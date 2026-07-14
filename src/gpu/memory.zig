//! GPU memory: buffers, and the staging machinery that gets data into them.
//!
//! Vulkan allocates nothing on your behalf. You ask what kinds of memory the
//! device has, pick one that satisfies both the resource's requirements and
//! yours, allocate it, and bind it. The distinction that matters is that the
//! fast memory (device-local) is usually not writable by the CPU at all, so data
//! reaches it by way of a temporary buffer in memory that is -- which is what
//! staging means, and what textures will do too.

const std = @import("std");
const c = @import("../platform/c.zig").c;
const Device = @import("device.zig").Device;

pub const Error = error{
    VulkanCall,
    NoSuitableMemory,
};

fn check(result: c.VkResult, comptime what: []const u8) !void {
    if (result != c.VK_SUCCESS) {
        std.debug.print("{s} failed: VkResult = {d}\n", .{ what, result });
        return Error.VulkanCall;
    }
}

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
        defer c.vkFreeCommandBuffers(self.device.handle, self.pool, 1, &cmd);

        const begin = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try check(c.vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer");

        const region = c.VkBufferCopy{ .srcOffset = 0, .dstOffset = 0, .size = size };
        c.vkCmdCopyBuffer(cmd, src, dst, 1, &region);

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
        // Blocking is fine here: uploads happen at load time, not per frame. A
        // streaming engine would use a fence and carry on.
        try check(c.vkQueueWaitIdle(self.device.graphics_queue), "vkQueueWaitIdle");
    }
};
