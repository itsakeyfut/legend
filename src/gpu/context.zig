//! Vulkan context: the instance, the validation layer plumbing, and the surface
//! the window presents through.
//!
//! Validation layers are the single most important tool in Vulkan development.
//! Without them a misused API call does not fail loudly -- it silently corrupts
//! state and crashes somewhere unrelated. They are on in Debug and off in
//! release, where they would cost real time.

const std = @import("std");
const builtin = @import("builtin");

const vk = @import("vk.zig");
const c = vk.c;
const check = vk.check;
const Error = vk.Error;

const Window = @import("../platform/window.zig").Window;
const Mesh = @import("../render/mesh.zig").Mesh;

const device_mod = @import("device.zig");
const Device = device_mod.Device;
const swapchain_mod = @import("swapchain.zig");
const Swapchain = swapchain_mod.Swapchain;
const depth_mod = @import("depth.zig");
const DepthBuffer = depth_mod.DepthBuffer;
const pipeline_mod = @import("pipeline.zig");
const RenderPass = pipeline_mod.RenderPass;
const Pipeline = pipeline_mod.Pipeline;
const memory_mod = @import("memory.zig");
const Uploader = memory_mod.Uploader;
const mesh_mod = @import("mesh.zig");
const GpuMesh = mesh_mod.GpuMesh;
const texture_mod = @import("texture.zig");
const TexturePool = texture_mod.TexturePool;
const GpuTexture = texture_mod.GpuTexture;
const skinning_mod = @import("skinning.zig");
const BonePool = skinning_mod.BonePool;
const shadow_mod = @import("shadow.zig");
const ShadowMap = shadow_mod.ShadowMap;
const ShadowSet = shadow_mod.ShadowSet;
const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;
const DrawItem = renderer_mod.DrawItem;
const math_mod = @import("../math/math.zig");

/// Compiled from shaders/mesh.slang by build.zig. Aligned because SPIR-V is read
/// as 32-bit words.
const mesh_spv align(4) = @embedFile("mesh_spv").*;
const skinned_spv align(4) = @embedFile("skinned_spv").*;
const shadow_spv align(4) = @embedFile("shadow_spv").*;

/// Vulkan 1.3: widely supported by current drivers, and new enough for dynamic
/// rendering and synchronization2. Spelled out rather than taken from the
/// header, because VK_MAKE_API_VERSION is a function-like macro that translate-c
/// does not reliably import.
const api_version: u32 = (0 << 29) | (1 << 22) | (3 << 12) | 0;

const validation_layer = "VK_LAYER_KHRONOS_validation";
const enable_validation = builtin.mode == .Debug;

const max_extensions = 16;

fn debugCallback(
    severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    kind: c.VkDebugUtilsMessageTypeFlagsEXT,
    data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) c.VkBool32 {
    _ = kind;
    _ = user_data;

    const label = if (severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT != 0)
        "error"
    else if (severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT != 0)
        "warning"
    else
        "info";

    if (data != null and data.*.pMessage != null) {
        std.debug.print("[vulkan {s}] {s}\n", .{ label, data.*.pMessage });
    }
    // VK_FALSE: report the problem but let the call proceed.
    return c.VK_FALSE;
}

fn debugMessengerInfo() c.VkDebugUtilsMessengerCreateInfoEXT {
    return .{
        .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .pNext = null,
        .flags = 0,
        .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debugCallback,
        .pUserData = null,
    };
}

/// Is the validation layer actually installed? Asking beats assuming: the layer
/// ships with the SDK, not with the driver, so a machine with Vulkan can still
/// lack it.
fn hasValidationLayer(allocator: std.mem.Allocator) !bool {
    var count: u32 = 0;
    try check(c.vkEnumerateInstanceLayerProperties(&count, null), "vkEnumerateInstanceLayerProperties");
    if (count == 0) return false;

    const layers = try allocator.alloc(c.VkLayerProperties, count);
    defer allocator.free(layers);
    try check(c.vkEnumerateInstanceLayerProperties(&count, layers.ptr), "vkEnumerateInstanceLayerProperties");

    for (layers) |layer| {
        const name = std.mem.sliceTo(&layer.layerName, 0);
        if (std.mem.eql(u8, name, validation_layer)) return true;
    }
    return false;
}

pub const Context = struct {
    instance: c.VkInstance,
    /// Null when validation is off, or when the layer was not installed.
    messenger: c.VkDebugUtilsMessengerEXT,
    surface: c.VkSurfaceKHR,
    device: Device,
    swapchain: Swapchain,
    depth: DepthBuffer,
    render_pass: RenderPass,
    pipeline: Pipeline,
    renderer: Renderer,
    uploader: Uploader,
    textures: TexturePool,
    skinned_pipeline: Pipeline,
    bones: BonePool,
    shadow: ShadowMap,
    shadow_pipeline: Pipeline,
    shadow_set: ShadowSet,

    pub fn init(allocator: std.mem.Allocator, window: *Window, width: u32, height: u32) !Context {
        const validate = enable_validation and try hasValidationLayer(allocator);
        if (enable_validation and !validate) {
            std.debug.print(
                "warning: {s} not found; running without validation\n",
                .{validation_layer},
            );
        }

        // SDL knows which surface extensions this platform needs (VK_KHR_surface
        // plus a per-OS one); asking it is how the same code works everywhere.
        var sdl_count: u32 = 0;
        const sdl_exts = c.SDL_Vulkan_GetInstanceExtensions(&sdl_count);
        if (sdl_exts == null) {
            std.debug.print("SDL_Vulkan_GetInstanceExtensions failed: {s}\n", .{c.SDL_GetError()});
            return Error.MissingDebugUtils;
        }

        var extensions: [max_extensions][*c]const u8 = undefined;
        var n: usize = 0;
        if (sdl_count + 1 > max_extensions) return Error.TooManyExtensions;
        for (0..sdl_count) |i| {
            extensions[n] = sdl_exts[i];
            n += 1;
        }
        if (validate) {
            extensions[n] = c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
            n += 1;
        }

        const app_info = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "LegendEngine",
            .applicationVersion = 1,
            .pEngineName = "LegendEngine",
            .engineVersion = 1,
            .apiVersion = api_version,
        };

        const layers = [_][*c]const u8{validation_layer};

        // Chaining the messenger info into pNext is what catches errors *during*
        // instance creation and destruction, which the messenger itself cannot.
        var messenger_info = debugMessengerInfo();

        const create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = if (validate) &messenger_info else null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = if (validate) 1 else 0,
            .ppEnabledLayerNames = if (validate) &layers else null,
            .enabledExtensionCount = @intCast(n),
            .ppEnabledExtensionNames = &extensions,
        };

        var instance: c.VkInstance = null;
        try check(c.vkCreateInstance(&create_info, null, &instance), "vkCreateInstance");
        errdefer c.vkDestroyInstance(instance, null);

        var messenger: c.VkDebugUtilsMessengerEXT = null;
        if (validate) {
            // Extension entry points are not exported by the loader; they have to
            // be fetched from the instance by name.
            const create = @as(
                c.PFN_vkCreateDebugUtilsMessengerEXT,
                @ptrCast(c.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT")),
            ) orelse return Error.MissingDebugUtils;
            try check(
                create(instance, &messenger_info, null, &messenger),
                "vkCreateDebugUtilsMessengerEXT",
            );
        }
        errdefer if (messenger != null) destroyMessenger(instance, messenger);

        const surface = try window.createVulkanSurface(instance);
        errdefer window.destroyVulkanSurface(instance, surface);

        // The surface has to exist first: choosing a GPU means asking which one
        // can actually present to *this* surface.
        var device = try Device.init(allocator, instance, surface);
        errdefer device.deinit();

        var swapchain = try Swapchain.init(allocator, &device, surface, width, height);
        errdefer swapchain.deinit();

        var depth = try DepthBuffer.init(&device, swapchain.extent);
        errdefer depth.deinit();

        // The render pass needs the swapchain's format; the framebuffers need
        // both. This ordering is forced by the dependencies, not by taste.
        var render_pass = try RenderPass.init(device.handle, swapchain.format, depth.format);
        errdefer render_pass.deinit();

        try swapchain.createFramebuffers(render_pass.handle, depth.view);

        var textures = try TexturePool.init(&device);
        errdefer textures.deinit();

        var bones = try BonePool.init(&device);
        errdefer bones.deinit();

        var shadow = try ShadowMap.init(&device);
        errdefer shadow.deinit();

        var shadow_set = try ShadowSet.init(&device, &shadow);
        errdefer shadow_set.deinit();

        var shadow_pipeline = try Pipeline.initShadow(
            device.handle,
            shadow.render_pass,
            &shadow_spv,
        );
        errdefer shadow_pipeline.deinit();

        var pipeline = try Pipeline.init(
            device.handle,
            render_pass.handle,
            &mesh_spv,
            textures.layout.handle,
            bones.layout.handle,
            shadow_set.layout,
        );
        errdefer pipeline.deinit();

        var skinned_pipeline = try Pipeline.initSkinned(
            device.handle,
            render_pass.handle,
            &skinned_spv,
            textures.layout.handle,
            bones.layout.handle,
            shadow_set.layout,
        );
        errdefer skinned_pipeline.deinit();

        var renderer = try Renderer.init(&device, &swapchain);
        errdefer renderer.deinit();

        const uploader = try Uploader.init(&device);

        return .{
            .instance = instance,
            .messenger = messenger,
            .surface = surface,
            .device = device,
            .swapchain = swapchain,
            .depth = depth,
            .render_pass = render_pass,
            .pipeline = pipeline,
            .skinned_pipeline = skinned_pipeline,
            .bones = bones,
            .shadow = shadow,
            .shadow_pipeline = shadow_pipeline,
            .shadow_set = shadow_set,
            .renderer = renderer,
            .uploader = uploader,
            .textures = textures,
        };
    }

    /// Vulkan objects must be destroyed in reverse order of creation, and every
    /// child must go before its parent.
    pub fn deinit(self: *Context, window: *Window) void {
        self.renderer.deinit(); // waits for the GPU to go idle
        self.textures.deinit();
        self.uploader.deinit();
        self.pipeline.deinit();
        self.skinned_pipeline.deinit();
        self.bones.deinit();
        self.shadow_pipeline.deinit();
        self.shadow_set.deinit();
        self.shadow.deinit();
        self.render_pass.deinit();
        self.depth.deinit();
        self.swapchain.deinit();
        self.device.deinit();
        window.destroyVulkanSurface(self.instance, self.surface);
        if (self.messenger != null) destroyMessenger(self.instance, self.messenger);
        c.vkDestroyInstance(self.instance, null);
        self.* = undefined;
    }

    /// Uploads a CPU mesh to GPU memory. The caller owns the result and must
    /// destroy it before the context goes.
    pub fn uploadMesh(self: *Context, allocator: std.mem.Allocator, mesh: Mesh) !GpuMesh {
        return GpuMesh.init(allocator, &self.uploader, mesh.vertices, mesh.indices);
    }

    /// Uploads a CPU mesh as a skinned mesh -- packed with joints and weights
    /// for the skinning pipeline. The caller owns the result.
    pub fn uploadSkinnedMesh(self: *Context, allocator: std.mem.Allocator, mesh: Mesh) !GpuMesh {
        return GpuMesh.initSkinned(allocator, &self.uploader, mesh.vertices, mesh.indices);
    }

    /// Uploads RGBA8 pixels as a sampled texture, ready to bind. The caller owns
    /// the result and must destroy it before the context goes.
    pub fn uploadTexture(
        self: *Context,
        pixels: []const u8,
        width: u32,
        height: u32,
    ) !GpuTexture {
        var image = try self.uploader.uploadImage(pixels, width, height);
        errdefer image.deinit();
        const set = try self.textures.bind(&image);
        return .{ .image = image, .set = set };
    }

    /// Draws one frame. Returns without drawing if the swapchain went stale --
    /// a resize, typically -- which is normal and not an error.
    pub fn drawFrame(self: *Context, items: []const DrawItem, shadow_data_set: c.VkDescriptorSet) !void {
        const res = renderer_mod.FrameResources{
            .render_pass = self.render_pass.handle,
            .pipeline = self.pipeline.handle,
            .layout = self.pipeline.layout,
            .skinned_pipeline = self.skinned_pipeline.handle,
            .skinned_layout = self.skinned_pipeline.layout,
            .shadow_pass = self.shadow.render_pass,
            .shadow_framebuffer = self.shadow.framebuffer,
            .shadow_pipeline = self.shadow_pipeline.handle,
            .shadow_layout = self.shadow_pipeline.layout,
            .shadow_extent = .{ .width = shadow_mod.resolution, .height = shadow_mod.resolution },
            .shadow_data_set = shadow_data_set,
        };
        self.renderer.drawFrame(&self.swapchain, res, items) catch |err| switch (err) {
            error.SwapchainLost => return, // recreation lands in the next step
            else => return err,
        };
    }

    /// Writes skinning matrices into the current frame's bone buffer and returns
    /// the descriptor set that binds it. The returned set goes into a DrawItem's
    /// bone_set to route it through the skinning pipeline. Must be called before
    /// drawFrame each frame, since it targets the frame drawFrame will use.
    pub fn updateBones(self: *Context, matrices: []const math_mod.Mat4) !c.VkDescriptorSet {
        const frame = self.renderer.frame;
        try self.bones.upload(frame, matrices);
        return self.bones.sets[frame];
    }

    /// Writes this frame's light matrix and direction into the shadow uniform
    /// buffer, returning the set that binds it together with the shadow map.
    /// Call before drawFrame, like updateBones.
    pub fn updateShadow(self: *Context, uniform: shadow_mod.ShadowUniform) !c.VkDescriptorSet {
        return self.shadow_set.update(self.renderer.frame, uniform);
    }

    /// Blocks until the GPU has finished everything. Call before destroying any
    /// resource the GPU might still be reading -- meshes, textures, buffers.
    pub fn waitIdle(self: *Context) void {
        _ = c.vkDeviceWaitIdle(self.device.handle);
    }
};

fn destroyMessenger(instance: c.VkInstance, messenger: c.VkDebugUtilsMessengerEXT) void {
    const destroy = @as(
        c.PFN_vkDestroyDebugUtilsMessengerEXT,
        @ptrCast(c.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT")),
    ) orelse return;
    destroy(instance, messenger, null);
}
