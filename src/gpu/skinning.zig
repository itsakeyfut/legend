//! GPU-side skinning resources: the bone-matrix uniform buffers and the
//! descriptor sets that bind them.
//!
//! Skinning needs one matrix per joint, recomputed every frame as the skeleton
//! poses. Those matrices reach the vertex shader through a uniform buffer bound
//! at descriptor set 1 -- kept separate from the material texture at set 0
//! because the two change at different rates (texture per material, bones per
//! character per frame). One buffer per frame in flight, so the CPU can write
//! next frame's pose while the GPU still reads this frame's.

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;
const check = vk.check;

const Device = @import("device.zig").Device;
const memory = @import("memory.zig");
const Buffer = memory.Buffer;
const renderer = @import("renderer.zig");
const math = @import("../math/math.zig");
const Mat4 = math.Mat4;

pub const Error = error{TooManyJoints};

/// The most joints one skinned mesh may have. 128 covers any humanoid rig with
/// room to spare (CesiumMan uses 19), and 128 * 64 bytes = 8 KiB stays within
/// the 16 KiB uniform buffer size every Vulkan implementation must support.
pub const max_joints = 128;

/// The uniform block layout, matching the shader's. A fixed-size matrix array:
/// simpler than a dynamically sized buffer, and the unused tail costs 8 KiB once.
const BoneBlock = struct {
    matrices: [max_joints]Mat4,
};

/// The descriptor set layout for the bone buffer: set 1, binding 0, read by the
/// vertex shader. The skinning pipeline is built against this alongside the
/// texture layout at set 0.
pub const BoneLayout = struct {
    handle: c.VkDescriptorSetLayout,
    device: c.VkDevice,

    pub fn init(device: *const Device) !BoneLayout {
        const binding = c.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        };

        const info = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = 1,
            .pBindings = &binding,
        };

        var handle: c.VkDescriptorSetLayout = null;
        try check(
            c.vkCreateDescriptorSetLayout(device.handle, &info, null, &handle),
            "vkCreateDescriptorSetLayout",
        );
        return .{ .handle = handle, .device = device.handle };
    }

    pub fn deinit(self: *BoneLayout) void {
        c.vkDestroyDescriptorSetLayout(self.device, self.handle, null);
        self.* = undefined;
    }
};

/// The per-frame bone buffers and their descriptor sets. One of each per frame
/// in flight: write buffer[frame], bind set[frame].
pub const BonePool = struct {
    layout: BoneLayout,
    pool: c.VkDescriptorPool,
    buffers: [renderer.max_frames_in_flight]Buffer,
    sets: [renderer.max_frames_in_flight]c.VkDescriptorSet,
    device: c.VkDevice,

    pub fn init(device: *const Device) !BonePool {
        var layout = try BoneLayout.init(device);
        errdefer layout.deinit();

        // One uniform descriptor per frame in flight.
        const size = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = renderer.max_frames_in_flight,
        };
        const pool_info = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = renderer.max_frames_in_flight,
            .poolSizeCount = 1,
            .pPoolSizes = &size,
        };
        var pool: c.VkDescriptorPool = null;
        try check(c.vkCreateDescriptorPool(device.handle, &pool_info, null, &pool), "vkCreateDescriptorPool");
        errdefer c.vkDestroyDescriptorPool(device.handle, pool, null);

        // A host-visible uniform buffer per frame, written each frame with the
        // current pose.
        var buffers: [renderer.max_frames_in_flight]Buffer = undefined;
        var made: usize = 0;
        errdefer for (0..made) |i| buffers[i].deinit();
        for (0..renderer.max_frames_in_flight) |i| {
            buffers[i] = try Buffer.init(
                device,
                @sizeOf(BoneBlock),
                c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );
            made += 1;
        }

        // A descriptor set per frame, each pointing at its buffer.
        var sets: [renderer.max_frames_in_flight]c.VkDescriptorSet = undefined;
        for (0..renderer.max_frames_in_flight) |i| {
            const alloc_info = c.VkDescriptorSetAllocateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .pNext = null,
                .descriptorPool = pool,
                .descriptorSetCount = 1,
                .pSetLayouts = &layout.handle,
            };
            try check(c.vkAllocateDescriptorSets(device.handle, &alloc_info, &sets[i]), "vkAllocateDescriptorSets");

            const buffer_info = c.VkDescriptorBufferInfo{
                .buffer = buffers[i].handle,
                .offset = 0,
                .range = @sizeOf(BoneBlock),
            };
            const write = c.VkWriteDescriptorSet{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = sets[i],
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_info,
                .pTexelBufferView = null,
            };
            c.vkUpdateDescriptorSets(device.handle, 1, &write, 0, null);
        }

        return .{
            .layout = layout,
            .pool = pool,
            .buffers = buffers,
            .sets = sets,
            .device = device.handle,
        };
    }

    pub fn deinit(self: *BonePool) void {
        for (0..renderer.max_frames_in_flight) |i| self.buffers[i].deinit();
        c.vkDestroyDescriptorPool(self.device, self.pool, null);
        self.layout.deinit();
        self.* = undefined;
    }

    /// Writes the given skinning matrices into frame `frame`'s buffer. Extra
    /// slots past `matrices.len` are left as-is; the shader only reads joints a
    /// vertex actually references.
    pub fn upload(self: *BonePool, frame: usize, matrices: []const Mat4) !void {
        if (matrices.len > max_joints) return Error.TooManyJoints;
        try self.buffers[frame].write(std.mem.sliceAsBytes(matrices));
    }
};
