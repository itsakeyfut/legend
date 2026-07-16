//! Loading a model from a .glb file.
//!
//! Box.glb is deliberately minimal but not trivial: a matrix-transform parent
//! node with a mesh-bearing child. Displaying it correctly exercises the whole
//! glTF path at once -- container, accessors, mesh building, the node hierarchy,
//! and the matrix-to-TRS decomposition -- so if the box shows up tilted and
//! textured, all of it works.
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

    const model_path: []const u8 = if (args.len >= 2) args[1] else "assets/gltf/Box.glb";

    const width: u32 = 960;
    const height: u32 = 640;

    var win = try legend.Window.init("LegendEngine - glTF", width, height);
    defer win.deinit();

    var ctx = try gpu.Context.init(gpa, &win, width, height);
    defer ctx.deinit(&win);

    var assets = try Assets.init(gpa, &ctx);
    defer assets.deinit();

    // A procedural texture, since Box.glb carries no UVs of its own. Once the
    // PNG decoder lands, a textured model like Duck.glb will bring its own.
    var checker_img = try legend.image.procedural.checker(
        gpa,
        256,
        8,
        .{ .r = 210, .g = 180, .b = 140 },
        .{ .r = 40, .g = 30, .b = 30 },
    );
    const checker = try assets.addTexture(checker_img);
    checker_img.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit();

    const material = try scene.addMaterial(.{ .texture = checker, .tint = math.vec3(1, 1, 1) });

    // The whole model: meshes uploaded, node tree walked into the scene, all in
    // one call. Everything the loader touches is behind this line.
    try legend.load_gltf.load(io, gpa, &assets, &scene, material, model_path);

    std.debug.print("loaded {s}\n", .{model_path});

    // -- loop -------------------------------------------------------------
    var camera = Camera{ .position = math.vec3(0, 1.5, 4) };
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

        const list = legend.buildDrawList(&scene, &assets, camera, aspect, &items);
        try ctx.drawFrame(list);
    }

    ctx.waitIdle();
}
