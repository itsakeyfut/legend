//! Scene graph (flat, for now): owns meshes, textures, materials and objects,
//! all held in generational slot maps so they can be created and destroyed at
//! runtime without dangling handles.

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

pub const Texture = image.Image(.rgb);

pub const MeshMap = slotmap.SlotMap(Mesh);
pub const TextureMap = slotmap.SlotMap(Texture);
pub const MaterialMap = slotmap.SlotMap(Material);
pub const ObjectMap = slotmap.SlotMap(Object);

/// Handles are values, not pointers: they stay valid to *hold* even after the
/// thing they point at is destroyed, and simply stop resolving.
pub const MeshHandle = MeshMap.Key;
pub const TextureHandle = TextureMap.Key;
pub const MaterialHandle = MaterialMap.Key;
pub const ObjectHandle = ObjectMap.Key;

/// A single directional light.
pub const Light = struct {
    dir: Vec3,
};

/// How a surface looks. Materials are cheap and textures are not, so several
/// materials can point at the same texture and differ only in `tint`.
pub const Material = struct {
    texture: TextureHandle,
    tint: Vec3 = math.vec3(1, 1, 1),
    ambient: f32 = 0.2,
    diffuse: f32 = 0.8,
};

/// One renderable instance: which mesh, and where it sits in the world.
pub const Object = struct {
    mesh: MeshHandle,
    material: MaterialHandle,
    transform: Transform = .{},
};

pub const Scene = struct {
    meshes: MeshMap,
    textures: TextureMap,
    materials: MaterialMap,
    objects: ObjectMap,

    /// A 1x1 white texel. A material wanting a flat colour points here and sets
    /// `tint`, so the rasterizer never needs an "untextured" code path.
    white: TextureHandle,
    /// Untinted white. For objects that don't care what they look like yet.
    default_material: MaterialHandle,

    pub fn init(allocator: std.mem.Allocator) !Scene {
        var meshes = try MeshMap.init(allocator);
        errdefer meshes.deinit();
        var textures = try TextureMap.init(allocator);
        errdefer textures.deinit();
        var materials = try MaterialMap.init(allocator);
        errdefer materials.deinit();
        var objects = try ObjectMap.init(allocator);
        errdefer objects.deinit();

        var white_image = try Texture.init(allocator, 1, 1);
        errdefer white_image.deinit();
        white_image.pixels[0] = .{ .r = 255, .g = 255, .b = 255 };

        const white = try textures.insert(white_image);
        const default_material = try materials.insert(.{ .texture = white });

        return .{
            .meshes = meshes,
            .textures = textures,
            .materials = materials,
            .objects = objects,
            .white = white,
            .default_material = default_material,
        };
    }

    /// Frees every mesh the scene owns, then the maps themselves.
    pub fn deinit(self: *Scene) void {
        var mesh_it = self.meshes.iterator();
        while (mesh_it.next()) |e| e.value_ptr.deinit();
        self.meshes.deinit();

        var tex_it = self.textures.iterator();
        while (tex_it.next()) |e| e.value_ptr.deinit();
        self.textures.deinit();

        self.materials.deinit();
        self.objects.deinit();
    }

    /// Takes ownership of `mesh`; it is freed by `Scene.deinit`.
    pub fn addMesh(self: *Scene, mesh: Mesh) !MeshHandle {
        return self.meshes.insert(mesh);
    }

    /// Takes ownership of `texture`; freed by `Scene.deinit`.
    pub fn addTexture(self: *Scene, texture: Texture) !TextureHandle {
        return self.textures.insert(texture);
    }

    /// Takes ownership of `material`; freed by `Scene.deinit`.
    pub fn addMaterial(self: *Scene, mat: Material) !MaterialHandle {
        return self.materials.insert(mat);
    }

    pub fn addObject(self: *Scene, mesh: MeshHandle, mat: MaterialHandle, transform: Transform) !ObjectHandle {
        return self.objects.insert(.{ .mesh = mesh, .material = mat, .transform = transform });
    }

    pub fn removeObject(self: *Scene, handle: ObjectHandle) void {
        _ = self.objects.remove(handle);
    }

    /// Resolves a handle, or null if the object has been destroyed.
    pub fn object(self: *Scene, handle: ObjectHandle) ?*Object {
        return self.objects.getPtr(handle);
    }

    /// Materials are meant to be tweaked live, so this hands back a pointer.
    pub fn material(self: *Scene, handle: MaterialHandle) ?*Material {
        return self.materials.getPtr(handle);
    }

    pub fn objectCount(self: Scene) usize {
        return self.objects.count();
    }

    pub fn objectIterator(self: *Scene) ObjectMap.Iterator {
        return self.objects.iterator();
    }

    /// Draws every object. The caller is expected to have cleared `fb`.
    /// Objects whose mesh, material or texture handle has gone stale are
    /// skipped rather than crashing -- that is the whole point of the slot map.
    pub fn render(self: *Scene, fb: *Framebuffer, camera: Camera, light: Light) void {
        const w: f32 = @floatFromInt(fb.width());
        const h: f32 = @floatFromInt(fb.height());
        const vp = camera.viewProjection(w / h);

        var it = self.objects.iterator();
        while (it.next()) |e| {
            const obj = e.value_ptr;

            const mesh_ptr = self.meshes.getPtr(obj.mesh) orelse continue;
            const mat = self.materials.get(obj.material) orelse continue;
            const tex_ptr = self.textures.getPtr(mat.texture) orelse continue;

            // Handles resolved: from here down, the renderer sees plain data.
            const surface = draw.Surface{
                .texture = tex_ptr.*,
                .tint = mat.tint,
                .ambient = mat.ambient,
                .diffuse = mat.diffuse,
            };
            draw.drawMesh(fb, mesh_ptr.*, obj.transform.matrix(), vp, surface, light.dir);
        }
    }
};

test "scene owns meshes and resolves handles" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();

    const cube = try scene.addMesh(try Mesh.cube(std.testing.allocator));
    const a = try scene.addObject(cube, scene.default_material, .{});
    const b = try scene.addObject(cube, scene.default_material, .{ .position = math.vec3(3, 0, 0) });

    try std.testing.expectEqual(@as(usize, 2), scene.objectCount());
    try std.testing.expect(scene.object(a) != null);

    scene.removeObject(a);
    try std.testing.expectEqual(@as(usize, 1), scene.objectCount());
    try std.testing.expect(scene.object(a) == null); // stale handle
    try std.testing.expect(scene.object(b) != null);
}

test "several materials can share one texture" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();

    const tex = try Texture.init(std.testing.allocator, 2, 2);
    for (tex.pixels) |*px| px.* = .{ .r = 200, .g = 200, .b = 200 };
    const shared = try scene.addTexture(tex);

    const red = try scene.addMaterial(.{ .texture = shared, .tint = math.vec3(1, 0.3, 0.3) });
    const blue = try scene.addMaterial(.{ .texture = shared, .tint = math.vec3(0.3, 0.3, 1) });

    try std.testing.expectEqual(shared, scene.material(red).?.texture);
    try std.testing.expectEqual(shared, scene.material(blue).?.texture);
    try std.testing.expect(scene.material(red).?.tint.x() > scene.material(blue).?.tint.x());
}

test "materials can be tweaked through their handle" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();

    const m = scene.default_material;
    scene.material(m).?.ambient = 0.9;
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), scene.material(m).?.ambient, 1e-6);
}
