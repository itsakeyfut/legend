//! GPU memory: buffers, and the staging machinery that gets data into them.
//!
//! Vulkan allocates nothing on your behalf. You ask what kinds of memory the
//! device has, pick one that satisfies both the resource's requirements and
//! yours, allocate it, and bind it. The distinction that matters is that the
//! fast memory (device-local) is usually not writable by the CPU at all, so data
//! reaches it by way of a temporary buffer in memory that is -- which is what
//! staging means, and what textures will do too.

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;
const check = vk.check;
const Error = vk.Error;
const Device = @import("device.zig").Device;

/// The device publishes a list of memory types, each with a set of properties.
/// A resource's requirements say which of them are acceptable as a bitmask; we
/// pick the first that is both acceptable and has the properties we asked for.
pub fn findMemoryType(
    physical: c.VkPhysicalDevice,
    type_bits: u32,
    properties: c.VkMemoryPropertyFlags,
) !u32 {
    var props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physical, &props);

    for (0..props.memoryTypeCount) |i| {
        const usable = type_bits & (@as(u32, 1) << @intCast(i)) != 0;
        const has_props = props.memoryTypes[i].propertyFlags & properties == properties;
        if (usable and has_props) return @intCast(i);
    }
    return Error.NoSuitableMemory;
}

/// A buffer and the memory behind it. Vulkan keeps the two separate -- one
/// allocation can back several buffers -- but at this scale one-to-one is fine,
/// and a real engine would replace this with a sub-allocator.
pub const Buffer = struct {
    handle: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: c.VkDeviceSize,
    device: c.VkDevice,

    pub fn init(
        device: *const Device,
        size: c.VkDeviceSize,
        usage: c.VkBufferUsageFlags,
        properties: c.VkMemoryPropertyFlags,
    ) !Buffer {
        const info = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        var handle: c.VkBuffer = null;
        try check(c.vkCreateBuffer(device.handle, &info, null, &handle), "vkCreateBuffer");
        errdefer c.vkDestroyBuffer(device.handle, handle, null);

        // The buffer exists but has no memory yet; asking it what it needs is a
        // separate step, because the answer depends on the driver.
        var reqs: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(device.handle, handle, &reqs);

        const alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = reqs.size,
            .memoryTypeIndex = try findMemoryType(device.physical, reqs.memoryTypeBits, properties),
        };

        var memory: c.VkDeviceMemory = null;
        try check(c.vkAllocateMemory(device.handle, &alloc_info, null, &memory), "vkAllocateMemory");
        errdefer c.vkFreeMemory(device.handle, memory, null);

        try check(c.vkBindBufferMemory(device.handle, handle, memory, 0), "vkBindBufferMemory");

        return .{
            .handle = handle,
            .memory = memory,
            .size = size,
            .device = device.handle,
        };
    }

    pub fn deinit(self: *Buffer) void {
        c.vkDestroyBuffer(self.device, self.handle, null);
        c.vkFreeMemory(self.device, self.memory, null);
        self.* = undefined;
    }

    /// Copies `bytes` in. Only valid on host-visible memory, so in practice this
    /// is called on staging buffers rather than the real thing.
    pub fn write(self: *Buffer, bytes: []const u8) !void {
        var mapped: ?*anyopaque = null;
        try check(
            c.vkMapMemory(self.device, self.memory, 0, self.size, 0, &mapped),
            "vkMapMemory",
        );
        const dst: [*]u8 = @ptrCast(mapped.?);
        @memcpy(dst[0..bytes.len], bytes);
        // HOST_COHERENT memory needs no explicit flush; the write is visible to
        // the GPU by the time the next queue submission runs.
        c.vkUnmapMemory(self.device, self.memory);
    }

    /// Writes `bytes` at `offset` into the buffer, leaving the rest untouched.
    /// Used to pack several independent records -- one bone palette per character
    /// -- into a single buffer, each at its own slot.
    pub fn writeAt(self: *Buffer, offset: usize, bytes: []const u8) !void {
        var mapped: ?*anyopaque = null;
        try check(
            c.vkMapMemory(self.device, self.memory, 0, self.size, 0, &mapped),
            "vkMapMemory",
        );
        const dst: [*]u8 = @ptrCast(mapped.?);
        @memcpy(dst[offset .. offset + bytes.len], bytes);
        c.vkUnmapMemory(self.device, self.memory);
    }
};

/// Owns a short-lived command pool for one-off transfers. Every buffer upload
/// needs a command buffer to carry the copy, and building one per upload is
/// wasteful; this keeps a pool around instead.
pub const Uploader = struct {
    /// By value, not by pointer: a Context is returned by value, so a pointer
    /// into the Device it was built from would dangle the moment it moved.
    device: Device,
    pool: c.VkCommandPool,

    pub fn init(device: *const Device) !Uploader {
        const info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            // TRANSIENT tells the driver these buffers are recorded once and
            // thrown away, which lets it allocate them more cheaply.
            .flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
            .queueFamilyIndex = device.families.graphics,
        };
        var pool: c.VkCommandPool = null;
        try check(
            c.vkCreateCommandPool(device.handle, &info, null, &pool),
            "vkCreateCommandPool",
        );
        return .{ .device = device.*, .pool = pool };
    }

    pub fn deinit(self: *Uploader) void {
        c.vkDestroyCommandPool(self.device.handle, self.pool, null);
        self.* = undefined;
    }

    /// Builds a device-local buffer holding `bytes`, by way of a staging buffer.
    /// The staging buffer is created, filled, copied from, and destroyed here.
    pub fn upload(
        self: *Uploader,
        bytes: []const u8,
        usage: c.VkBufferUsageFlags,
    ) !Buffer {
        const size: c.VkDeviceSize = bytes.len;

        var staging = try Buffer.init(
            &self.device,
            size,
            c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        defer staging.deinit();
        try staging.write(bytes);

        var buffer = try Buffer.init(
            &self.device,
            size,
            usage | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );
        errdefer buffer.deinit();

        try self.copyBuffer(staging.handle, buffer.handle, size);
        return buffer;
    }

    fn copyBuffer(
        self: *Uploader,
        src: c.VkBuffer,
        dst: c.VkBuffer,
        size: c.VkDeviceSize,
    ) !void {
        const cmd = try self.beginOneShot();
        const region = c.VkBufferCopy{ .srcOffset = 0, .dstOffset = 0, .size = size };
        c.vkCmdCopyBuffer(cmd, src, dst, 1, &region);
        try self.endOneShot(cmd);
    }

    /// Begins a one-off command buffer for a transfer.
    fn beginOneShot(self: *Uploader) !c.VkCommandBuffer {
        const alloc_info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var cmd: c.VkCommandBuffer = null;
        try check(
            c.vkAllocateCommandBuffers(self.device.handle, &alloc_info, &cmd),
            "vkAllocateCommandBuffers",
        );
        errdefer c.vkFreeCommandBuffers(self.device.handle, self.pool, 1, &cmd);

        const begin = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try check(c.vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer");
        return cmd;
    }

    /// Submits and waits. Blocking is fine: transfers happen at load time.
    fn endOneShot(self: *Uploader, cmd: c.VkCommandBuffer) !void {
        defer c.vkFreeCommandBuffers(self.device.handle, self.pool, 1, &cmd);

        try check(c.vkEndCommandBuffer(cmd), "vkEndCommandBuffer");

        const submit = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        try check(
            c.vkQueueSubmit(self.device.graphics_queue, 1, &submit, null),
            "vkQueueSubmit",
        );
        try check(c.vkQueueWaitIdle(self.device.graphics_queue), "vkQueueWaitIdle");
    }

    /// Moves an image from one layout to another.
    ///
    /// An image's bytes are not laid out the same way for every purpose: the
    /// arrangement that is fast to copy into is not the one that is fast to
    /// sample from. Vulkan will not guess -- the transition is stated, and the
    /// barrier also says which stages must wait for which, so the copy is
    /// visible to the shader that reads it.
    fn transitionLayout(
        self: *Uploader,
        image: c.VkImage,
        old: c.VkImageLayout,
        new: c.VkImageLayout,
    ) !void {
        const cmd = try self.beginOneShot();

        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = old;
        barrier.newLayout = new;
        // Not transferring between queue families, so both are IGNORED. Setting
        // them to the same index would be wrong -- it means a real transfer.
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };

        var src_stage: c.VkPipelineStageFlags = undefined;
        var dst_stage: c.VkPipelineStageFlags = undefined;

        if (old == c.VK_IMAGE_LAYOUT_UNDEFINED and
            new == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
        {
            // Nothing has touched it yet, so nothing has to complete first.
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            src_stage = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
            dst_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (old == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and
            new == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
        {
            // The copy must land before any shader reads it.
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            src_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
            dst_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else {
            return Error.UnsupportedTransition;
        }

        c.vkCmdPipelineBarrier(
            cmd,
            src_stage,
            dst_stage,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier,
        );

        try self.endOneShot(cmd);
    }

    /// Copies a staging buffer into an image, one mip level, one layer.
    fn copyBufferToImage(
        self: *Uploader,
        buffer: c.VkBuffer,
        image: c.VkImage,
        width: u32,
        height: u32,
    ) !void {
        const cmd = try self.beginOneShot();

        const region = c.VkBufferImageCopy{
            .bufferOffset = 0,
            // Zero means "tightly packed": rows follow one another with no
            // padding, which is what our pixel buffers are.
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        };
        c.vkCmdCopyBufferToImage(
            cmd,
            buffer,
            image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
        );

        try self.endOneShot(cmd);
    }

    /// Uploads RGBA8 pixels into a sampled, device-local image.
    ///
    /// `pixels` is width * height * 4 bytes. The image walks UNDEFINED ->
    /// TRANSFER_DST -> SHADER_READ_ONLY; the staging buffer is created, copied
    /// from, and destroyed here.
    pub fn uploadImage(
        self: *Uploader,
        pixels: []const u8,
        width: u32,
        height: u32,
    ) !GpuImage {
        const size: c.VkDeviceSize = pixels.len;

        var staging = try Buffer.init(
            &self.device,
            size,
            c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        defer staging.deinit();
        try staging.write(pixels);

        var image = try GpuImage.init(&self.device, width, height);
        errdefer image.deinit();

        try self.transitionLayout(
            image.handle,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        );
        try self.copyBufferToImage(staging.handle, image.handle, width, height);
        try self.transitionLayout(
            image.handle,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        );

        return image;
    }
};

/// An image in device-local memory, with the view a shader reads it through.
/// The same shape as DepthBuffer -- image, memory, view -- and a candidate for
/// merging with it once the sub-allocator lands.
pub const GpuImage = struct {
    handle: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    width: u32,
    height: u32,
    device: c.VkDevice,

    pub fn init(device: *const Device, width: u32, height: u32) !GpuImage {
        const info = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = c.VK_IMAGE_TYPE_2D,
            // SRGB, matching the swapchain: the hardware converts to linear on
            // read, so lighting maths happens in linear space and the result is
            // converted back on write. Getting this wrong is what makes shaded
            // textures look washed out or muddy.
            .format = c.VK_FORMAT_R8G8B8A8_SRGB,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        var handle: c.VkImage = null;
        try check(c.vkCreateImage(device.handle, &info, null, &handle), "vkCreateImage");
        errdefer c.vkDestroyImage(device.handle, handle, null);

        var reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(device.handle, handle, &reqs);

        const alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = reqs.size,
            .memoryTypeIndex = try findMemoryType(
                device.physical,
                reqs.memoryTypeBits,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            ),
        };

        var memory: c.VkDeviceMemory = null;
        try check(
            c.vkAllocateMemory(device.handle, &alloc_info, null, &memory),
            "vkAllocateMemory",
        );
        errdefer c.vkFreeMemory(device.handle, memory, null);

        try check(c.vkBindImageMemory(device.handle, handle, memory, 0), "vkBindImageMemory");

        const view_info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = handle,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = c.VK_FORMAT_R8G8B8A8_SRGB,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        var view: c.VkImageView = null;
        try check(
            c.vkCreateImageView(device.handle, &view_info, null, &view),
            "vkCreateImageView",
        );

        return .{
            .handle = handle,
            .memory = memory,
            .view = view,
            .width = width,
            .height = height,
            .device = device.handle,
        };
    }

    pub fn deinit(self: *GpuImage) void {
        c.vkDestroyImageView(self.device, self.view, null);
        c.vkDestroyImage(self.device, self.handle, null);
        c.vkFreeMemory(self.device, self.memory, null);
        self.* = undefined;
    }
};
