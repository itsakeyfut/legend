//! Model benchmark: loads a Wavefront OBJ and renders it uncapped so the
//! frame limiter does not cap the numbers we are trying to measure.
//!
//!   zig build bench-model                 -- assets/torus.obj, ReleaseFast, uncapped
//!   zig build bench-model -- path/to/model.obj

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const image = legend.image;
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

fn loadQoiRgb(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !image.Image(.rgb) {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const size: usize = @intCast(try file.length(io));
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
    _ = try file.readPositionalAll(io, data, 0);

    var rgba = try image.decodeQoi(allocator, data);
    defer rgba.deinit();

    const rgb = try image.Image(.rgb).init(allocator, rgba.width, rgba.height);
    for (rgba.pixels, 0..) |px, i| {
        rgb.pixels[i] = .{ .r = px.r, .g = px.g, .b = px.b };
    }
    return rgb;
}

fn loadTexture(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8) !image.Image(.rgb) {
    if (path) |p| {
        return loadQoiRgb(io, allocator, p) catch |err| {
            std.debug.print("failed to load {s}: {any}; using checker\n", .{ p, err });
            return makeChecker(allocator, 512, 16);
        };
    }
    return makeChecker(allocator, 512, 16);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Pass --uncapped to remove the frame limiter when measuring.
    var uncapped = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--uncapped")) uncapped = true;
    }

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

    const move_speed: f32 = 4.0;
    const look_speed: f32 = 1.8;
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
            const title = std.fmt.bufPrintZ(&title_buf, "LegendEngine - OBJ | {d:.1} fps | {d:.2} ms | {d} tris", .{
                fps.fps,
                fps.frame_ms,
                mesh_tris,
            }) catch "LegendEngine - OBJ";
            win.setTitle(title);
        }

        const input = win.pollInput();
        if (input.quit) break;
        if (input.toggle_pause) auto_spin = !auto_spin;

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

        if (auto_spin) {
            if (scene.object(object)) |obj| {
                obj.transform.rotation.v[1] += spin_speed * dt;
            }
        }

        fb.clear(legend.rgb(15, 15, 25));
        scene.render(&fb, camera, light);
        win.present(fb);

        // Cap the frame rate unless we're benchmarking. Without this the
        // renderer spins a core flat out to produce frames nobody sees.
        if (!uncapped) win.delay(1);
    }
}
