//! The depth buffer. The swapchain hands over colour images; depth is ours to
//! create -- an image, its memory, and a view -- and to hang off the render pass.

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;
const check = vk.check;
const Error = vk.Error;
const Device = @import("device.zig").Device;
const findMemoryType = @import("memory.zig").findMemoryType;

/// Not every format is supported everywhere, so the device is asked rather than
/// assumed. D32 is preferred: 32 bits of float depth, no stencil to pay for.
pub fn findDepthFormat(physical: c.VkPhysicalDevice) !c.VkFormat {
    const candidates = [_]c.VkFormat{
        c.VK_FORMAT_D32_SFLOAT,
        c.VK_FORMAT_D32_SFLOAT_S8_UINT,
        c.VK_FORMAT_D24_UNORM_S8_UINT,
    };
    for (candidates) |format| {
        var props: c.VkFormatProperties = undefined;
        c.vkGetPhysicalDeviceFormatProperties(physical, format, &props);
        const wanted = c.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT;
        if (props.optimalTilingFeatures & wanted == wanted) return format;
    }
    return Error.NoDepthFormat;
}

pub const DepthBuffer = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    format: c.VkFormat,
    device: c.VkDevice,

    pub fn init(device: *const Device, extent: c.VkExtent2D) !DepthBuffer {
        const format = try findDepthFormat(device.physical);

        const image_info = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            // OPTIMAL, not LINEAR: nothing on the CPU ever reads this, so the
            // driver is free to swizzle it however the hardware likes best.
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        var image: c.VkImage = null;
        try check(c.vkCreateImage(device.handle, &image_info, null, &image), "vkCreateImage");
        errdefer c.vkDestroyImage(device.handle, image, null);

        var reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(device.handle, image, &reqs);

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

        try check(c.vkBindImageMemory(device.handle, image, memory, 0), "vkBindImageMemory");

        const view_info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
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
            .image = image,
            .memory = memory,
            .view = view,
            .format = format,
            .device = device.handle,
        };
    }

    pub fn deinit(self: *DepthBuffer) void {
        c.vkDestroyImageView(self.device, self.view, null);
        c.vkDestroyImage(self.device, self.image, null);
        c.vkFreeMemory(self.device, self.memory, null);
        self.* = undefined;
    }
};
