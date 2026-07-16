//! Bridging glTF into the engine's own scene.
//!
//! gltf.zig turns a .glb into neutral data -- transforms, mesh indices, a node
//! tree -- and stops there, knowing nothing of Assets or Scene. This file is the
//! other half: it uploads that file's meshes to the GPU, then walks the node
//! tree into the engine's Scene, resolving each glTF mesh index to a real
//! MeshHandle. The dependency arrow points one way -- scene depends on render,
//! never the reverse -- so this bridge lives on the scene side.

const std = @import("std");

const gltf = @import("../render/gltf.zig");
const assets_mod = @import("assets.zig");
const scene_mod = @import("scene.zig");

const Assets = assets_mod.Assets;
const MeshHandle = assets_mod.MeshHandle;
const Scene = scene_mod.Scene;
const ObjectHandle = scene_mod.ObjectHandle;

/// Loads a .glb from disk into `scene`, uploading its meshes into `assets`. Every
/// node becomes an Object; the hierarchy is preserved through Scene.addChild, so
/// a moved parent carries its children. A shared `material` is used for all of
/// them -- glTF materials are a later concern; geometry and hierarchy come first.
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    assets: *Assets,
    scene: *Scene,
    material: scene_mod.MaterialHandle,
    path: []const u8,
) !void {
    // Read the file once, split the container, and parse the node tree.
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    const glb = try gltf.parseGlb(bytes);
    var gltf_scene = try gltf.parseScene(allocator, glb);
    defer gltf_scene.deinit();

    // Upload every mesh in the file, building glTF-mesh-index -> MeshHandle
    // Some entries stay null only if a mesh fails to load; here all succeed.
    const mesh_handles = try allocator.alloc(?MeshHandle, gltf_scene.meshCount());
    defer allocator.free(mesh_handles);
    for (0..gltf_scene.meshCount()) |i| {
        var cpu_mesh = try gltf.loadMesh(allocator, glb, i);
        // addMesh copies to the GPU; the CPU copy is dead weight after.
        mesh_handles[i] = try assets.addMesh(allocator, cpu_mesh);
        cpu_mesh.deinit();
    }

    // Walk each root into the scene. Children recurse, pinned to their parent.
    for (gltf_scene.roots) |root_idx| {
        try addNode(scene, gltf_scene, mesh_handles, material, root_idx, null);
    }
}

/// Recursively turns glTF node `index` into an Object under `parent`, then does
/// the same for its children. A node's mesh index (if any) is resolved through
/// `mesh_handles`; a node without one becomes a transform-only Object.
fn addNode(
    scene: *Scene,
    gltf_scene: gltf.Scene,
    mesh_handles: []const ?MeshHandle,
    material: scene_mod.MaterialHandle,
    index: usize,
    parent: ?ObjectHandle,
) !void {
    if (index >= gltf_scene.nodes.len) return;
    const node = gltf_scene.nodes[index];

    // Resolve the mesh, if the node has one and it uploaded.
    const mesh: ?MeshHandle = if (node.mesh) |m|
        (if (m < mesh_handles.len) mesh_handles[m] else null)
    else
        null;

    // Root nodes have no parent; children are pinned via addChild.
    const handle = if (parent) |p|
        try scene.addChild(p, mesh, material, node.transform)
    else
        try scene.addObject(mesh, material, node.transform);

    for (node.children) |child_idx| {
        try addNode(scene, gltf_scene, mesh_handles, material, child_idx, handle);
    }
}
