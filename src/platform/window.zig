//! Platform layer: an SDL3 window that presents a Framebuffer and collects input.

const std = @import("std");
const Framebuffer = @import("../render/framebuffer.zig").Framebuffer;

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL3/SDL.h");
});

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
};

pub const Window = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,
    w: c_int,
    h: c_int,

    pub fn init(title: [*:0]const u8, w: u32, h: u32) !Window {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlInit;
        }
        errdefer c.SDL_Quit();

        const win = c.SDL_CreateWindow(title, @intCast(w), @intCast(h), 0) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlWindow;
        };
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

    pub fn deinit(self: *Window) void {
        c.SDL_DestroyTexture(self.texture);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn present(self: *Window, fb: Framebuffer) void {
        const pitch: c_int = self.w * 3;
        _ = c.SDL_UpdateTexture(self.texture, null, @ptrCast(fb.color.pixels.ptr), pitch);
        _ = c.SDL_RenderClear(self.renderer);
        _ = c.SDL_RenderTexture(self.renderer, self.texture, null, null);
        _ = c.SDL_RenderPresent(self.renderer);
    }

    pub fn pollInput(self: *Window) Input {
        _ = self;
        var input = Input{};

        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            if (ev.type == c.SDL_EVENT_QUIT) {
                input.quit = true;
            } else if (ev.type == c.SDL_EVENT_KEY_DOWN and !ev.key.repeat) {
                switch (ev.key.scancode) {
                    c.SDL_SCANCODE_P => input.toggle_pause = true,
                    c.SDL_SCANCODE_Z => input.spawn = true,
                    c.SDL_SCANCODE_X => input.despawn = true,
                    c.SDL_SCANCODE_ESCAPE => input.quit = true,
                    else => {},
                }
            }
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
};
