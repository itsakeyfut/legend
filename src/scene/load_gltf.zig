//! Bridging glTF into the engine's own scene.
//!
//! gltf.zig turns a .glb into neutral data -- transforms, mesh indices, a node
//! tree, and the byte ranges of embedded PNG textures -- and stops there,
//! knowing nothing of Assets, Scene, or the image codec. This file is the other
//! half: it uploads meshes, decodes textures, builds materials, and walks the
//! node tree into the engine's Scene. The dependency arrow points one way --
//! scene depends on render, never the reverse -- so this bridge lives here.

const std = @import("std");

const gltf = @import("../render/gltf.zig");
const png = @import("../image/png.zig");
const assets_mod = @import("assets.zig");
const scene_mod = @import("scene.zig");
const math_mod = @import("../math/math.zig");
const skeleton_mod = @import("skeleton.zig");

const Assets = assets_mod.Assets;
const MeshHandle = assets_mod.MeshHandle;
const SkeletonHandle = assets_mod.SkeletonHandle;
const TextureHandle = assets_mod.TextureHandle;
const Scene = scene_mod.Scene;
const MaterialHandle = scene_mod.MaterialHandle;
const ObjectHandle = scene_mod.ObjectHandle;
const Vec3 = math_mod.Vec3;

/// What a load produced: the object the model hangs from, and the skeleton it
/// brought if it was rigged. A game needs both -- one to move the thing, one to
/// drive its animation.
pub const Model = struct {
    root: ObjectHandle,
    skeleton: ?SkeletonHandle = null,
};

/// Loads a .glb from disk into `scene`, uploading its meshes and textures into
/// `assets`, and returns the object the whole model hangs from.
///
/// A file may name several root nodes, so one transform-only Object is created
/// above them all: "the model" is then a single thing to move, rotate, or scale,
/// and the hierarchy carries the rest. Without it there would be no handle to
/// the thing that was just loaded -- fine for looking at a scene, useless for a
/// game that has to move what it loaded.
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    assets: *Assets,
    scene: *Scene,
    fallback_tint: Vec3,
    path: []const u8,
) !Model {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    const glb = try gltf.parseGlb(bytes);
    var gltf_scene = try gltf.parseScene(allocator, glb);
    defer gltf_scene.deinit();

    // Each mesh becomes a (MeshHandle, MaterialHandle) pair. A mesh used by a
    // skinned node also gets a SkeletonHandle and is uploaded as a skinned mesh;
    // meshes[i]/skeletons[i] index by glTF mesh index.
    const mesh_count = gltf_scene.meshCount();
    const meshes = try allocator.alloc(?MeshHandle, mesh_count);
    defer allocator.free(meshes);
    const materials = try allocator.alloc(MaterialHandle, mesh_count);
    defer allocator.free(materials);
    const skeletons = try allocator.alloc(?SkeletonHandle, mesh_count);
    defer allocator.free(skeletons);

    for (0..mesh_count) |i| {
        // Does any node use this mesh with a skin? If so, that node's skin index.
        const skin_idx = skinForMesh(gltf_scene, i);

        var cpu_mesh = try gltf.loadMesh(allocator, glb, i);
        if (skin_idx) |si| {
            // Skinned: upload with joints/weights, build the skeleton, and give
            // it the file's first animation if there is one.
            meshes[i] = try assets.addSkinnedMesh(allocator, cpu_mesh);
            var skin = try gltf.parseSkin(allocator, glb, si);
            defer skin.deinit();
            var skel = try skeleton_mod.build(allocator, skin, gltf_scene);
            // Every clip the file holds, not just the first: switching between
            // them is what makes a character look alive, and that needs them all
            // loaded.
            const clip_count = gltf.animationCount(allocator, glb) catch 0;
            if (clip_count > 0) {
                const clips = try allocator.alloc(gltf.Animation, clip_count);
                var built: usize = 0;
                errdefer {
                    for (0..built) |ci| clips[ci].deinit();
                    allocator.free(clips);
                }
                for (0..clip_count) |ci| {
                    clips[ci] = try gltf.parseAnimation(allocator, glb, ci);
                    built += 1;
                }
                skel.clips = clips;
                skel.bindClips();
            }
            skeletons[i] = try assets.addSkeleton(skel);
        } else {
            // Static.
            meshes[i] = try assets.addMesh(allocator, cpu_mesh);
            skeletons[i] = null;
        }
        cpu_mesh.deinit();

        // Material: resolve this mesh's glTF material, decode its base-color PNG
        // if it has one, and fall back to a flat tint otherwise.
        materials[i] = try buildMaterial(allocator, assets, scene, glb, i, fallback_tint);
    }

    // A default material for mesh-less nodes, which still need one to exist as
    // Objects even though they draw nothing.
    const default_material = try scene.addMaterial(.{
        .texture = assets.white,
        .tint = fallback_tint,
    });

    const model_root = try scene.addObject(null, default_material, .{});

    for (gltf_scene.roots) |root_idx| {
        try addNode(scene, gltf_scene, meshes, materials, skeletons, default_material, root_idx, model_root);
    }

    // The first skeleton the file brought, if any. A file with several rigged
    // meshes would need more, but nothing in reach has one.
    var first_skeleton: ?SkeletonHandle = null;
    for (skeletons) |maybe| {
        if (maybe) |handle| {
            first_skeleton = handle;
            break;
        }
    }

    return .{ .root = model_root, .skeleton = first_skeleton };
}

/// Builds the Scene material for mesh `mesh_index`: base-color PNG decoded and
/// uploaded when present, otherwise a flat tint over the default white texture.
fn buildMaterial(
    allocator: std.mem.Allocator,
    assets: *Assets,
    scene: *Scene,
    glb: gltf.Glb,
    mesh_index: usize,
    fallback_tint: Vec3,
) !MaterialHandle {
    const mat_idx = try gltf.meshMaterial(allocator, glb, mesh_index);

    if (mat_idx) |mi| {
        if (try gltf.baseColorPng(allocator, glb, mi)) |png_bytes| {
            // Decode the embedded PNG and upload it as this material's texture.
            var img = try png.decode(allocator, png_bytes);
            defer img.deinit();
            const tex = try assets.addTextureRgba(img);
            return scene.addMaterial(.{ .texture = tex, .tint = math_mod.vec3(1, 1, 1) });
        }
    }

    // No material, or a material with no base-color texture: flat colour.
    return scene.addMaterial(.{ .texture = assets.white, .tint = fallback_tint });
}

/// Recursively turns glTF node `index` into an Object under `parent`. A node's
/// mesh (if any) is resolved to its handle and paired material; a mesh-less node
/// becomes a transform-only Object with the default material.
fn addNode(
    scene: *Scene,
    gltf_scene: gltf.Scene,
    meshes: []const ?MeshHandle,
    materials: []const MaterialHandle,
    skeletons: []const ?SkeletonHandle,
    default_material: MaterialHandle,
    index: usize,
    parent: ?ObjectHandle,
) !void {
    if (index >= gltf_scene.nodes.len) return;
    const node = gltf_scene.nodes[index];

    var mesh: ?MeshHandle = null;
    var material = default_material;
    var skeleton: ?SkeletonHandle = null;
    if (node.mesh) |m| {
        if (m < meshes.len) {
            mesh = meshes[m];
            material = materials[m];
            // A node with a skin gets its mesh's skeleton bound.
            if (node.skin != null) skeleton = skeletons[m];
        }
    }

    const handle = if (parent) |p|
        try scene.addChild(p, mesh, material, node.transform)
    else
        try scene.addObject(mesh, material, node.transform);

    // Bind the skeleton after creation (addObject/addChild don't take one).
    if (skeleton) |sk| scene.setSkeleton(handle, sk);

    for (node.children) |child_idx| {
        try addNode(scene, gltf_scene, meshes, materials, skeletons, default_material, child_idx, handle);
    }
}

/// If any node draws mesh `mesh_index` with a skin, returns that skin index.
/// The common case (one skinned node per skinned mesh) resolves to the first.
fn skinForMesh(gltf_scene: gltf.Scene, mesh_index: usize) ?usize {
    for (gltf_scene.nodes) |node| {
        if (node.mesh == mesh_index and node.skin != null) return node.skin;
    }
    return null;
}
