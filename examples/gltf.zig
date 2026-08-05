//! Loading a model from a .glb file.
//!
//! Duck.glb exercises the whole path at once: container, accessors, mesh with
//! UVs, node hierarchy, and -- the part Box could not reach -- a base-color PNG
//! texture, decoded and uploaded. If the duck shows up yellow and textured, all
//! of it works, Paeth filtering included.
//!
//!   zig build run-gltf
//!   zig build run-gltf -- path/to/model.glb

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const Camera = legend.Camera;
const gpu = legend.gpu;

const Assets = legend.Assets;
const Scene = legend.Scene;
const action = legend.action;

/// What this example can be asked to do. The engine knows none of these names --
/// they are declared here, and the map is built around them.
const Action = enum {
    move_x,
    move_y,
    move_z,
    look_x,
    look_y,
    toggle_mouse,
    quit,
};

const Input = action.Map(Action);

/// Always active, underneath whatever else is pushed: the keys that mean the
/// same thing no matter what the game is doing.
const globals = Input.Context{
    .name = "globals",
    .bindings = &.{
        .{ .source = .{ .key = .escape }, .action = .quit },
        .{ .source = .{ .key = .tab }, .action = .toggle_mouse },
    },
};

/// Flying the camera around to look at the scene. Later this sits alongside a
/// gameplay context that binds the same keys to moving the character.
const free_camera = Input.Context{
    .name = "free camera",
    .bindings = &.{
        .{ .source = .{ .key = .d }, .action = .move_x, .scale = 1 },
        .{ .source = .{ .key = .a }, .action = .move_x, .scale = -1 },
        .{ .source = .{ .key = .space }, .action = .move_y, .scale = 1 },
        .{ .source = .{ .key = .lshift }, .action = .move_y, .scale = -1 },
        .{ .source = .{ .key = .w }, .action = .move_z, .scale = 1 },
        .{ .source = .{ .key = .s }, .action = .move_z, .scale = -1 },
        .{ .source = .mouse_x, .action = .look_x, .scale = 1 },
        // Screen y grows downward, and looking down should lower the pitch.
        .{ .source = .mouse_y, .action = .look_y, .scale = -1 },
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const model_path: []const u8 = if (args.len >= 2) args[1] else "assets/gltf/Duck.glb";

    const width: u32 = 960;
    const height: u32 = 640;

    var win = try legend.Window.init("LegendEngine - glTF", width, height);
    defer win.deinit();

    var ctx = try gpu.Context.init(gpa, &win, width, height);
    defer ctx.deinit(&win);

    var assets = try Assets.init(gpa, &ctx);
    defer assets.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit();

    // The model brings its own textures; the tint is only a fallback for any
    // node whose material has no base-color texture.
    const fallback = math.vec3(0.8, 0.8, 0.85);
    _ = try legend.load_gltf.load(io, gpa, &assets, &scene, fallback, model_path);

    std.debug.print("loaded {s}\n", .{model_path});

    // -- loop -------------------------------------------------------------
    var camera = Camera{ .position = math.vec3(0, 1, 4) };
    win.setMouseCaptured(true);

    const move_speed: f32 = 5.0;
    const mouse_sensitivity: f32 = 0.0025;

    var items: [256]gpu.DrawItem = undefined;

    var fps = legend.FpsCounter{};
    var title_buf: [160]u8 = undefined;
    var last_ms = win.ticks();
    var input = Input.init();
    input.push(&globals);
    input.push(&free_camera);

    while (true) {
        const now_ms = win.ticks();
        const elapsed_ms = now_ms - last_ms;
        const dt = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
        last_ms = now_ms;

        if (fps.tick(elapsed_ms)) {
            const title = std.fmt.bufPrintZ(
                &title_buf,
                "LegendEngine - glTF | {d:.1} fps | {d:.2} ms",
                .{ fps.fps, fps.frame_ms },
            ) catch "LegendEngine - glTF";
            win.setTitle(title);
        }

        const raw = win.poll();
        input.update(raw);

        if (raw.quit or input.pressed(.quit)) break;
        if (input.pressed(.toggle_mouse)) win.setMouseCaptured(!win.isMouseCaptured());

        camera.move(
            input.value(.move_x) * move_speed * dt,
            input.value(.move_y) * move_speed * dt,
            input.value(.move_z) * move_speed * dt,
        );
        camera.look(
            input.value(.look_x) * mouse_sensitivity,
            input.value(.look_y) * mouse_sensitivity,
        );

        const aspect = @as(f32, @floatFromInt(ctx.swapchain.extent.width)) /
            @as(f32, @floatFromInt(ctx.swapchain.extent.height));

        const frame = try legend.buildDrawList(&scene, &assets, &ctx, camera, aspect, &items);
        try ctx.drawFrame(frame.items, frame.shadow_set, &.{}, &.{}, .{ .vp0 = .{ 0, 0, 0, 0 }, .vp1 = .{ 0, 0, 0, 0 }, .vp2 = .{ 0, 0, 0, 0 }, .vp3 = .{ 0, 0, 0, 0 } });
    }

    ctx.waitIdle();
}
