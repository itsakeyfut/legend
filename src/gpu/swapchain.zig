//! The swapchain: the ring of images the GPU draws into and the window system
//! displays, plus the views through which they are accessed.
//!
//! Nothing here is chosen unilaterally. Every parameter -- how many images, what
//! pixel format, how frames are queued for display -- is negotiated with what
//! the surface and the driver actually support.

const std = @import("std");
const c = @import("../platform/c.zig").c;
const Device = @import("device.zig").Device;

pub const Error = error{
    VulkanCall,
    NoSurfaceFormat,
    TooManyImages,
};

/// A hard ceiling so the image list can live in a fixed array. Drivers offer
/// two or three; anything near this would be pathological.
const max_images = 8;

fn check(result: c.VkResult, comptime what: []const u8) !void {
    if (result != c.VK_SUCCESS) {
        std.debug.print("{s} failed: VkResult = {d}\n", .{ what, result });
        return Error.VulkanCall;
    }
}

/// Prefer 8-bit BGRA in sRGB: sRGB means the hardware does gamma conversion on
/// write, so colours land where the eye expects them without us correcting by
/// hand. If it is not offered, take whatever is first rather than fail.
fn chooseFormat(formats: []const c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
    for (formats) |f| {
        if (f.format == c.VK_FORMAT_B8G8R8A8_SRGB and
            f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return f;
        }
    }
    return formats[0];
}

/// MAILBOX replaces the queued frame instead of blocking, so it gives low
/// latency without tearing -- at the cost of rendering frames that get thrown
/// away. FIFO is plain vsync and is the only mode the spec guarantees exists.
fn choosePresentMode(modes: []const c.VkPresentModeKHR) c.VkPresentModeKHR {
    for (modes) |m| {
        if (m == c.VK_PRESENT_MODE_MAILBOX_KHR) return m;
    }
    return c.VK_PRESENT_MODE_FIFO_KHR;
}

/// The surface usually dictates the extent exactly. The 0xFFFFFFFF sentinel is
/// the exception: it means "you choose", and then the window's pixel size is
/// clamped into the range the surface allows.
fn chooseExtent(caps: c.VkSurfaceCapabilitiesKHR, width: u32, height: u32) c.VkExtent2D {
    if (caps.currentExtent.width != std.math.maxInt(u32)) return caps.currentExtent;
    return .{
        .width = std.math.clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
        .height = std.math.clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
    };
}

pub const Swapchain = struct {
    handle: c.VkSwapchainKHR,
    format: c.VkFormat,
    extent: c.VkExtent2D,

    images: [max_images]c.VkImage,
    views: [max_images]c.VkImageView,
    count: u32,

    device: c.VkDevice,

    pub fn init(
        allocator: std.mem.Allocator,
        device: *const Device,
        surface: c.VkSurfaceKHR,
        width: u32,
        height: u32,
    ) !Swapchain {
        // -- ask what the surface supports ------------------------------------
        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(
            c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device.physical, surface, &caps),
            "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
        );

        var format_count: u32 = 0;
        try check(
            c.vkGetPhysicalDeviceSurfaceFormatsKHR(device.physical, surface, &format_count, null),
            "vkGetPhysicalDeviceSurfaceFormatsKHR",
        );
        if (format_count == 0) return Error.NoSurfaceFormat;

        const formats = try allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        defer allocator.free(formats);
        try check(
            c.vkGetPhysicalDeviceSurfaceFormatsKHR(device.physical, surface, &format_count, formats.ptr),
            "vkGetPhysicalDeviceSurfaceFormatsKHR",
        );

        var mode_count: u32 = 0;
        try check(
            c.vkGetPhysicalDeviceSurfacePresentModesKHR(device.physical, surface, &mode_count, null),
            "vkGetPhysicalDeviceSurfacePresentModesKHR",
        );
        const modes = try allocator.alloc(c.VkPresentModeKHR, @max(mode_count, 1));
        defer allocator.free(modes);
        if (mode_count > 0) {
            try check(
                c.vkGetPhysicalDeviceSurfacePresentModesKHR(device.physical, surface, &mode_count, modes.ptr),
                "vkGetPhysicalDeviceSurfacePresentModesKHR",
            );
        }

        const surface_format = chooseFormat(formats);
        const present_mode = choosePresentMode(modes[0..mode_count]);
        const extent = chooseExtent(caps, width, height);

        // One more than the minimum: at the minimum the CPU can end up waiting
        // on the driver every frame just to get an image to draw into.
        var image_count = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 and image_count > caps.maxImageCount) {
            image_count = caps.maxImageCount;
        }
        if (image_count > max_images) return Error.TooManyImages;

        // -- create it ---------------------------------------------------------
        const families = [_]u32{ device.families.graphics, device.families.present };
        const concurrent = !device.families.sameFamily();

        const info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            // Sharing an image across two queue families needs explicit
            // ownership transfers unless it is declared CONCURRENT. When one
            // family does both jobs -- the common case -- EXCLUSIVE is faster.
            .imageSharingMode = if (concurrent)
                c.VK_SHARING_MODE_CONCURRENT
            else
                c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = if (concurrent) 2 else 0,
            .pQueueFamilyIndices = if (concurrent) &families else null,
            .preTransform = caps.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = c.VK_TRUE,
            .oldSwapchain = null,
        };

        var handle: c.VkSwapchainKHR = null;
        try check(c.vkCreateSwapchainKHR(device.handle, &info, null, &handle), "vkCreateSwapchainKHR");
        errdefer c.vkDestroySwapchainKHR(device.handle, handle, null);

        // The driver may hand back more images than we asked for.
        var actual: u32 = 0;
        try check(
            c.vkGetSwapchainImagesKHR(device.handle, handle, &actual, null),
            "vkGetSwapchainImagesKHR",
        );
        if (actual > max_images) return Error.TooManyImages;

        var swapchain = Swapchain{
            .handle = handle,
            .format = surface_format.format,
            .extent = extent,
            .images = undefined,
            .views = undefined,
            .count = actual,
            .device = device.handle,
        };
        try check(
            c.vkGetSwapchainImagesKHR(device.handle, handle, &actual, &swapchain.images),
            "vkGetSwapchainImagesKHR",
        );

        // -- one view per image -----------------------------------------------
        // Images are never touched directly in Vulkan; a view states how to
        // interpret one -- as 2D colour here, with no mip levels or layers.
        var created: u32 = 0;
        errdefer for (0..created) |i| c.vkDestroyImageView(device.handle, swapchain.views[i], null);

        while (created < actual) : (created += 1) {
            const view_info = c.VkImageViewCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = swapchain.images[created],
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = surface_format.format,
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
            try check(
                c.vkCreateImageView(device.handle, &view_info, null, &swapchain.views[created]),
                "vkCreateImageView",
            );
        }

        return swapchain;
    }

    pub fn deinit(self: *Swapchain) void {
        // Views first: they are children of the images the swapchain owns.
        for (0..self.count) |i| c.vkDestroyImageView(self.device, self.views[i], null);
        c.vkDestroySwapchainKHR(self.device, self.handle, null);
        self.* = undefined;
    }

    pub fn presentModeName(mode: c.VkPresentModeKHR) []const u8 {
        return switch (mode) {
            c.VK_PRESENT_MODE_IMMEDIATE_KHR => "immediate",
            c.VK_PRESENT_MODE_MAILBOX_KHR => "mailbox",
            c.VK_PRESENT_MODE_FIFO_KHR => "fifo",
            c.VK_PRESENT_MODE_FIFO_RELAXED_KHR => "fifo-relaxed",
            else => "unknown",
        };
    }
};
