//! Scene graph (flat, for now): owns meshes and renderable objects, both held
//! in generational slot maps so they can be created and destroyed at runtime
//! without dangling handles.

const std = @import("std");
const slotmap = @import("slotmap");

const math = @import("../math/math.zig");
const Vec3 = math.Vec3;
const image = @import("../image/root.zig");

const mesh_mod = @import("../render/mesh.zig");
const Mesh = mesh_mod.Mesh;
const Transform = mesh_mod.Transform;
const fb_mod = @import("../render/framebuffer.zig");
const Framebuffer = fb_mod.Framebuffer;
const draw = @import("../render/draw.zig");
const Camera = @import("../render/camera.zig").Camera;

pub const MeshMap = slotmap.SlotMap(Mesh);
pub const ObjectMap = slotmap.SlotMap(Object);

/// Handles are values, not pointers: they stay valid to *hold* even after the
/// thing they point at is destroyed, and simply stop resolving.
pub const MeshHandle = MeshMap.Key;
pub const ObjectHandle = ObjectMap.Key;

/// A single directional light.
pub const Light = struct {
    dir: Vec3,
    ambient: f32 = 0.25,
};

/// One renderable instance: which mesh, and where it sits in the world.
pub const Object = struct {
    mesh: MeshHandle,
    transform: Transform = .{},
};

pub const Scene = struct {
    meshes: MeshMap,
    objects: ObjectMap,

    pub fn init(allocator: std.mem.Allocator) !Scene {
        return .{
            .meshes = try MeshMap.init(allocator),
            .objects = try ObjectMap.init(allocator),
        };
    }

    /// Frees every mesh the scene owns, then the maps themselves.
    pub fn deinit(self: *Scene) void {
        var it = self.meshes.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        self.meshes.deinit();
        self.objects.deinit();
    }

    /// Takes ownership of `mesh`; it is freed by `Scene.deinit`.
    pub fn addMesh(self: *Scene, mesh: Mesh) !MeshHandle {
        return self.meshes.insert(mesh);
    }

    pub fn addObject(self: *Scene, mesh: MeshHandle, transform: Transform) !ObjectHandle {
        return self.objects.insert(.{ .mesh = mesh, .transform = transform });
    }

    pub fn removeObject(self: *Scene, handle: ObjectHandle) void {
        _ = self.objects.remove(handle);
    }

    /// Resolves a handle, or null if the object has been destroyed.
    pub fn object(self: *Scene, handle: ObjectHandle) ?*Object {
        return self.objects.getPtr(handle);
    }

    pub fn objectCount(self: Scene) usize {
        return self.objects.count();
    }

    pub fn objectIterator(self: *Scene) ObjectMap.Iterator {
        return self.objects.iterator();
    }

    /// Draws every object. The caller is expected to have cleared `fb`.
    pub fn render(
        self: *Scene,
        fb: *Framebuffer,
        camera: Camera,
        tex: image.Image(.rgb),
        light: Light,
    ) void {
        const w: f32 = @floatFromInt(fb.width());
        const h: f32 = @floatFromInt(fb.height());
        const vp = camera.viewProjection(w / h);

        var it = self.objects.iterator();
        while (it.next()) |e| {
            const mesh_ptr = self.meshes.getPtr(e.value_ptr.mesh) orelse continue;
            const model = e.value_ptr.transform.matrix();
            draw.drawMesh(fb, mesh_ptr.*, model, vp, tex, light.dir, light.ambient);
        }
    }
};

test "scene owns meshes and resolves handles" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();

    const cube = try scene.addMesh(try Mesh.cube(std.testing.allocator));
    const a = try scene.addObject(cube, .{});
    const b = try scene.addObject(cube, .{ .position = math.vec3(3, 0, 0) });

    try std.testing.expectEqual(@as(usize, 2), scene.objectCount());
    try std.testing.expect(scene.object(a) != null);

    scene.removeObject(a);
    try std.testing.expectEqual(@as(usize, 1), scene.objectCount());
    try std.testing.expect(scene.object(a) == null); // stale handle
    try std.testing.expect(scene.object(b) != null);
}
