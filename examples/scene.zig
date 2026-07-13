//! A scene: a ground plane with several models standing on it, each with its
//! own material, explored with a free camera.
//!
//!   zig build run-scene
//!   zig build run-scene -- path/to/model.obj
//!
//! WASD to move, Space / LShift for up and down, mouse to look (Tab releases
//! the cursor), P to pause the spin, Esc to quit.

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const procedural = legend.image.procedural;
const Framebuffer = legend.Framebuffer;
const Mesh = legend.Mesh;
const Camera = legend.Camera;
const Scene = legend.Scene;
const Light = legend.Light;
const ObjectHandle = legend.ObjectHandle;

/// Game-side data. The engine's Object holds mesh + material + transform;
/// behaviour like "how fast does this spin" belongs to the game.
const Spinner = struct {
    handle: ObjectHandle,
    spin: f32, // radians per second
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const model_path: []const u8 = if (args.len >= 2) args[1] else "assets/torus.obj";

    const width: u32 = 960;
    const height: u32 = 640;

    var fb = try Framebuffer.init(gpa, width, height);
    defer fb.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit(); // frees every mesh and texture it owns

    // -- meshes -----------------------------------------------------------
    const ground_mesh = try scene.addMesh(try Mesh.plane(gpa, 60, 30));
    const cube_mesh = try scene.addMesh(try Mesh.cube(gpa));
    const model_mesh = try scene.addMesh(try legend.obj.load(io, gpa, model_path));

    // -- textures ---------------------------------------------------------
    // One grid texel repeated across the floor: a bare plane gives the eye no
    // sense of speed or distance, and this is the cheapest way to give it one.
    const grid_tex = try scene.addTexture(try procedural.grid(
        gpa,
        64,
        3,
        .{ .r = 90, .g = 100, .b = 120 },
        .{ .r = 32, .g = 36, .b = 46 },
    ));
    const checker_tex = try scene.addTexture(try procedural.checker(
        gpa,
        256,
        8,
        .{ .r = 235, .g = 235, .b = 235 },
        .{ .r = 70, .g = 70, .b = 80 },
    ));

    // -- materials --------------------------------------------------------
    const ground_mat = try scene.addMaterial(.{
        .texture = grid_tex,
        .ambient = 0.45, // the floor has nothing bouncing light back onto it
        .diffuse = 0.55,
    });
    // Four looks from a single checker texture: only the tint differs.
    const warm = try scene.addMaterial(.{ .texture = checker_tex, .tint = math.vec3(1.0, 0.55, 0.4) });
    const cool = try scene.addMaterial(.{ .texture = checker_tex, .tint = math.vec3(0.4, 0.65, 1.0) });
    const lime = try scene.addMaterial(.{ .texture = checker_tex, .tint = math.vec3(0.6, 1.0, 0.45) });
    // No texture at all: the scene's 1x1 white texel plus a tint is a flat colour.
    const gold = try scene.addMaterial(.{
        .texture = scene.white,
        .tint = math.vec3(0.95, 0.8, 0.3),
        .ambient = 0.15,
    });

    // -- objects ----------------------------------------------------------
    _ = try scene.addObject(ground_mesh, ground_mat, .{ .position = math.vec3(0, -1.5, 0) });

    var spinners: [16]Spinner = undefined;
    var spinner_n: usize = 0;

    // Three copies of the loaded model, each with a different material. They
    // share one mesh: the handle is copied, the geometry is not.
    const models = [_]struct { x: f32, mat: legend.MaterialHandle, spin: f32 }{
        .{ .x = -5, .mat = warm, .spin = 0.6 },
        .{ .x = 0, .mat = cool, .spin = -0.4 },
        .{ .x = 5, .mat = lime, .spin = 0.9 },
    };
    for (models) |m| {
        const h = try scene.addObject(model_mesh, m.mat, .{
            .position = math.vec3(m.x, 0.2, 0),
        });
        spinners[spinner_n] = .{ .handle = h, .spin = m.spin };
        spinner_n += 1;
    }

    // A row of cubes behind them, to give the space some depth.
    var i: i32 = -3;
    while (i <= 3) : (i += 1) {
        const x: f32 = @floatFromInt(i);
        const mat = if (@mod(i, 2) == 0) gold else cool;
        _ = try scene.addObject(cube_mesh, mat, .{
            .position = math.vec3(x * 3.0, -0.9, -9),
            .scale = math.vec3(0.6, 0.6, 0.6),
        });
    }

    // -- render loop ------------------------------------------------------
    const light = Light{ .dir = math.vec3(0.35, 0.85, 0.4).normalize() };

    var camera = Camera{ .position = math.vec3(0, 1.5, 12) };
    var win = try legend.Window.init("LegendEngine - Scene", width, height);
    defer win.deinit();
    win.setMouseCaptured(true); // Tab gives the cursor back

    const move_speed: f32 = 7.0;
    const look_speed: f32 = 1.8; // radians per second, for the arrow keys
    const mouse_sensitivity: f32 = 0.0025; // radians per pixel
    var auto_spin = true;

    var fps = legend.FpsCounter{};
    var title_buf: [160]u8 = undefined;
    var last_ms = win.ticks();

    while (true) {
        const now_ms = win.ticks();
        const elapsed_ms = now_ms - last_ms;
        const dt = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
        last_ms = now_ms;

        if (fps.tick(elapsed_ms)) {
            const mouse = if (win.isMouseCaptured()) "mouse on" else "mouse off";
            const title = std.fmt.bufPrintZ(
                &title_buf,
                "LegendEngine - Scene | {d:.1} fps | {d:.2} ms | {d} objects | {s} (Tab)",
                .{ fps.fps, fps.frame_ms, scene.objectCount(), mouse },
            ) catch "LegendEngine - Scene";
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

        var dyaw: f32 = 0;
        var dpitch: f32 = 0;
        if (input.look_right) dyaw += 1;
        if (input.look_left) dyaw -= 1;
        if (input.look_up) dpitch += 1;
        if (input.look_down) dpitch -= 1;
        camera.look(dyaw * look_speed * dt, dpitch * look_speed * dt);

        // Not scaled by dt: the mouse delta is a distance, not a rate.
        camera.look(
            input.mouse_dx * mouse_sensitivity,
            -input.mouse_dy * mouse_sensitivity,
        );

        if (auto_spin) {
            for (spinners[0..spinner_n]) |sp| {
                const obj = scene.object(sp.handle) orelse continue;
                obj.transform.rotation.v[1] += sp.spin * dt;
            }
        }

        fb.clear(legend.rgb(18, 20, 28));
        scene.render(&fb, camera, light);
        win.present(fb);
        win.delay(1);
    }
}
