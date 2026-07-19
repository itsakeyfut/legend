//! Platform layer: an SDL3 window Vulkan presents to, and per-frame input.

const std = @import("std");
const c = @import("c.zig").c;

/// The physical keys the engine can bind.
///
/// A named subset rather than SDL's whole scancode table: what an engine binds
/// should be its own contract, not "whatever the windowing library happens to
/// define". Adding one is a line here and a line in `scancode`.
pub const Key = enum {
    w,
    a,
    s,
    d,
    q,
    e,
    space,
    lshift,
    rshift,
    lctrl,
    rctrl,
    tab,
    escape,
    f1,
    f2,
    left,
    right,
    up,
    down,
};

pub const key_count = @typeInfo(Key).@"enum".fields.len;

fn scancode(key: Key) c_uint {
    return switch (key) {
        .w => c.SDL_SCANCODE_W,
        .a => c.SDL_SCANCODE_A,
        .s => c.SDL_SCANCODE_S,
        .d => c.SDL_SCANCODE_D,
        .q => c.SDL_SCANCODE_Q,
        .e => c.SDL_SCANCODE_E,
        .space => c.SDL_SCANCODE_SPACE,
        .lshift => c.SDL_SCANCODE_LSHIFT,
        .rshift => c.SDL_SCANCODE_RSHIFT,
        .lctrl => c.SDL_SCANCODE_LCTRL,
        .rctrl => c.SDL_SCANCODE_RCTRL,
        .tab => c.SDL_SCANCODE_TAB,
        .escape => c.SDL_SCANCODE_ESCAPE,
        .f1 => c.SDL_SCANCODE_F1,
        .f2 => c.SDL_SCANCODE_F2,
        .left => c.SDL_SCANCODE_LEFT,
        .right => c.SDL_SCANCODE_RIGHT,
        .up => c.SDL_SCANCODE_UP,
        .down => c.SDL_SCANCODE_DOWN,
    };
}

/// The physical state of the input devices this frame, with no meaning attached.
///
/// "W is down" and "the mouse moved 3 pixels" -- nothing about forward, nothing
/// about looking. Turning that into what the game means is the action map's job
/// (platform/action.zig), and keeping the two apart is what lets the same key
/// mean different things in different contexts.
pub const Raw = struct {
    /// The window was closed. Not a key, so not bindable.
    quit: bool = false,
    /// Down this frame, indexed by @intFromEnum(Key).
    keys: [key_count]bool = .{false} ** key_count,
    /// Relative mouse motion in pixels. Already a delta, so it must NOT be
    /// scaled by frame time -- that would make sensitivity depend on frame rate.
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,

    pub fn down(self: Raw, key: Key) bool {
        return self.keys[@intFromEnum(key)];
    }
};

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
    w: c_int,
    h: c_int,
    mouse_captured: bool = false,

    /// The window Vulkan presents to. SDL owns no renderer or texture; the
    /// swapchain does all presentation.
    pub fn init(title: [*:0]const u8, w: u32, h: u32) !Window {
        const win = try createWindow(title, w, h, c.SDL_WINDOW_VULKAN);
        return .{
            .window = win,
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
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    /// Polls the window and returns the physical state of the devices. The
    /// action map turns this into what the game means.
    pub fn poll(self: *Window) Raw {
        var raw = Raw{};

        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            if (ev.type == c.SDL_EVENT_QUIT) {
                raw.quit = true;
            } else if (ev.type == c.SDL_EVENT_MOUSE_MOTION) {
                // Accumulate: SDL may deliver several motion events per frame.
                raw.mouse_dx += ev.motion.xrel;
                raw.mouse_dy += ev.motion.yrel;
            }
        }

        // Motion only counts while the cursor is captured; otherwise moving the
        // mouse over the window would swing the camera around.
        if (!self.mouse_captured) {
            raw.mouse_dx = 0;
            raw.mouse_dy = 0;
        }

        const keys = c.SDL_GetKeyboardState(null);
        inline for (@typeInfo(Key).@"enum".fields) |field| {
            const key: Key = @enumFromInt(field.value);
            raw.keys[field.value] = keys[scancode(key)];
        }

        return raw;
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
