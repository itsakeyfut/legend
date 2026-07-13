//! Platform layer: an SDL3 window that presents a Framebuffer and collects input.

const std = @import("std");
const c = @import("c.zig").c;
const Framebuffer = @import("../render/framebuffer.zig").Framebuffer;

/// One frame of input. Movement/look flags are held-down state; the rest are
/// edges (true only on the frame the key went down).
pub const Input = struct {
    quit: bool = false,

    // Held.
    forward: bool = false,
    back: bool = false,
    strafe_left: bool = false,
    strafe_right: bool = false,
    ascend: bool = false,
    descend: bool = false,
    look_left: bool = false,
    look_right: bool = false,
    look_up: bool = false,
    look_down: bool = false,

    // Edges.
    toggle_pause: bool = false,
    spawn: bool = false,
    despawn: bool = false,
    toggle_mouse: bool = false,

    /// Relative mouse motion for this frame, in pixels. Already a delta, so it
    /// must NOT be scaled by frame time -- doing so would make sensitivity
    /// depend on the frame rate.
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
};

pub const Window = struct {
    window: *c.SDL_Window,
    /// Null under Vulkan: SDL's renderer is only used by the software path.
    renderer: ?*c.SDL_Renderer,
    texture: ?*c.SDL_Texture,
    w: c_int,
    h: c_int,
    mouse_captured: bool = false,

    /// A window backed by SDL's software renderer, presenting a Framebuffer.
    pub fn init(title: [*:0]const u8, w: u32, h: u32) !Window {
        const win = try createWindow(title, w, h, 0);
        errdefer c.SDL_DestroyWindow(win);

        const ren = c.SDL_CreateRenderer(win, null) orelse {
            std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlRenderer;
        };
        errdefer c.SDL_DestroyRenderer(ren);

        // RGB24 matches image.Rgb's byte layout exactly, so the framebuffer
        // can be handed to SDL with no conversion.
        const tex = c.SDL_CreateTexture(
            ren,
            c.SDL_PIXELFORMAT_RGB24,
            c.SDL_TEXTUREACCESS_STREAMING,
            @intCast(w),
            @intCast(h),
        ) orelse {
            std.debug.print("SDL_CreateTexture failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlTexture;
        };

        return .{
            .window = win,
            .renderer = ren,
            .texture = tex,
            .w = @intCast(w),
            .h = @intCast(h),
        };
    }

    /// A window Vulkan can present to. No SDL renderer or texture: Vulkan owns
    /// the swapchain, so SDL's presentation path is bypassed entirely.
    pub fn initVulkan(title: [*:0]const u8, w: u32, h: u32) !Window {
        const win = try createWindow(title, w, h, c.SDL_WINDOW_VULKAN);
        return .{
            .window = win,
            .renderer = null,
            .texture = null,
            .w = @intCast(w),
            .h = @intCast(h),
        };
    }

    fn createWindow(title: [*:0]const u8, w: u32, h: u32, flags: c.SDL_WindowFlags) !*c.SDL_Window {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlInit;
        }
        errdefer c.SDL_Quit();

        return c.SDL_CreateWindow(title, @intCast(w), @intCast(h), flags) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlWindow;
        };
    }

    pub fn deinit(self: *Window) void {
        if (self.texture) |t| c.SDL_DestroyTexture(t);
        if (self.renderer) |r| c.SDL_DestroyRenderer(r);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    /// Software path only; a no-op under Vulkan
    pub fn present(self: *Window, fb: Framebuffer) void {
        const ren = self.renderer orelse return;
        const tex = self.texture orelse return;
        const pitch: c_int = self.w * 3;
        _ = c.SDL_UpdateTexture(tex, null, @ptrCast(fb.color.pixels.ptr), pitch);
        _ = c.SDL_RenderClear(ren);
        _ = c.SDL_RenderTexture(ren, tex, null, null);
        _ = c.SDL_RenderPresent(ren);
    }

    pub fn pollInput(self: *Window) Input {
        var input = Input{};

        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            if (ev.type == c.SDL_EVENT_QUIT) {
                input.quit = true;
            } else if (ev.type == c.SDL_EVENT_MOUSE_MOTION) {
                // Accumulate: SDL may deliver several motion events per frame.
                input.mouse_dx += ev.motion.xrel;
                input.mouse_dy += ev.motion.yrel;
            } else if (ev.type == c.SDL_EVENT_KEY_DOWN and !ev.key.repeat) {
                switch (ev.key.scancode) {
                    c.SDL_SCANCODE_P => input.toggle_pause = true,
                    c.SDL_SCANCODE_Z => input.spawn = true,
                    c.SDL_SCANCODE_X => input.despawn = true,
                    c.SDL_SCANCODE_TAB => input.toggle_mouse = true,
                    c.SDL_SCANCODE_ESCAPE => input.quit = true,
                    else => {},
                }
            }
        }

        // Motion only counts while the cursor is captured; otherwise moving the
        // mouse over the window would swing the camera around.
        if (!self.mouse_captured) {
            input.mouse_dx = 0;
            input.mouse_dy = 0;
        }

        const keys = c.SDL_GetKeyboardState(null);
        input.forward = keys[c.SDL_SCANCODE_W];
        input.back = keys[c.SDL_SCANCODE_S];
        input.strafe_left = keys[c.SDL_SCANCODE_A];
        input.strafe_right = keys[c.SDL_SCANCODE_D];
        input.ascend = keys[c.SDL_SCANCODE_SPACE];
        input.descend = keys[c.SDL_SCANCODE_LSHIFT];
        input.look_left = keys[c.SDL_SCANCODE_LEFT];
        input.look_right = keys[c.SDL_SCANCODE_RIGHT];
        input.look_up = keys[c.SDL_SCANCODE_UP];
        input.look_down = keys[c.SDL_SCANCODE_DOWN];

        return input;
    }

    /// Milliseconds since SDL was initialised. Used to derive delta time.
    pub fn ticks(self: *Window) u64 {
        _ = self;
        return c.SDL_GetTicks();
    }

    pub fn delay(self: *Window, ms: u32) void {
        _ = self;
        c.SDL_Delay(ms);
    }

    /// Replaces the window title. Used to surface frame timings without a
    /// text renderer.
    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        _ = c.SDL_SetWindowTitle(self.window, title);
    }

    /// Hides the cursor, pins it to the window, and switches the mouse to
    /// reporting relative motion. This is what lets the view keep turning past
    /// the edge of the screen.
    pub fn setMouseCaptured(self: *Window, captured: bool) void {
        if (self.mouse_captured == captured) return;
        if (!c.SDL_SetWindowRelativeMouseMode(self.window, captured)) {
            std.debug.print("SDL_SetWindowRelativeMouseMode failed: {s}\n", .{c.SDL_GetError()});
            return;
        }
        self.mouse_captured = captured;
    }

    pub fn isMouseCaptured(self: *Window) bool {
        return self.mouse_captured;
    }

    /// Creates the VkSurfaceKHR this window presents through. The window must
    /// have come from `initVulkan`, and `instance` must have been created with
    /// the extensions SDL asked for.
    pub fn createVulkanSurface(self: *Window, instance: c.VkInstance) !c.VkSurfaceKHR {
        var surface: c.VkSurfaceKHR = null;
        if (!c.SDL_Vulkan_CreateSurface(self.window, instance, null, &surface)) {
            std.debug.print("SDL_Vulkan_CreateSurface failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlVulkanSurface;
        }
        return surface;
    }

    pub fn destroyVulkanSurface(self: *Window, instance: c.VkInstance, surface: c.VkSurfaceKHR) void {
        _ = self;
        c.SDL_Vulkan_DestroySurface(instance, surface, null);
    }
};
