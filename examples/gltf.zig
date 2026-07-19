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
    try legend.load_gltf.load(io, gpa, &assets, &scene, fallback, model_path);

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

        const input = win.pollInput();
        if (input.quit) break;
        if (input.toggle_mouse) win.setMouseCaptured(!win.isMouseCaptured());

        var dx: f32 = 0;
        var dy: f32 = 0;
        var dz: f32 = 0;
        if (input.forward) dz += 1;
        if (input.back) dz -= 1;
        if (input.strafe_right) dx += 1;
        if (input.strafe_left) dx -= 1;
        if (input.ascend) dy += 1;
        if (input.descend) dy -= 1;
        camera.move(dx * move_speed * dt, dy * move_speed * dt, dz * move_speed * dt);
        camera.look(
            input.mouse_dx * mouse_sensitivity,
            -input.mouse_dy * mouse_sensitivity,
        );

        const aspect = @as(f32, @floatFromInt(ctx.swapchain.extent.width)) /
            @as(f32, @floatFromInt(ctx.swapchain.extent.height));

        const frame = try legend.buildDrawList(&scene, &assets, &ctx, camera, aspect, 0, &items);
        try ctx.drawFrame(frame.items, frame.shadow_set);
    }

    ctx.waitIdle();
}
