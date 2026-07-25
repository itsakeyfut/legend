//! Turning a scene into a draw list.
//!
//! Scene is pure data and Assets is GPU resources; neither knows about the
//! other. This is where they meet: for each object, resolve its mesh and
//! texture handles against Assets, fold its transform and material into the
//! push constants the shader wants, and emit a DrawItem. The renderer downstream
//! stays ignorant of scenes, assets, and handles alike -- it sees only a flat
//! list of things to draw.

const std = @import("std");

const c = @import("../gpu/vk.zig").c;

const math = @import("../math/math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Camera = @import("../render/camera.zig").Camera;

const gpu = @import("../gpu/root.zig");
const DrawItem = gpu.DrawItem;
const PushConstants = gpu.PushConstants;
const Context = gpu.Context;

const assets_mod = @import("assets.zig");
const Assets = assets_mod.Assets;
const scene_mod = @import("scene.zig");
const Scene = scene_mod.Scene;

/// One frame's worth of drawing: the list of objects, and the per-frame data
/// they all share. Bundled because the shared half keeps growing -- the shadow
/// map and the light's matrix now, the camera position and fog later -- and
/// threading each one separately would mean touching every caller each time.
pub const Frame = struct {
    items: []DrawItem,
    /// Set 2: the shadow map plus the light's matrix, bound once for the frame.
    shadow_set: c.VkDescriptorSet,
};

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
    ctx: *Context,
    camera: Camera,
    aspect: f32,
    out: []DrawItem,
) !Frame {
    // Vulkan's clip space: Y down, depth 0..1.
    const vp = camera.viewProjection(aspect);
    const light = scene.light.dir.normalize();
    const light_vp = lightViewProjection(light);
    // Bone slots are handed out fresh each frame; start them over before any
    // character claims one.
    ctx.beginBones();
    // The light's matrix and direction, shared by every object this frame.
    const shadow_set = try ctx.updateShadow(.{
        .light_vp = light_vp,
        .light_dir = .{ light.x(), light.y(), light.z(), 0 },
    });

    var n: usize = 0;
    var it = scene.objectIterator();
    while (it.next()) |entry| {
        if (n >= out.len) break;
        const obj = entry.value_ptr;

        // A mesh-less object is a transform carrier only -- nothing to draw, but
        // its world matrix still matters to its children.
        const mesh_handle = obj.mesh orelse continue;
        const mesh = assets.mesh(mesh_handle) orelse continue;
        const mat = scene.material(obj.material) orelse continue;
        const tex = assets.texture(mat.texture) orelse continue;

        // The world matrix folds in every ancestor's transform; a root object's
        // is just its own.
        const model = scene.worldMatrix(entry.key);
        const push = pushFor(model, vp, mat.tint);
        const shadow_push = pushFor(model, light_vp, mat.tint);

        // A skinned object uploads the palette its animator was evaluated to
        // this frame, yielding the descriptor set that routes it through the
        // skinning pipeline. The pose itself was computed in the update phase --
        // nothing is posed here. Static objects have no bone set.
        if (obj.animator) |anim_handle| skinned: {
            const anim = scene.animators.getPtr(anim_handle) orelse break :skinned;
            // Full frames drop the character rather than overwrite another's
            // palette; static-draw it so it is still visible, just unposed.
            const bone = (ctx.updateBones(anim.skinning) catch break :skinned) orelse break :skinned;
            out[n] = .{ .mesh = mesh, .texture = tex.set, .push = push, .shadow_push = shadow_push, .bone = bone };
            n += 1;
            continue;
        }

        // Static object.
        out[n] = .{ .mesh = mesh, .texture = tex.set, .push = push, .shadow_push = shadow_push };
        n += 1;
    }
    return .{ .items = out[0..n], .shadow_set = shadow_set };
}

/// Packs the 128 bytes the shader reads: MVP and normal matrix as columns, the
/// light, and the tint tucked into the normal matrix's unused w channels.
fn pushFor(model: Mat4, vp: Mat4, tint: Vec3) PushConstants {
    const mvp = vp.mul(model);

    var m0 = model.column(0).v;
    var m1 = model.column(1).v;
    var m2 = model.column(2).v;
    m0[3] = tint.x();
    m1[3] = tint.y();
    m2[3] = tint.z();

    return .{
        .mvp0 = mvp.column(0).v,
        .mvp1 = mvp.column(1).v,
        .mvp2 = mvp.column(2).v,
        .mvp3 = mvp.column(3).v,
        .model0 = m0,
        .model1 = m1,
        .model2 = m2,
        .model3 = model.column(3).v,
    };
}

/// The matrix the shadow map is rendered with: the scene as the light sees it.
///
/// A directional light has no position, only a direction, so one is invented --
/// far enough back along the light to keep the scene in front of it -- and the
/// projection is orthographic, because parallel rays do not converge. The box is
/// fixed for now: everything outside it is simply unshadowed, which is why the
/// sampler's border is white.
pub fn lightViewProjection(dir: Vec3) Mat4 {
    const d = dir.normalize();
    // The light sits along its own direction, looking back at the origin.
    const eye = d.scale(12);
    // Any up vector works except one parallel to the light.
    const up = if (@abs(d.y()) > 0.99) math.vec3(0, 0, 1) else math.vec3(0, 1, 0);
    const view = Mat4.lookAt(eye, math.vec3(0, 0, 0), up);
    const proj = Mat4.orthographic(-8, 8, -8, 8, 0.1, 30);
    return proj.mul(view);
}
