//! The scene: objects, materials, and lighting -- the half that is pure data.
//!
//! Nothing here touches the GPU. A material names a texture by handle and holds
//! a tint; an object names a mesh and a material and sits at a transform. All of
//! it is numbers and handles, which is exactly what a saved scene file will
//! contain: this is the structure that decision (2), comptime serialization,
//! will eventually walk. Meshes and textures themselves live in Assets.

const std = @import("std");
const slotmap = @import("slotmap");

const math = @import("../math/math.zig");
const Vec3 = math.Vec3;

const Transform = @import("../render/mesh.zig").Transform;

const assets = @import("assets.zig");
const MeshHandle = assets.MeshHandle;
const TextureHandle = assets.TextureHandle;

pub const MaterialMap = slotmap.SlotMap(Material);
pub const ObjectMap = slotmap.SlotMap(Object);

pub const MaterialHandle = MaterialMap.Key;
pub const ObjectHandle = ObjectMap.Key;

/// A single directional light.
pub const Light = struct {
    dir: Vec3 = math.vec3(0.35, 0.85, 0.4),
};

/// How a surface looks: a texture, and a tint multiplied over it. Materials are
/// cheap and textures are not, so many materials can share one texture and
/// differ only in tint.
pub const Material = struct {
    texture: TextureHandle,
    tint: Vec3 = math.vec3(1, 1, 1),
};

/// One renderable instance: which mesh, which material, and where.
pub const Object = struct {
    mesh: MeshHandle,
    material: MaterialHandle,
    transform: Transform = .{},
};

pub const Scene = struct {
    materials: MaterialMap,
    objects: ObjectMap,
    light: Light = .{},

    pub fn init(allocator: std.mem.Allocator) !Scene {
        var materials = try MaterialMap.init(allocator);
        errdefer materials.deinit();
        const objects = try ObjectMap.init(allocator);

        return .{
            .materials = materials,
            .objects = objects,
        };
    }

    pub fn deinit(self: *Scene) void {
        self.materials.deinit();
        self.objects.deinit();
    }

    pub fn addMaterial(self: *Scene, mat: Material) !MaterialHandle {
        return self.materials.insert(mat);
    }

    pub fn addObject(
        self: *Scene,
        mesh: MeshHandle,
        mat: MaterialHandle,
        transform: Transform,
    ) !ObjectHandle {
        return self.objects.insert(.{ .mesh = mesh, .material = mat, .transform = transform });
    }

    pub fn removeObject(self: *Scene, handle: ObjectHandle) void {
        _ = self.objects.remove(handle);
    }

    pub fn object(self: *Scene, handle: ObjectHandle) ?*Object {
        return self.objects.getPtr(handle);
    }

    pub fn material(self: *Scene, handle: MaterialHandle) ?*Material {
        return self.materials.getPtr(handle);
    }

    pub fn objectCount(self: Scene) usize {
        return self.objects.count();
    }

    pub fn objectIterator(self: *Scene) ObjectMap.Iterator {
        return self.objects.iterator();
    }
};

test "scene holds objects and resolves handles" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();

    // Handles from an empty map are fine to store; they simply never resolve.
    const dummy_mesh: MeshHandle = .{ .index = 0, .generation = 0 };
    const mat = try scene.addMaterial(.{ .texture = .{ .index = 0, .generation = 0 } });

    const a = try scene.addObject(dummy_mesh, mat, .{});
    const b = try scene.addObject(dummy_mesh, mat, .{ .position = math.vec3(3, 0, 0) });

    try std.testing.expectEqual(@as(usize, 2), scene.objectCount());

    scene.removeObject(a);
    try std.testing.expectEqual(@as(usize, 1), scene.objectCount());
    try std.testing.expect(scene.object(a) == null);
    try std.testing.expect(scene.object(b) != null);
}

test "several materials can share one texture" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();

    const shared: TextureHandle = .{ .index = 1, .generation = 0 };
    const red = try scene.addMaterial(.{ .texture = shared, .tint = math.vec3(1, 0.3, 0.3) });
    const blue = try scene.addMaterial(.{ .texture = shared, .tint = math.vec3(0.3, 0.3, 1) });

    try std.testing.expectEqual(shared, scene.material(red).?.texture);
    try std.testing.expectEqual(shared, scene.material(blue).?.texture);
}
