//! Textures: the sampler, the descriptor machinery, and what a material binds.
//!
//! A texture cannot be pushed into a command buffer the way a matrix can -- it
//! is too big, and the shader reaches for it by name rather than being handed a
//! copy. Instead the GPU is told, ahead of time, "slot 0 holds a sampled image",
//! and then at draw time which image that is. That indirection is what all three
//! descriptor objects exist to express.

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;
const check = vk.check;
const Error = vk.Error;
const Device = @import("device.zig").Device;
const GpuImage = @import("memory.zig").GpuImage;

/// How many textures may exist at once. A fixed pool because Vulkan wants to be
/// told up front; raising it is a one-line change, and a real engine would grow
/// pools on demand.
pub const max_textures = 256;

/// How a shader reads an image: filtering, wrapping, mip selection. Kept apart
/// from the image itself because it is a separate question -- one sampler is
/// shared by every texture that wants to be read the same way.
pub const Sampler = struct {
    handle: c.VkSampler,
    device: c.VkDevice,

    pub fn init(device: *const Device) !Sampler {
        const info = c.VkSamplerCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            // LINEAR: blend between texels rather than snapping to the nearest.
            // The software rasterizer did nearest-neighbour; this is free here.
            .magFilter = c.VK_FILTER_LINEAR,
            .minFilter = c.VK_FILTER_LINEAR,
            .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR,
            // REPEAT, matching the `@mod` the software renderer applied to UVs.
            .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .mipLodBias = 0,
            // Anisotropy needs a device feature we have not asked for, and mip
            // levels we do not yet generate. Both belong with mipmapping.
            .anisotropyEnable = c.VK_FALSE,
            .maxAnisotropy = 1,
            .compareEnable = c.VK_FALSE,
            .compareOp = c.VK_COMPARE_OP_ALWAYS,
            .minLod = 0,
            .maxLod = 0,
            .borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            // Normalized: UVs run 0..1 regardless of the image's pixel size,
            // which is what every mesh in the engine assumes.
            .unnormalizedCoordinates = c.VK_FALSE,
        };

        var handle: c.VkSampler = null;
        try check(c.vkCreateSampler(device.handle, &info, null, &handle), "vkCreateSampler");
        return .{ .handle = handle, .device = device.handle };
    }

    pub fn deinit(self: *Sampler) void {
        c.vkDestroySampler(self.device, self.handle, null);
        self.* = undefined;
    }
};

/// The type declaration: what a descriptor set for a material looks like. The
/// pipeline is built against this, and every set handed to it must match.
pub const TextureLayout = struct {
    handle: c.VkDescriptorSetLayout,
    device: c.VkDevice,

    pub fn init(device: *const Device) !TextureLayout {
        const binding = c.VkDescriptorSetLayoutBinding{
            // Matches [vk::binding(0, 0)] in the shader. The number is the
            // contract; nothing checks it for you until validation runs.
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
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

    pub fn deinit(self: *TextureLayout) void {
        c.vkDestroyDescriptorSetLayout(self.device, self.handle, null);
        self.* = undefined;
    }
};

/// Where descriptor sets are carved from. Vulkan wants the budget declared up
/// front -- so many sets, so many descriptors of each type -- because the driver
/// reserves real GPU memory for them.
pub const TexturePool = struct {
    handle: c.VkDescriptorPool,
    layout: TextureLayout,
    sampler: Sampler,
    device: c.VkDevice,
    allocated: u32 = 0,

    pub fn init(device: *const Device) !TexturePool {
        const size = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = max_textures,
        };

        const info = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            // No FREE_DESCRIPTOR_SET_BIT: sets are never returned individually,
            // only when the whole pool goes. Textures live as long as the scene,
            // and saying so lets the driver use a bump allocator internally.
            .flags = 0,
            .maxSets = max_textures,
            .poolSizeCount = 1,
            .pPoolSizes = &size,
        };

        var handle: c.VkDescriptorPool = null;
        try check(
            c.vkCreateDescriptorPool(device.handle, &info, null, &handle),
            "vkCreateDescriptorPool",
        );
        errdefer c.vkDestroyDescriptorPool(device.handle, handle, null);

        var layout = try TextureLayout.init(device);
        errdefer layout.deinit();

        const sampler = try Sampler.init(device);

        return .{
            .handle = handle,
            .layout = layout,
            .sampler = sampler,
            .device = device.handle,
        };
    }

    pub fn deinit(self: *TexturePool) void {
        // The sets go with the pool; they are not freed one by one.
        c.vkDestroyDescriptorPool(self.device, self.handle, null);
        self.sampler.deinit();
        self.layout.deinit();
        self.* = undefined;
    }

    /// Carves out a set and points it at `image`. The returned set is bound at
    /// draw time and needs no cleanup of its own.
    pub fn bind(self: *TexturePool, image: *const GpuImage) !c.VkDescriptorSet {
        if (self.allocated >= max_textures) return Error.TooManyTextures;

        const alloc_info = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.handle,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.layout.handle,
        };

        var set: c.VkDescriptorSet = null;
        try check(
            c.vkAllocateDescriptorSets(self.device, &alloc_info, &set),
            "vkAllocateDescriptorSets",
        );
        self.allocated += 1;

        // Allocating a set gives you an empty slot; this is what fills it in.
        const image_info = c.VkDescriptorImageInfo{
            .sampler = self.sampler.handle,
            .imageView = image.view,
            // The layout the image will be in when the shader reads it -- which
            // is a promise, not an instruction. uploadImage already put it there.
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const write = c.VkWriteDescriptorSet{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        c.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);

        return set;
    }
};

/// An uploaded texture and the descriptor set that binds it. This is what a
/// material holds.
pub const GpuTexture = struct {
    image: GpuImage,
    set: c.VkDescriptorSet,

    pub fn deinit(self: *GpuTexture) void {
        // The set belongs to the pool and dies with it; only the image is ours.
        self.image.deinit();
        self.* = undefined;
    }
};
