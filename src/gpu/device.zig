//! Physical device selection, and the logical device and queues built on it.
//!
//! Vulkan does not hand you "the GPU". It hands you a list of them, and expects
//! you to state which one you want and exactly which capabilities you intend to
//! use. That verbosity is the point: nothing is enabled behind your back, and a
//! feature the shader relies on but the device never asked for is an error
//! rather than a silent fallback.

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;
const check = vk.check;
const Error = vk.Error;

/// Rendering to a window needs this; a headless or compute-only device may not
/// have it, which is one of the things that disqualifies a candidate.
const required_extensions = [_][*c]const u8{
    c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
};

/// Which queue families do the work we need? "Graphics" and "can present to this
/// surface" are separate capabilities in Vulkan, and although they usually live
/// on the same family, they are not guaranteed to, so both are looked up.
pub const QueueFamilies = struct {
    graphics: u32,
    present: u32,

    pub fn sameFamily(self: QueueFamilies) bool {
        return self.graphics == self.present;
    }
};

fn findQueueFamilies(
    allocator: std.mem.Allocator,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
) !?QueueFamilies {
    var count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
    if (count == 0) return null;

    const families = try allocator.alloc(c.VkQueueFamilyProperties, count);
    defer allocator.free(families);
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, families.ptr);

    var graphics: ?u32 = null;
    var present: ?u32 = null;

    for (families, 0..) |family, i| {
        const index: u32 = @intCast(i);
        if (family.queueCount == 0) continue;

        if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0 and graphics == null) {
            graphics = index;
        }

        var supported: c.VkBool32 = c.VK_FALSE;
        try check(
            c.vkGetPhysicalDeviceSurfaceSupportKHR(device, index, surface, &supported),
            "vkGetPhysicalDeviceSurfaceSupportKHR",
        );
        if (supported == c.VK_TRUE and present == null) present = index;

        // A family that does both is worth preferring: it means one queue
        // instead of two, and no ownership transfers between them.
        if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0 and supported == c.VK_TRUE) {
            return .{ .graphics = index, .present = index };
        }
    }

    if (graphics == null or present == null) return null;
    return .{ .graphics = graphics.?, .present = present.? };
}

fn hasRequiredExtensions(allocator: std.mem.Allocator, device: c.VkPhysicalDevice) !bool {
    var count: u32 = 0;
    try check(
        c.vkEnumerateDeviceExtensionProperties(device, null, &count, null),
        "vkEnumerateDeviceExtensionProperties",
    );
    if (count == 0) return false;

    const available = try allocator.alloc(c.VkExtensionProperties, count);
    defer allocator.free(available);
    try check(
        c.vkEnumerateDeviceExtensionProperties(device, null, &count, available.ptr),
        "vkEnumerateDeviceExtensionProperties",
    );

    for (required_extensions) |wanted| {
        const want = std.mem.span(wanted);
        var found = false;
        for (available) |ext| {
            if (std.mem.eql(u8, std.mem.sliceTo(&ext.extensionName, 0), want)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Prefer a discrete GPU: on a laptop the integrated one will also be listed and
/// will also work, just several times slower.
fn score(props: c.VkPhysicalDeviceProperties) u32 {
    return switch (props.deviceType) {
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 1000,
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 100,
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 10,
        else => 1,
    };
}

pub const Device = struct {
    physical: c.VkPhysicalDevice,
    handle: c.VkDevice,
    families: QueueFamilies,
    graphics_queue: c.VkQueue,
    present_queue: c.VkQueue,
    name: [256]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        instance: c.VkInstance,
        surface: c.VkSurfaceKHR,
    ) !Device {
        // -- pick a physical device ------------------------------------------
        var count: u32 = 0;
        try check(c.vkEnumeratePhysicalDevices(instance, &count, null), "vkEnumeratePhysicalDevices");
        if (count == 0) return Error.NoSuitableDevice;

        const devices = try allocator.alloc(c.VkPhysicalDevice, count);
        defer allocator.free(devices);
        try check(
            c.vkEnumeratePhysicalDevices(instance, &count, devices.ptr),
            "vkEnumeratePhysicalDevices",
        );

        var best: ?c.VkPhysicalDevice = null;
        var best_score: u32 = 0;
        var best_families: QueueFamilies = undefined;
        var best_props: c.VkPhysicalDeviceProperties = undefined;

        for (devices) |candidate| {
            const families = try findQueueFamilies(allocator, candidate, surface) orelse continue;
            if (!try hasRequiredExtensions(allocator, candidate)) continue;

            var props: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(candidate, &props);

            const s = score(props);
            if (s > best_score) {
                best = candidate;
                best_score = s;
                best_families = families;
                best_props = props;
            }
        }

        const physical = best orelse return Error.NoSuitableDevice;

        // -- create the logical device ---------------------------------------
        const priority: f32 = 1.0;
        var queue_infos: [2]c.VkDeviceQueueCreateInfo = undefined;
        var queue_count: u32 = 1;

        queue_infos[0] = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = best_families.graphics,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        if (!best_families.sameFamily()) {
            queue_infos[1] = .{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = best_families.present,
                .queueCount = 1,
                .pQueuePriorities = &priority,
            };
            queue_count = 2;
        }

        // Slang lowers SV_VertexID using the SPIR-V DrawParameters capability,
        // which the device has to be told about. Zeroing the struct and setting
        // only what we need beats spelling out every field: it survives Vulkan
        // adding more of them.
        var vulkan11 = std.mem.zeroes(c.VkPhysicalDeviceVulkan11Features);
        vulkan11.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES;
        vulkan11.shaderDrawParameters = c.VK_TRUE;

        // Nothing from the Vulkan 1.0 feature set is needed yet. Features get
        // switched on as the renderer starts requiring them, never speculatively.
        const features = std.mem.zeroes(c.VkPhysicalDeviceFeatures);

        const device_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            // Feature sets newer than Vulkan 1.0 are chained through pNext rather
            // than added as fields -- that is how the API grows without breaking.
            .pNext = &vulkan11,
            .flags = 0,
            .queueCreateInfoCount = queue_count,
            .pQueueCreateInfos = &queue_infos,
            // Device layers are deprecated; the instance's layers cover us.
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = required_extensions.len,
            .ppEnabledExtensionNames = &required_extensions,
            .pEnabledFeatures = &features,
        };

        var handle: c.VkDevice = null;
        try check(c.vkCreateDevice(physical, &device_info, null, &handle), "vkCreateDevice");
        errdefer c.vkDestroyDevice(handle, null);

        // Queues are not created here so much as retrieved: the device made them,
        // and they die with it.
        var graphics_queue: c.VkQueue = null;
        var present_queue: c.VkQueue = null;
        c.vkGetDeviceQueue(handle, best_families.graphics, 0, &graphics_queue);
        c.vkGetDeviceQueue(handle, best_families.present, 0, &present_queue);

        var name: [256]u8 = undefined;
        const raw = std.mem.sliceTo(&best_props.deviceName, 0);
        const len = @min(raw.len, name.len - 1);
        @memcpy(name[0..len], raw[0..len]);
        name[len] = 0;

        return .{
            .physical = physical,
            .handle = handle,
            .families = best_families,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .name = name,
        };
    }

    pub fn deinit(self: *Device) void {
        c.vkDestroyDevice(self.handle, null);
        self.* = undefined;
    }

    pub fn deviceName(self: *const Device) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};
