//! A scene, on the GPU: built from Assets and Scene, drawn through a flat draw
//! list. This is the shape the engine actually uses -- the hand-rolled arrays
//! are gone.
//!
//!   zig build run-mesh
//!   zig build run-mesh -- path/to/model.obj

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const Mesh = legend.Mesh;
const Camera = legend.Camera;
const gpu = legend.gpu;

const Assets = legend.Assets;
const Scene = legend.Scene;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const model_path: []const u8 = if (args.len >= 2) args[1] else "assets/torus.obj";

    const width: u32 = 960;
    const height: u32 = 640;

    var win = try legend.Window.init("LegendEngine - Vulkan", width, height);
    defer win.deinit();

    var ctx = try gpu.Context.init(gpa, &win, width, height);
    defer ctx.deinit(&win);

    std.debug.print("gpu: {s}\n", .{ctx.device.deviceName()});

    // -- assets: the GPU-resident half ------------------------------------
    var assets = try Assets.init(gpa, &ctx);
    defer assets.deinit();

    // Meshes. The CPU mesh is freed as soon as it is uploaded; the copy in
    // system RAM is dead weight once the vertices are in device memory.
    var cpu_model = try legend.obj.load(io, gpa, model_path);
    const model_tris = cpu_model.indices.len / 3;
    const model = try assets.addMesh(gpa, cpu_model);
    cpu_model.deinit();

    var cpu_cube = try Mesh.cube(gpa);
    const cube = try assets.addMesh(gpa, cpu_cube);
    cpu_cube.deinit();

    var cpu_ground = try Mesh.plane(gpa, 60, 30);
    const ground_mesh = try assets.addMesh(gpa, cpu_ground);
    cpu_ground.deinit();

    // Textures. Three, so the descriptor-set switching is visible.
    var dice_img = try legend.image.loadQoiRgb(io, gpa, "assets/dice.qoi");
    const dice = try assets.addTexture(dice_img);
    dice_img.deinit();

    var checker_img = try legend.image.procedural.checker(
        gpa,
        256,
        8,
        .{ .r = 220, .g = 220, .b = 225 },
        .{ .r = 60, .g = 60, .b = 70 },
    );
    const checker = try assets.addTexture(checker_img);
    checker_img.deinit();

    var grid_img = try legend.image.procedural.grid(
        gpa,
        128,
        6,
        .{ .r = 90, .g = 100, .b = 120 },
        .{ .r = 45, .g = 50, .b = 62 },
    );
    const grid = try assets.addTexture(grid_img);
    grid_img.deinit();

    std.debug.print("uploaded: {d} triangles, 3 textures\n", .{model_tris});

    // -- scene: the pure-data half ----------------------------------------
    var scene = try Scene.init(gpa);
    defer scene.deinit();

    const grid_mat = try scene.addMaterial(.{ .texture = grid });
    const dice_mat = try scene.addMaterial(.{ .texture = dice });

    // Three tinted materials sharing the one checker texture.
    const tints = [_]math.Vec3{
        math.vec3(1.0, 0.85, 0.7),
        math.vec3(0.7, 1.0, 0.8),
        math.vec3(0.8, 0.8, 1.0),
    };
    var spinner_mats: [3]legend.MaterialHandle = undefined;
    for (&spinner_mats, tints) |*m, tint| {
        m.* = try scene.addMaterial(.{ .texture = checker, .tint = tint });
    }

    // Ground.
    _ = try scene.addObject(ground_mesh, grid_mat, .{ .position = math.vec3(0, -1.5, 0) });

    // The row of dice cubes.
    var i: i32 = -3;
    while (i <= 3) : (i += 1) {
        const x: f32 = @floatFromInt(i);
        _ = try scene.addObject(cube, dice_mat, .{
            .position = math.vec3(x * 3.0, -0.9, -9),
            .scale = math.vec3(0.6, 0.6, 0.6),
        });
    }

    // The three spinning tori. Their handles are kept so they can be rotated.
    var spinners: [3]legend.ObjectHandle = undefined;
    const spin_x = [_]f32{ -5, 0, 5 };
    for (&spinners, spin_x, spinner_mats) |*s, x, mat| {
        s.* = try scene.addObject(model, mat, .{ .position = math.vec3(x, 0.2, 0) });
    }
    const spin_rate = [_]f32{ 0.6, -0.4, 0.9 };
    var spin_angle = [_]f32{ 0, 1.0, 2.0 };

    // -- loop -------------------------------------------------------------
    var camera = Camera{ .position = math.vec3(0, 1.5, 12) };
    win.setMouseCaptured(true);

    const move_speed: f32 = 7.0;
    const mouse_sensitivity: f32 = 0.0025;
    var auto_spin = true;

    var items: [64]gpu.DrawItem = undefined;

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
                "LegendEngine - Vulkan | {d:.1} fps | {d:.2} ms | {d} tris",
                .{ fps.fps, fps.frame_ms, model_tris * spinners.len },
            ) catch "LegendEngine - Vulkan";
            win.setTitle(title);
        }

        const input = win.pollInput();
        if (input.quit) break;
        if (input.toggle_pause) auto_spin = !auto_spin;
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

        if (auto_spin) {
            for (spinners, spin_rate, &spin_angle) |handle, rate, *angle| {
                angle.* += rate * dt;
                if (scene.object(handle)) |obj| {
                    obj.transform.rotation = math.Quat.fromAxisAngle(
                        math.vec3(0, 1, 0),
                        angle.*,
                    );
                }
            }
        }

        const aspect = @as(f32, @floatFromInt(ctx.swapchain.extent.width)) /
            @as(f32, @floatFromInt(ctx.swapchain.extent.height));

        const list = legend.buildDrawList(&scene, &assets, camera, aspect, &items);
        try ctx.drawFrame(list);
    }

    // The GPU may still be reading last frame's meshes and textures when the
    // deferred deinits run.
    ctx.waitIdle();
}
