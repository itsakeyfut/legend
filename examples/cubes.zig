const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const image = legend.image;
const Framebuffer = legend.Framebuffer;
const Mesh = legend.Mesh;
const Camera = legend.Camera;
const Scene = legend.Scene;
const Light = legend.Light;
const ObjectHandle = legend.ObjectHandle;

/// Game-side data. The engine's Object holds only mesh + transform; behaviour
/// like "how fast does this spin" belongs to the game, not the engine.
const Spinner = struct {
    handle: ObjectHandle,
    spin: f32, // radians per second
};

fn makeChecker(allocator: std.mem.Allocator, size: u32, cells: u32) !image.Image(.rgb) {
    var tex = try image.Image(.rgb).init(allocator, size, size);
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
            return makeChecker(allocator, 256, 8);
        };
    }
    return makeChecker(allocator, 256, 8);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const width: u32 = 640;
    const height: u32 = 480;

    var fb = try Framebuffer.init(gpa, width, height);
    defer fb.deinit();

    const tex_path: ?[]const u8 = if (args.len >= 2) args[1] else null;
    var tex = try loadTexture(io, gpa, tex_path);
    defer tex.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit(); // frees the meshes it owns

    const cube = try scene.addMesh(try Mesh.cube(gpa));

    var spinners: [128]Spinner = undefined;
    var spinner_n: usize = 0;

    // Three cubes to start with.
    const initial = [_]struct { pos: math.Vec3, s: f32, spin: f32 }{
        .{ .pos = math.vec3(-3, 0, 0), .s = 0.8, .spin = 0.7 },
        .{ .pos = math.vec3(0, 0, 0), .s = 1.0, .spin = 1.0 },
        .{ .pos = math.vec3(3, 0, 0), .s = 1.2, .spin = 1.4 },
    };
    for (initial) |o| {
        const h = try scene.addObject(cube, .{
            .position = o.pos,
            .scale = math.vec3(o.s, o.s, o.s),
        });
        spinners[spinner_n] = .{ .handle = h, .spin = o.spin };
        spinner_n += 1;
    }
    const base_count = spinner_n; // the initial cubes are never despawned

    const light = Light{ .dir = math.vec3(0.4, 0.9, 0.5).normalize(), .ambient = 0.25 };

    var camera = Camera{};
    var win = try legend.Window.init("LegendEngine", width, height);
    defer win.deinit();

    const move_speed: f32 = 6.0; // units / second
    const look_speed: f32 = 1.8; // radians / second
    var auto_spin = true;
    var spawn_seq: u32 = 0;

    var last_ms = win.ticks();

    while (true) {
        // Delta time: everything below is expressed per-second, so the
        // simulation no longer depends on the frame rate.
        const now_ms = win.ticks();
        const dt = @as(f32, @floatFromInt(now_ms - last_ms)) / 1000.0;
        last_ms = now_ms;

        const input = win.pollInput();
        if (input.quit) break;
        if (input.toggle_pause) auto_spin = !auto_spin;

        // -- camera -------------------------------------------------------------------------------
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

        // -- spawn / despawn -------------------------------------------------------------------------------
        if (input.spawn and spinner_n < spinners.len) {
            const angle = @as(f32, @floatFromInt(spawn_seq)) * 0.9;
            const h = try scene.addObject(cube, .{
                .position = math.vec3(4.0 * @cos(angle), 2.0, 4.0 * @sin(angle) - 1.0),
                .scale = math.vec3(0.5, 0.5, 0.5),
            });
            spinners[spinner_n] = .{
                .handle = h,
                .spin = 1.0 + @as(f32, @floatFromInt(spawn_seq % 5)) * 0.3,
            };
            spinner_n += 1;
            spawn_seq += 1;
            std.debug.print("spawn   -> live={d}\n", .{scene.objectCount()});
        }
        if (input.despawn and spinner_n > base_count) {
            spinner_n -= 1;
            scene.removeObject(spinners[spinner_n].handle);
            std.debug.print("despawn -> live={d}\n", .{scene.objectCount()});
        }

        // -- update -------------------------------------------------------------------------------
        if (auto_spin) {
            for (spinners[0..spinner_n]) |sp| {
                // The handle may be stale if the object was destroyed; the
                // slot map tells us so instead of handing back a dangling ptr.
                const obj = scene.object(sp.handle) orelse continue;
                obj.transform.rotation.v[1] += sp.spin * dt;
            }
        }

        // -- render -------------------------------------------------------------------------------
        fb.clear(legend.rgb(15, 15, 25));
        scene.render(&fb, camera, tex, light);
        win.present(fb);
        win.delay(1);
    }
}
