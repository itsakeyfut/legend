//! The scene, on the GPU. Same meshes, same camera, same lighting as the
//! software renderer -- and the frame time is what changed.
//!
//!   zig build run-mesh
//!   zig build run-mesh -- path/to/model.obj

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const Mesh = legend.Mesh;
const Camera = legend.Camera;
const gpu = legend.gpu;

/// Fills in the 128 bytes the shader expects: the MVP and the normal matrix as
/// columns, plus the light. Doing this per object per frame is exactly what push
/// constants are for -- no buffers, no descriptor sets, no synchronisation.
fn pushFor(model: math.Mat4, vp: math.Mat4, light: math.Vec3) gpu.PushConstants {
    const mvp = vp.mul(model);
    const nm = model.normalMatrix();
    return .{
        .mvp0 = mvp.column(0).v,
        .mvp1 = mvp.column(1).v,
        .mvp2 = mvp.column(2).v,
        .mvp3 = mvp.column(3).v,
        .normal0 = nm.column(0).v,
        .normal1 = nm.column(1).v,
        .normal2 = nm.column(2).v,
        .light_dir = .{ light.x(), light.y(), light.z(), 0 },
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const model_path: []const u8 = if (args.len >= 2) args[1] else "assets/torus.obj";

    const width: u32 = 960;
    const height: u32 = 640;

    var win = try legend.Window.initVulkan("LegendEngine - Vulkan", width, height);
    defer win.deinit();

    var ctx = try gpu.Context.init(gpa, &win, width, height);
    defer ctx.deinit(&win);

    std.debug.print("gpu: {s}\n", .{ctx.device.deviceName()});

    // -- upload the meshes -------------------------------------------------
    // The CPU-side Mesh is freed straight after: once the vertices are in device
    // memory, the copy in system RAM is dead weight.
    var cpu_model = try legend.obj.load(io, gpa, model_path);
    const model_tris = cpu_model.indices.len / 3;
    var gpu_model = try ctx.uploadMesh(gpa, cpu_model);
    cpu_model.deinit();
    defer gpu_model.deinit();

    var cpu_cube = try Mesh.cube(gpa);
    var gpu_cube = try ctx.uploadMesh(gpa, cpu_cube);
    cpu_cube.deinit();
    defer gpu_cube.deinit();

    var cpu_ground = try Mesh.plane(gpa, 60, 30);
    var gpu_ground = try ctx.uploadMesh(gpa, cpu_ground);
    cpu_ground.deinit();
    defer gpu_ground.deinit();

    std.debug.print("uploaded: {d} triangles in the model\n", .{model_tris});

    // -- the scene ----------------------------------------------------------
    const Spinner = struct { x: f32, spin: f32, angle: f32 };
    var spinners = [_]Spinner{
        .{ .x = -5, .spin = 0.6, .angle = 0 },
        .{ .x = 0, .spin = -0.4, .angle = 1.0 },
        .{ .x = 5, .spin = 0.9, .angle = 2.0 },
    };

    const light = math.vec3(0.35, 0.85, 0.4).normalize();
    var camera = Camera{ .position = math.vec3(0, 1.5, 12) };

    win.setMouseCaptured(true);

    const move_speed: f32 = 7.0;
    const mouse_sensitivity: f32 = 0.0025;
    var auto_spin = true;

    var items: [16]gpu.DrawItem = undefined;

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
            for (&spinners) |*s| s.angle += s.spin * dt;
        }

        // Vulkan's clip space, not OpenGL's: Y points down and depth runs 0..1.
        const aspect = @as(f32, @floatFromInt(ctx.swapchain.extent.width)) /
            @as(f32, @floatFromInt(ctx.swapchain.extent.height));
        const vp = camera.viewProjectionVulkan(aspect);

        var n: usize = 0;

        const ground = math.Mat4.translation(math.vec3(0, -1.5, 0));
        items[n] = .{ .mesh = &gpu_ground, .push = pushFor(ground, vp, light) };
        n += 1;

        for (spinners) |s| {
            const model = math.Mat4.translation(math.vec3(s.x, 0.2, 0))
                .mul(math.Mat4.rotationY(s.angle));
            items[n] = .{ .mesh = &gpu_model, .push = pushFor(model, vp, light) };
            n += 1;
        }

        var i: i32 = -3;
        while (i <= 3) : (i += 1) {
            const x: f32 = @floatFromInt(i);
            const model = math.Mat4.translation(math.vec3(x * 3.0, -0.9, -9))
                .mul(math.Mat4.scaling(math.vec3(0.6, 0.6, 0.6)));
            items[n] = .{ .mesh = &gpu_cube, .push = pushFor(model, vp, light) };
            n += 1;
        }

        try ctx.drawFrame(items[0..n]);
    }

    // The GPU may still be executing the last frame's commands, which reference
    // the mesh buffers the deferred deinits are about to free.
    ctx.waitIdle();
}
