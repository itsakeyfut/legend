//! A scene, on the GPU: built from Assets and Scene, drawn through a flat draw
//! list. A little solar system, to show what parenting buys -- a moon pinned to
//! a planet pinned to a sun, each carried by the one above without knowing it.
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
    toggle_spin,
};

const Input = action.Map(Action);

/// Always active, underneath whatever else is pushed: the keys that mean the
/// same thing no matter what the game is doing.
const globals = Input.Context{
    .name = "globals",
    .bindings = &.{
        .{ .source = .{ .key = .escape }, .action = .quit },
        .{ .source = .{ .key = .tab }, .action = .toggle_mouse },
        .{ .source = .{ .key = .p }, .action = .toggle_spin },
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

    // -- scene: a little solar system --------------------------------------
    // Three levels of hierarchy, so the parent chain is exercised more than
    // once: a moon pinned to a planet pinned to a sun. Watch what "parent" buys
    // -- the planet's orbit carries the moon with it, for free.
    var scene = try Scene.init(gpa);
    defer scene.deinit();

    const sun_mat = try scene.addMaterial(.{ .texture = checker, .tint = math.vec3(1.0, 0.9, 0.4) });
    const planet_mat = try scene.addMaterial(.{ .texture = dice });
    const moon_mat = try scene.addMaterial(.{ .texture = grid, .tint = math.vec3(0.7, 0.8, 1.0) });

    // The sun sits at the origin, a little up, and only spins.
    const sun = try scene.addObject(model, sun_mat, .{
        .position = math.vec3(0, 1.5, 0),
        .scale = math.vec3(1.5, 1.5, 1.5),
    });

    // The planet is a child of the sun. Its position is *relative to the sun*,
    // so this 6 units stays 6 units from the sun wherever the sun goes.
    const planet = try scene.addChild(sun, cube, planet_mat, .{
        .position = math.vec3(6, 0, 0),
    });

    // The moon is a child of the planet: relative to the planet, 2 units out.
    // Nothing here mentions the sun, yet the moon will follow it.
    _ = try scene.addChild(planet, cube, moon_mat, .{
        .position = math.vec3(2, 0, 0),
        .scale = math.vec3(0.4, 0.4, 0.4),
    });

    // A ground plane, unparented -- a plain world-space root for contrast.
    const ground_mat = try scene.addMaterial(.{ .texture = grid });
    _ = try scene.addObject(ground_mesh, ground_mat, .{ .position = math.vec3(0, -2.0, 0) });

    // -- loop -------------------------------------------------------------
    var camera = Camera{ .position = math.vec3(0, 2.5, 16) };
    win.setMouseCaptured(true);

    const move_speed: f32 = 7.0;
    const mouse_sensitivity: f32 = 0.0025;
    var auto_spin = true;
    var elapsed: f32 = 0;

    var items: [64]gpu.DrawItem = undefined;

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
                "LegendEngine - Vulkan | {d:.1} fps | {d:.2} ms | {d} tris",
                .{ fps.fps, fps.frame_ms, model_tris },
            ) catch "LegendEngine - Vulkan";
            win.setTitle(title);
        }

        const raw = win.poll();
        input.update(raw);

        if (raw.quit or input.pressed(.quit)) break;
        if (input.pressed(.toggle_mouse)) win.setMouseCaptured(!win.isMouseCaptured());
        if (input.pressed(.toggle_spin)) auto_spin = !auto_spin;

        camera.move(
            input.value(.move_x) * move_speed * dt,
            input.value(.move_y) * move_speed * dt,
            input.value(.move_z) * move_speed * dt,
        );
        camera.look(
            input.value(.look_x) * mouse_sensitivity,
            input.value(.look_y) * mouse_sensitivity,
        );

        if (auto_spin) {
            elapsed += dt;

            // The sun spins in place: a child sees this as its parent turning,
            // so the planet's whole orbit rotates with it.
            if (scene.object(sun)) |obj| {
                obj.transform.rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), elapsed * 0.5);
            }
            // The planet spins about its own centre. Because the moon is its
            // child, the moon orbits the planet as a result -- without the moon
            // knowing anything about it.
            if (scene.object(planet)) |obj| {
                obj.transform.rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), elapsed * 1.5);
            }
        }

        const aspect = @as(f32, @floatFromInt(ctx.swapchain.extent.width)) /
            @as(f32, @floatFromInt(ctx.swapchain.extent.height));

        const frame = try legend.buildDrawList(&scene, &assets, &ctx, camera, aspect, 0, &items);
        try ctx.drawFrame(frame.items, frame.shadow_set, &.{});
    }

    // The GPU may still be reading last frame's meshes and textures when the
    // deferred deinits run.
    ctx.waitIdle();
}
