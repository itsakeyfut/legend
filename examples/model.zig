//! Loads a Wavefront OBJ and shows it with a free camera.
//!
//!   zig build run-model
//!   zig build run-model -- path/to/model.obj
//!   zig build run-model -- path/to/model.obj path/to/texture.qoi
//!
//! WASD to move, Space / LShift for up and down, mouse to look (Tab releases
//! the cursor), arrow keys to look without the mouse, P to pause the spin.

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const Framebuffer = legend.Framebuffer;
const Camera = legend.Camera;
const Scene = legend.Scene;
const Light = legend.Light;
const Texture = legend.Texture;

fn makeChecker(allocator: std.mem.Allocator, size: u32, cells: u32) !Texture {
    var tex = try Texture.init(allocator, size, size);
    const cell = size / cells;
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const on = ((x / cell) + (y / cell)) % 2 == 0;
            tex.at(x, y).* = if (on)
                .{ .r = 230, .g = 230, .b = 240 }
            else
                .{ .r = 40, .g = 40, .b = 70 };
        }
    }
    return tex;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const model_path: []const u8 = if (args.len >= 2) args[1] else "assets/torus.obj";
    const tex_path: ?[]const u8 = if (args.len >= 3) args[2] else null;

    const width: u32 = 800;
    const height: u32 = 600;

    var fb = try Framebuffer.init(gpa, width, height);
    defer fb.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit();

    const base = blk: {
        if (tex_path) |p| {
            break :blk legend.image.loadQoiRgb(io, gpa, p) catch |err| {
                std.debug.print("failed to load {s}: {any}; using checker\n", .{ p, err });
                break :blk try makeChecker(gpa, 512, 16);
            };
        }
        break :blk try makeChecker(gpa, 512, 16);
    };
    const texture = try scene.addTexture(base);
    const material = try scene.addMaterial(.{ .texture = texture, .ambient = 0.2 });

    // The scene takes ownership of the mesh.
    const mesh = legend.obj.load(io, gpa, model_path) catch |err| {
        std.debug.print("failed to load {s}: {any}\n", .{ model_path, err });
        return err;
    };
    std.debug.print("loaded {s}: {d} vertices, {d} triangles\n", .{
        model_path,
        mesh.vertices.len,
        mesh.indices.len / 3,
    });
    const mesh_tris = mesh.indices.len / 3;
    const model = try scene.addMesh(mesh);
    const object = try scene.addObject(model, material, .{});

    const light = Light{ .dir = math.vec3(0.4, 0.9, 0.5).normalize() };

    var camera = Camera{ .position = math.vec3(0, 1.0, 4) };
    var win = try legend.Window.init("LegendEngine - OBJ", width, height);
    defer win.deinit();
    win.setMouseCaptured(true); // Tab gives the cursor back

    const move_speed: f32 = 4.0;
    const look_speed: f32 = 1.8; // radians per second, for the arrow keys
    const mouse_sensitivity: f32 = 0.0025; // radians per pixel
    const spin_speed: f32 = 0.5;
    var auto_spin = true;

    var fps = legend.FpsCounter{};
    var title_buf: [128]u8 = undefined;
    var last_ms = win.ticks();

    while (true) {
        const now_ms = win.ticks();
        const elapsed_ms = now_ms - last_ms;
        const dt = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
        last_ms = now_ms;

        // Publish timings to the title bar; there is no text renderer yet.
        if (fps.tick(elapsed_ms)) {
            const mouse = if (win.isMouseCaptured()) "mouse on" else "mouse off";
            const title = std.fmt.bufPrintZ(&title_buf, "LegendEngine - OBJ | {d:.1} fps | {d:.2} ms | {d} tris | {s} (Tab)", .{
                fps.fps,
                fps.frame_ms,
                mesh_tris,
                mouse,
            }) catch "LegendEngine - OBJ";
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

        // Arrow keys turn at a rate, so they scale with frame time.
        var dyaw: f32 = 0;
        var dpitch: f32 = 0;
        if (input.look_right) dyaw += 1;
        if (input.look_left) dyaw -= 1;
        if (input.look_up) dpitch += 1;
        if (input.look_down) dpitch -= 1;
        camera.look(dyaw * look_speed * dt, dpitch * look_speed * dt);

        // The mouse delta is a distance already moved, not a rate, so it is not
        // scaled by dt. Screen Y grows downward while pitch grows upward, which
        // is where the minus comes from.
        camera.look(
            input.mouse_dx * mouse_sensitivity,
            -input.mouse_dy * mouse_sensitivity,
        );

        if (auto_spin) {
            if (scene.object(object)) |obj| {
                obj.transform.rotation.v[1] += spin_speed * dt;
            }
        }

        fb.clear(legend.rgb(15, 15, 25));
        scene.render(&fb, camera, light);
        win.present(fb);
        win.delay(1);
    }
}
