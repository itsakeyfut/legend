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

/// The most skinned characters one frame may draw. Each owns a slice of the
/// per-frame bone buffer, so the buffer is this many slots long. 16 * 8 KiB =
/// 128 KiB a frame; raising it costs only that linear memory.
pub const max_skinned = 16;

/// The uniform block layout, matching the shader's. A fixed-size matrix array:
/// simpler than a dynamically sized buffer, and the unused tail costs 8 KiB once.
const BoneBlock = struct {
    matrices: [max_joints]Mat4,
};

/// A bound palette: the descriptor set (shared by every character this frame)
/// and the dynamic offset that selects one character's slot within it.
pub const BoneBinding = struct {
    set: c.VkDescriptorSet,
    offset: u32,
};

/// The descriptor set layout for the bone buffer: set 1, binding 0, read by the
/// vertex shader. Dynamic, so one set serves every character and the byte offset
/// into the buffer is supplied per draw rather than baked into the set.
pub const BoneLayout = struct {
    handle: c.VkDescriptorSetLayout,
    device: c.VkDevice,

    pub fn init(device: *const Device) !BoneLayout {
        const binding = c.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
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

/// One big bone buffer per frame in flight, holding max_skinned palettes end to
/// end, with a single dynamic descriptor set that indexes into it. Each frame,
/// characters take slots in order from 0; the offset a slot maps to is what the
/// draw binds.
pub const BonePool = struct {
    layout: BoneLayout,
    pool: c.VkDescriptorPool,
    buffers: [renderer.max_frames_in_flight]Buffer,
    sets: [renderer.max_frames_in_flight]c.VkDescriptorSet,
    /// One palette's stride in the buffer: a BoneBlock rounded up to the device's
    /// required dynamic-offset alignment, so every slot offset is legal.
    stride: usize,
    /// The next free slot this frame. Reset to 0 at the start of each frame's
    /// draw list; handed out and incremented per skinned character.
    next_slot: usize,
    device: c.VkDevice,

    pub fn init(device: *const Device) !BonePool {
        var layout = try BoneLayout.init(device);
        errdefer layout.deinit();

        // The dynamic offset for each slot must be a multiple of this. A
        // BoneBlock (8 KiB) is already far larger, but rounding the stride up to
        // it keeps every slot offset legal on any device.
        var props: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(device.physical, &props);
        const alignment: usize = @intCast(props.limits.minUniformBufferOffsetAlignment);
        const block = @sizeOf(BoneBlock);
        const stride = if (alignment == 0) block else ((block + alignment - 1) / alignment) * alignment;

        // One dynamic descriptor per frame in flight.
        const size = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
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

        // A host-visible buffer per frame, big enough for every slot.
        var buffers: [renderer.max_frames_in_flight]Buffer = undefined;
        var made: usize = 0;
        errdefer for (0..made) |i| buffers[i].deinit();
        for (0..renderer.max_frames_in_flight) |i| {
            buffers[i] = try Buffer.init(
                device,
                stride * max_skinned,
                c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );
            made += 1;
        }

        // One dynamic set per frame. Its range is a single palette; the offset
        // that picks a slot is supplied at bind time, not here.
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
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
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
            .stride = stride,
            .next_slot = 0,
            .device = device.handle,
        };
    }

    pub fn deinit(self: *BonePool) void {
        for (0..renderer.max_frames_in_flight) |i| self.buffers[i].deinit();
        c.vkDestroyDescriptorPool(self.device, self.pool, null);
        self.layout.deinit();
        self.* = undefined;
    }

    /// Starts a frame's bone usage: slots are handed out from 0 again. Called
    /// once, before the first character is uploaded.
    pub fn reset(self: *BonePool) void {
        self.next_slot = 0;
    }

    /// Claims the next slot for `matrices` and writes them into frame `frame`'s
    /// buffer, returning the binding that draws it. Null when the frame is
    /// already full: the character is dropped this frame rather than overwriting
    /// another's palette. Raising max_skinned is the fix if it ever bites.
    pub fn upload(self: *BonePool, frame: usize, matrices: []const Mat4) !?BoneBinding {
        if (matrices.len > max_joints) return Error.TooManyJoints;
        if (self.next_slot >= max_skinned) return null;

        const slot = self.next_slot;
        self.next_slot += 1;
        const offset = slot * self.stride;
        try self.buffers[frame].writeAt(offset, std.mem.sliceAsBytes(matrices));

        return .{ .set = self.sets[frame], .offset = @intCast(offset) };
    }
};
