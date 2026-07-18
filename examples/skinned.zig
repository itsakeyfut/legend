//! Skinned mesh, loaded through the ordinary asset path.
//!
//! CesiumMan is rigged: its mesh carries per-vertex joints and weights, and the
//! file names a skeleton. load_gltf detects the skin, uploads the mesh through
//! the skinning pipeline, builds the skeleton, and binds it to the object --
//! exactly as Duck flows through the static path. buildDrawList then poses the
//! skeleton and routes the object to the skinning shader. At bind pose the
//! skinning matrices are identity, so a correct pipeline shows CesiumMan
//! standing undistorted, upright, with no by-hand correction: the file's own
//! Z-up root node is folded into its world matrix like any other transform.
//!
//!   zig build run-skinned
//!   zig build run-skinned -- path/to/model.glb

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

    const model_path: []const u8 = if (args.len >= 2) args[1] else "assets/gltf/CesiumMan.glb";

    const width: u32 = 960;
    const height: u32 = 640;

    var win = try legend.Window.init("LegendEngine - Skinned", width, height);
    defer win.deinit();

    var ctx = try gpu.Context.init(gpa, &win, width, height);
    defer ctx.deinit(&win);

    var assets = try Assets.init(gpa, &ctx);
    defer assets.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit();

    // CesiumMan's texture is JPEG, which the engine doesn't decode; nodes with
    // no usable base-color texture fall back to this flat tint over white.
    const fallback = math.vec3(0.8, 0.8, 0.85);
    try legend.load_gltf.load(io, gpa, &assets, &scene, fallback, model_path);

    std.debug.print("loaded {s}\n", .{model_path});

    // -- loop -------------------------------------------------------------
    // CesiumMan is ~1.6 units tall; sit the camera close.
    var camera = Camera{ .position = math.vec3(0, 1, 3) };
    win.setMouseCaptured(true);

    const move_speed: f32 = 2.0;
    const mouse_sensitivity: f32 = 0.0025;

    var items: [256]gpu.DrawItem = undefined;

    var fps = legend.FpsCounter{};
    var title_buf: [160]u8 = undefined;
    var last_ms = win.ticks();
    var anim_time: f32 = 0;

    while (true) {
        const now_ms = win.ticks();
        const elapsed_ms = now_ms - last_ms;
        const dt = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
        last_ms = now_ms;

        if (fps.tick(elapsed_ms)) {
            const title = std.fmt.bufPrintZ(
                &title_buf,
                "LegendEngine - Skinned | {d:.1} fps",
                .{fps.fps},
            ) catch "LegendEngine - Skinned";
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

        anim_time += dt;
        if (anim_time > 2.0) anim_time -= 2.0;
        const list = legend.buildDrawList(&scene, &assets, &ctx, camera, aspect, anim_time, &items);
        try ctx.drawFrame(list);
    }

    ctx.waitIdle();
}
