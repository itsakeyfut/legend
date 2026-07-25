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
const Mat4 = math.Mat4;

const Transform = @import("../render/mesh.zig").Transform;

const assets = @import("assets.zig");
const MeshHandle = assets.MeshHandle;
const TextureHandle = assets.TextureHandle;

pub const MaterialMap = slotmap.SlotMap(Material);
pub const ObjectMap = slotmap.SlotMap(Object);

pub const MaterialHandle = MaterialMap.Key;
pub const ObjectHandle = ObjectMap.Key;

const SkeletonHandle = @import("assets.zig").SkeletonHandle;
const Animator = @import("animator.zig").Animator;
const Skeleton = @import("skeleton.zig").Skeleton;

pub const AnimatorMap = slotmap.SlotMap(Animator);
pub const AnimatorHandle = AnimatorMap.Key;

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

/// One renderable instance: which mesh, which material, and where -- where being
/// relative to its parent, or to the world if it has none.
pub const Object = struct {
    mesh: ?MeshHandle,
    material: MaterialHandle,
    transform: Transform = .{},
    /// The object this one is pinned to. When the parent moves, this moves with
    /// it; moving this leaves the parent alone. Null means the object sits
    /// directly in world space -- a root.
    parent: ?ObjectHandle = null,
    /// The skeleton posing this object's skinned mesh, or null for a static
    /// mesh. Its presence routes the object through the skinning pipeline.
    skeleton: ?SkeletonHandle = null,
    /// This object's own animation playback, or null if it is not animated.
    ///
    /// Separate from the skeleton because the two are shared differently: the
    /// skeleton is the rig, one copy however many characters use it, while the
    /// animator is where this character has got to in its own clip. Two foxes
    /// share a skeleton and never an animator.
    animator: ?AnimatorHandle = null,
};

pub const Scene = struct {
    materials: MaterialMap,
    objects: ObjectMap,
    light: Light = .{},
    animators: AnimatorMap,

    pub fn init(allocator: std.mem.Allocator) !Scene {
        var materials = try MaterialMap.init(allocator);
        errdefer materials.deinit();
        var objects = try ObjectMap.init(allocator);
        errdefer objects.deinit();
        const animators = try AnimatorMap.init(allocator);

        return .{
            .materials = materials,
            .objects = objects,
            .animators = animators,
        };
    }

    pub fn deinit(self: *Scene) void {
        var anim_it = self.animators.valueIterator();
        while (anim_it.next()) |a| a.deinit();
        self.animators.deinit();
        self.materials.deinit();
        self.objects.deinit();
    }

    pub fn addMaterial(self: *Scene, mat: Material) !MaterialHandle {
        return self.materials.insert(mat);
    }

    pub fn addObject(
        self: *Scene,
        mesh: ?MeshHandle,
        mat: MaterialHandle,
        transform: Transform,
    ) !ObjectHandle {
        return self.objects.insert(.{ .mesh = mesh, .material = mat, .transform = transform });
    }

    /// As addObject, but pinned to a parent: the transform is now relative to it.
    pub fn addChild(
        self: *Scene,
        parent: ObjectHandle,
        mesh: ?MeshHandle,
        mat: MaterialHandle,
        transform: Transform,
    ) !ObjectHandle {
        return self.objects.insert(.{
            .mesh = mesh,
            .material = mat,
            .transform = transform,
            .parent = parent,
        });
    }

    pub fn removeObject(self: *Scene, handle: ObjectHandle) void {
        _ = self.objects.remove(handle);
    }

    /// Binds a skeleton an existing object, routing it through the skinning
    /// pipeline. Kept separate from addObject/addChild so those don't grow a
    /// variant per optional component; this is the seam where a skeleton
    /// invariant could later be enforced.
    pub fn setSkeleton(self: *Scene, handle: ObjectHandle, skel: SkeletonHandle) void {
        if (self.objects.getPtr(handle)) |obj| obj.skeleton = skel;
    }

    /// Gives an object its own animation playback, sized to `rig`. The scene
    /// owns the animator from here and frees it with the rest.
    pub fn addAnimator(
        self: *Scene,
        allocator: std.mem.Allocator,
        rig: *const Skeleton,
    ) !AnimatorHandle {
        var anim = try Animator.init(allocator, rig);
        errdefer anim.deinit();
        return self.animators.insert(anim);
    }

    /// Binds an animator to an existing object, the same seam setSkeleton uses.
    pub fn setAnimator(self: *Scene, handle: ObjectHandle, anim: AnimatorHandle) void {
        if (self.objects.getPtr(handle)) |obj| obj.animator = anim;
    }

    /// The first object bound to `skel`, or null. load_gltf binds a skeleton to
    /// the node that carries the skinned mesh -- often a child of the model root,
    /// not the root itself -- so a game that has only the skeleton handle needs
    /// this to find the object an animator must go on.
    pub fn objectWithSkeleton(self: *Scene, skel: SkeletonHandle) ?ObjectHandle {
        var it = self.objects.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.skeleton) |s| {
                if (s.index == skel.index and s.generation == skel.generation) return entry.key;
            }
        }
        return null;
    }

    pub fn animator(self: *Scene, handle: AnimatorHandle) ?*Animator {
        return self.animators.getPtr(handle);
    }

    /// Re-evaluates every animated object's pose: the update phase, run once a
    /// frame before the draw list is built.
    ///
    /// Kept apart from drawing on purpose. Posing inside the draw meant one
    /// character could be posed at a time and the work was tangled with
    /// uploading it; separated, any number of characters can be brought up to
    /// date first and drawn afterwards. Once a frame rather than once a
    /// simulation step, because only the last evaluation of a frame is ever
    /// seen -- advancing the clock is cheap, evaluating a pose is not.
    pub fn evaluateAnimators(self: *Scene, asset_store: *assets.Assets) void {
        var it = self.objects.iterator();
        while (it.next()) |entry| {
            const obj = entry.value_ptr;
            const anim_handle = obj.animator orelse continue;
            const skel_handle = obj.skeleton orelse continue;
            const anim = self.animators.getPtr(anim_handle) orelse continue;
            const rig = asset_store.skeleton(skel_handle) orelse continue;
            anim.evaluate(rig);
        }
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

    /// The maximum parent chain length before resolution gives up. Not a cycle
    /// detector -- it is a safety valve, so a scene that accidentally points an
    /// object at its own descendant stops instead of looping forever. Real
    /// hierarchies are nowhere near this deep.
    pub const max_depth = 64;

    /// An object's world matrix: its own local transform, with every ancestor's
    /// transform applied outward from it to the root.
    ///
    /// world = parent_world * local, unrolled up the chain. Ancestors are walked
    /// one at a time and their local matrices accumulated; a shared parent is
    /// therefore recomputed once per child, which is wasteful but correct, and
    /// correctness is what a first version owes. Caching is a later problem, and
    /// only once there are enough objects to make it one.
    pub fn worldMatrix(self: *Scene, handle: ObjectHandle) Mat4 {
        const obj = self.objects.getPtr(handle) orelse return Mat4.identity();

        var result = obj.transform.matrix();
        var current = obj.parent;
        var depth: usize = 0;

        while (current) |parent_handle| {
            if (depth >= max_depth) break;
            const parent = self.objects.getPtr(parent_handle) orelse break;
            // Parent's local sits to the left: it is applied after the child's,
            // so the child is first placed within the parent, then carried by it.
            result = parent.transform.matrix().mul(result);
            current = parent.parent;
            depth += 1;
        }

        return result;
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
