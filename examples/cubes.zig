//! Three cubes, one texture, three materials. The point of the example is that
//! the tint lives in the material, not the texture, so one image serves them all.

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const Framebuffer = legend.Framebuffer;
const Mesh = legend.Mesh;
const Camera = legend.Camera;
const Scene = legend.Scene;
const Light = legend.Light;
const Texture = legend.Texture;
const ObjectHandle = legend.ObjectHandle;
const MaterialHandle = legend.MaterialHandle;

/// Game-side data. The engine's Object holds only mesh + material + transform;
/// behaviour like "how fast does this spin" belongs to the game, not the engine.
const Spinner = struct {
    handle: ObjectHandle,
    spin: f32, // radians per second
};

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

    const width: u32 = 640;
    const height: u32 = 480;

    var fb = try Framebuffer.init(gpa, width, height);
    defer fb.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit(); // frees the meshes and textures it owns

    const cube = try scene.addMesh(try Mesh.cube(gpa));

    // One texture, either loaded for generated.
    const base = blk: {
        if (args.len >= 2) {
            break :blk legend.image.loadQoiRgb(io, gpa, args[1]) catch |err| {
                std.debug.print("failed to load {s}: {any}; using checker\n", .{ args[1], err });
                break :blk try makeChecker(gpa, 256, 8);
            };
        }
        break :blk try makeChecker(gpa, 256, 8);
    };
    const texture = try scene.addTexture(base);

    // Three materials over that one texture. Only the tint differs.
    const warm = try scene.addMaterial(.{ .texture = texture, .tint = math.vec3(1.0, 0.55, 0.4) });
    const cool = try scene.addMaterial(.{ .texture = texture, .tint = math.vec3(0.4, 0.65, 1.0) });
    const lime = try scene.addMaterial(.{ .texture = texture, .tint = math.vec3(0.6, 1.0, 0.45) });

    // A fourth with no texture at all: white texel plus a tint is a flat colour.
    const flat = try scene.addMaterial(.{
        .texture = scene.white,
        .tint = math.vec3(0.95, 0.85, 0.35),
        .ambient = 0.15,
    });

    var spinners: [128]Spinner = undefined;
    var spinner_n: usize = 0;

    // Three cubes to start with.
    const initial = [_]struct { pos: math.Vec3, s: f32, spin: f32, mat: MaterialHandle }{
        .{ .pos = math.vec3(-3, 0, 0), .s = 0.8, .spin = 0.7, .mat = warm },
        .{ .pos = math.vec3(0, 0, 0), .s = 1.0, .spin = 1.0, .mat = cool },
        .{ .pos = math.vec3(3, 0, 0), .s = 1.2, .spin = 1.4, .mat = lime },
    };
    for (initial) |o| {
        const h = try scene.addObject(cube, o.mat, .{
            .position = o.pos,
            .scale = math.vec3(o.s, o.s, o.s),
        });
        spinners[spinner_n] = .{ .handle = h, .spin = o.spin };
        spinner_n += 1;
    }
    const base_count = spinner_n; // the initial cubes are never despawned

    const light = Light{ .dir = math.vec3(0.4, 0.9, 0.5).normalize() };

    var camera = Camera{};
    var win = try legend.Window.init("LegendEngine", width, height);
    defer win.deinit();

    const move_speed: f32 = 6.0; // units / second
    const look_speed: f32 = 1.8; // radians / second
    var auto_spin = true;
    var spawn_seq: u32 = 0;

    var fps = legend.FpsCounter{};
    var title_buf: [128]u8 = undefined;
    var last_ms = win.ticks();

    while (true) {
        // Delta time: everything below is expressed per-second, so the
        // simulation no longer depends on the frame rate.
        const now_ms = win.ticks();
        const elapsed_ms = now_ms - last_ms;
        const dt = @as(f32, @floatFromInt(now_ms - last_ms)) / 1000.0;
        last_ms = now_ms;

        if (fps.tick(elapsed_ms)) {
            const title = std.fmt.bufPrintZ(&title_buf, "LegendEngine | {d:.1} fps | {d:.2} ms | {d} objects", .{
                fps.fps,
                fps.frame_ms,
                scene.objectCount(),
            }) catch "LegendEngine";
            win.setTitle(title);
        }

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
            const palette = [_]MaterialHandle{ warm, cool, lime, flat };
            const angle = @as(f32, @floatFromInt(spawn_seq)) * 0.9;
            const h = try scene.addObject(cube, palette[spawn_seq % palette.len], .{
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
        scene.render(&fb, camera, light);
        win.present(fb);
        win.delay(1);
    }
}
