//! Skinned mesh: a rigged model deformed by its skeleton on the GPU.
//!
//! This is the payoff of the whole skinning path -- vertex joints and weights,
//! the bone-matrix uniform buffer, the skinning pipeline -- wired by hand for
//! one model. At bind pose the skinning matrices are identity, so a correct
//! pipeline shows CesiumMan standing undistorted. Once that holds, animation
//! (S-3) is only a matter of posing the skeleton over time.
//!
//!   zig build run-skinned

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const Camera = legend.Camera;
const gpu = legend.gpu;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;

const gltf = legend.gltf;
const skeleton_mod = legend.skeleton;
const png = legend.image.png;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const path = "assets/gltf/CesiumMan.glb";

    const width: u32 = 960;
    const height: u32 = 640;

    var win = try legend.Window.init("LegendEngine - Skinned", width, height);
    defer win.deinit();

    var ctx = try gpu.Context.init(gpa, &win, width, height);
    defer ctx.deinit(&win);

    // -- load the model by hand ------------------------------------------
    // Read the whole file once; parse geometry, the node tree, and the skin.
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    const size: usize = @intCast(try file.length(io));
    const bytes = try gpa.alloc(u8, size);
    file.close(io);
    defer gpa.free(bytes);
    {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        _ = try f.readPositionalAll(io, bytes, 0);
    }

    const glb = try gltf.parseGlb(bytes);

    var mesh = try gltf.loadMesh(gpa, glb, 0);
    defer mesh.deinit();

    var gscene = try gltf.parseScene(gpa, glb);
    defer gscene.deinit();

    var skin = try gltf.parseSkin(gpa, glb, 0);
    defer skin.deinit();

    var skeleton = try skeleton_mod.build(gpa, skin, gscene);
    defer skeleton.deinit();

    // Upload geometry as a skinned mesh, and the base-color texture.
    var gpu_mesh = try ctx.uploadSkinnedMesh(gpa, mesh);
    defer gpu_mesh.deinit();

    // CesiumMan's texture is JPEG, which we don't decode; a flat white texel
    // stands in. Skinning is what this example verifies, not texturing.
    var texture = blk: {
        const white = [_]u8{ 255, 255, 255, 255 };
        break :blk try ctx.uploadTexture(&white, 1, 1);
    };
    defer texture.deinit();

    std.debug.print("loaded {s}: {} joints\n", .{ path, skeleton.joints.len });

    // -- loop -------------------------------------------------------------
    // CesiumMan is ~1.6 units tall after its 0.01 scale node; sit the camera
    // close.
    var camera = Camera{ .position = math.vec3(0, 1, 3) };
    win.setMouseCaptured(true);

    const move_speed: f32 = 2.0;
    const mouse_sensitivity: f32 = 0.0025;

    const light = math.vec3(0.3, 0.7, 0.5).normalize();

    var fps = legend.FpsCounter{};
    var title_buf: [160]u8 = undefined;
    var last_ms = win.ticks();

    while (true) {
        const now_ms = win.ticks();
        const elapsed_ms = now_ms - last_ms;
        const dt = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
        last_ms = now_ms;

        if (fps.tick(elapsed_ms)) {
            const title = std.fmt.bufPrintZ(&title_buf, "LegendEngine - Skinned | {d:.1} fps", .{fps.fps}) catch "Skinned";
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
        camera.look(input.mouse_dx * mouse_sensitivity, -input.mouse_dy * mouse_sensitivity);

        const aspect = @as(f32, @floatFromInt(ctx.swapchain.extent.width)) /
            @as(f32, @floatFromInt(ctx.swapchain.extent.height));

        // Bind pose for now: pose() with the skeleton's rest transforms leaves
        // the skinning matrices at (near) identity.
        skeleton.pose();
        const bone_set = try ctx.updateBones(skeleton.skinning);

        // The model's own root transform (identity here) times view-projection.
        const vp = camera.viewProjection(aspect);
        // CesiumMan is authored Z-up; its root "Z_UP" node rotates it into the
        // Y-up world. The manual path here skips the file's node hierarchy, so
        // that correction is applied by hand -- a -90 deg turn about X.
        const model = Mat4.rotationX(-std.math.pi / 2.0);

        const item = gpu.DrawItem{
            .mesh = &gpu_mesh,
            .texture = texture.set,
            .push = pushFor(model, vp, light, math.vec3(1, 1, 1)),
            .bone_set = bone_set,
        };

        try ctx.drawFrame(&.{item});
    }

    ctx.waitIdle();
}

/// Builds the push constants, mirroring scene/render.zig's private helper.
fn pushFor(model: Mat4, vp: Mat4, light: Vec3, tint: Vec3) gpu.PushConstants {
    const mvp = vp.mul(model);
    const nm = model.normalMatrix();

    var n0 = nm.column(0).v;
    var n1 = nm.column(1).v;
    var n2 = nm.column(2).v;
    n0[3] = tint.x();
    n1[3] = tint.y();
    n2[3] = tint.z();

    return .{
        .mvp0 = mvp.column(0).v,
        .mvp1 = mvp.column(1).v,
        .mvp2 = mvp.column(2).v,
        .mvp3 = mvp.column(3).v,
        .normal0 = n0,
        .normal1 = n1,
        .normal2 = n2,
        .light_dir = .{ light.x(), light.y(), light.z(), 0 },
    };
}
