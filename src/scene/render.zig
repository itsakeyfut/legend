//! Turning a scene into a draw list.
//!
//! Scene is pure data and Assets is GPU resources; neither knows about the
//! other. This is where they meet: for each object, resolve its mesh and
//! texture handles against Assets, fold its transform and material into the
//! push constants the shader wants, and emit a DrawItem. The renderer downstream
//! stays ignorant of scenes, assets, and handles alike -- it sees only a flat
//! list of things to draw.

const std = @import("std");

const math = @import("../math/math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Camera = @import("../render/camera.zig").Camera;

const gpu = @import("../gpu/root.zig");
const DrawItem = gpu.DrawItem;
const PushConstants = gpu.PushConstants;

const assets_mod = @import("assets.zig");
const Assets = assets_mod.Assets;
const scene_mod = @import("scene.zig");
const Scene = scene_mod.Scene;

/// Builds the frame's draw list into `out`, returning the slice actually used.
/// Objects whose mesh or texture handle has gone stale are skipped rather than
/// crashing -- the whole reason the handles are generational.
///
/// `out` is caller-owned and typically a fixed buffer reused every frame, so no
/// allocation happens here. Objects beyond its length are dropped; a real scene
/// would grow it, which is a job for the frame arena when one exists.
pub fn buildDrawList(
    scene: *Scene,
    assets: *Assets,
    camera: Camera,
    aspect: f32,
    out: []DrawItem,
) []DrawItem {
    // Vulkan's clip space: Y down, depth 0..1.
    const vp = camera.viewProjectionVulkan(aspect);
    const light = scene.light.dir.normalize();

    var n: usize = 0;
    var it = scene.objectIterator();
    while (it.next()) |entry| {
        if (n >= out.len) break;
        const obj = entry.value_ptr;

        const mesh = assets.mesh(obj.mesh) orelse continue;
        const mat = scene.material(obj.material) orelse continue;
        const tex = assets.texture(mat.texture) orelse continue;

        out[n] = .{
            .mesh = mesh,
            .texture = tex.set,
            .push = pushFor(obj.transform.matrix(), vp, light, mat.tint),
        };
        n += 1;
    }
    return out[0..n];
}

/// Packs the 128 bytes the shader reads: MVP and normal matrix as columns, the
/// light, and the tint tucked into the normal matrix's unused w channels.
fn pushFor(model: Mat4, vp: Mat4, light: Vec3, tint: Vec3) PushConstants {
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
