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
    var doc = try gltf.openDocument(io, allocator, path);
    defer doc.deinit();
    const glb = doc.glb;
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

    // One skeleton per skin, not per mesh. A character is often several meshes
    // on one rig -- KayKit splits a body into head, torso and limbs, all skinned
    // to the same skeleton -- and building a separate rig per mesh would leave
    // one character with several animators to keep in step. Cache by skin index
    // and hand every mesh of a skin the same skeleton handle. Sixteen distinct
    // skins in one file is far past anything real.
    var skin_cache: [16]struct { skin: usize, handle: SkeletonHandle } = undefined;
    var skin_cache_n: usize = 0;

    for (0..mesh_count) |i| {
        // Does any node use this mesh with a skin? If so, that node's skin index.
        const skin_idx = skinForMesh(gltf_scene, i);

        var cpu_mesh = try gltf.loadMesh(allocator, glb, i);
        if (skin_idx) |si| {
            // Skinned: upload with joints/weights and resolve the skin's skeleton.
            meshes[i] = try assets.addSkinnedMesh(allocator, cpu_mesh);

            var handle: ?SkeletonHandle = null;
            for (skin_cache[0..skin_cache_n]) |entry| {
                if (entry.skin == si) {
                    handle = entry.handle;
                    break;
                }
            }
            if (handle == null) {
                // First mesh to use this skin: build the rig, load every clip the
                // file holds (switching between them is what makes a character
                // look alive), and cache it for the skin's other meshes.
                var skin = try gltf.parseSkin(allocator, glb, si);
                defer skin.deinit();
                var skel = try skeleton_mod.build(allocator, skin, gltf_scene);
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
                const h = try assets.addSkeleton(skel);
                if (skin_cache_n < skin_cache.len) {
                    skin_cache[skin_cache_n] = .{ .skin = si, .handle = h };
                    skin_cache_n += 1;
                }
                handle = h;
            }
            skeletons[i] = handle;
        } else {
            // Static.
            meshes[i] = try assets.addMesh(allocator, cpu_mesh);
            skeletons[i] = null;
        }
        cpu_mesh.deinit();

        // Material: resolve this mesh's glTF material, decode its base-color PNG
        // if it has one, and fall back to a flat tint otherwise.
        materials[i] = try buildMaterial(io, allocator, assets, scene, glb, i, fallback_tint, path);
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

/// Reads every animation clip from a separate glTF file and binds them to an
/// existing skeleton by joint name.
///
/// This is the other half of separating a character from its animation: a body
/// file carries the mesh and rig, animation files carry clips authored against
/// the same rig, and this joins them. The clips target joints by name -- the two
/// files agree on names, not on node indices -- so a clip built in one file
/// drives a skeleton built from another. The way Unreal binds an AnimSequence to
/// a Skeleton, and Unity a clip to an Avatar.
pub fn loadClipsInto(
    io: std.Io,
    allocator: std.mem.Allocator,
    assets: *Assets,
    skeleton_handle: SkeletonHandle,
    path: []const u8,
) !void {
    const skel = assets.skeleton(skeleton_handle) orelse return error.NoSkeleton;

    var doc = try gltf.openDocument(io, allocator, path);
    defer doc.deinit();
    const glb = doc.glb;

    const count = try gltf.animationCount(allocator, glb);
    for (0..count) |ci| {
        const clip = try gltf.parseAnimation(allocator, glb, ci);
        // addClip takes ownership and resolves the clip's channels against this
        // skeleton's joints by name. A clip whose names do not match this rig
        // still loads; its channels simply stay unresolved and are skipped.
        try skel.addClip(clip);
    }
}

/// Builds the Scene material for mesh `mesh_index`: base-color PNG decoded and
/// uploaded when present, otherwise a flat tint over the default white texture.
fn buildMaterial(
    io: std.Io,
    allocator: std.mem.Allocator,
    assets: *Assets,
    scene: *Scene,
    glb: gltf.Glb,
    mesh_index: usize,
    fallback_tint: Vec3,
    base_path: []const u8,
) !MaterialHandle {
    const mat_idx = try gltf.meshMaterial(allocator, glb, mesh_index);
    if (mat_idx) |mi| {
        // First an embedded PNG (a .glb keeps its texture inside).
        if (try gltf.baseColorPng(allocator, glb, mi)) |png_bytes| {
            var img = try png.decode(allocator, png_bytes);
            defer img.deinit();
            const tex = try assets.addTextureRgba(img);
            return scene.addMaterial(.{ .texture = tex, .tint = math_mod.vec3(1, 1, 1) });
        }
        // Then an external one (a .gltf names its texture in a separate file,
        // beside the .gltf, the way it names its .bin). Read it the same way,
        // decode it the same way. A uri we cannot read falls through to the tint.
        if (try gltf.baseColorUri(allocator, glb, mi)) |uri| {
            defer allocator.free(uri);
            if (loadExternalPng(io, allocator, base_path, uri)) |png_bytes| {
                defer allocator.free(png_bytes);
                var img = try png.decode(allocator, png_bytes);
                defer img.deinit();
                const tex = try assets.addTextureRgba(img);
                return scene.addMaterial(.{ .texture = tex, .tint = math_mod.vec3(1, 1, 1) });
            } else |err| {
                std.debug.print("external texture {s}: {}\n", .{ uri, err });
            }
        }
    }
    // No material, or a texture we could not load: flat colour.
    return scene.addMaterial(.{ .texture = assets.white, .tint = fallback_tint });
}

/// Reads an external texture file named by `uri`, relative to `base_path` (the
/// .gltf's own path). The bytes are the caller's to free. The same directory
/// resolution openDocument uses for a .gltf's .bin.
fn loadExternalPng(
    io: std.Io,
    allocator: std.mem.Allocator,
    base_path: []const u8,
    uri: []const u8,
) ![]const u8 {
    const dir_end = if (std.mem.lastIndexOfScalar(u8, base_path, '/')) |i| i + 1 else 0;
    const full = try std.mem.concat(allocator, u8, &.{ base_path[0..dir_end], uri });
    defer allocator.free(full);

    const file = try std.Io.Dir.cwd().openFile(io, full, .{});
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
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
