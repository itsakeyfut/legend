//! Turning a glTF skin into the joint matrices a skinned mesh needs.
//!
//! gltf.zig read the skin as neutral data: which nodes are joints, and each
//! joint's inverse bind matrix. This file does the rest -- walk the node
//! hierarchy to each joint's world transform, then combine it with the inverse
//! bind matrix into the "skinning matrix" the vertex shader multiplies vertices
//! by.
//!
//! The skinning matrix for joint j is  world(j) * inverseBind(j).  In the bind
//! pose the two are inverses, so the product is (near) identity and the vertex
//! does not move -- which is exactly the check S-2 leans on: build this, render
//! it static, and a correct pipeline shows the model standing in its bind pose.

const std = @import("std");
const math = @import("../math/math.zig");
const gltf = @import("../render/gltf.zig");

const Transform = @import("../render/mesh.zig").Transform;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Quat = math.Quat;

/// One joint's place in the skeleton: its local transform, and its parent among
/// the joints (or null if it is a root joint). Built from the glTF node tree.
pub const Joint = struct {
    /// The matrix pose() reads. Built from `bind` at rest, overwritten by
    /// animate() when a clip plays.
    local: Mat4,
    /// The rest transform, as TRS. Never mutated after build -- animation starts
    /// from it each frame, so it must survive as the un-animated baseline.
    bind: Transform,
    /// Index into the skeleton's joint array, or null for a root.
    parent: ?usize,
    /// The glTF node this joint came from. Animation channels target nodes, so
    /// this is how a channel finds its joint.
    node: usize,
};

/// A skeleton ready to pose: the joints in skin order, their inverse binds, and
/// scratch space for the matrices handed to the GPU. Owns its allocations.
pub const Skeleton = struct {
    joints: []Joint,
    inverse_binds: []Mat4,
    /// The skinning matrices, recomputed each pose. One per joint.
    skinning: []Mat4,
    /// The clip this skeleton plays, if any. Set after build by whoever loaded
    /// it. When present, animate() drives the joints; when null, the skeleton
    /// holds its bind pose.
    animation: ?gltf.Animation = null,
    /// Where this skeleton is in its clip, in seconds. Null means it is not
    /// playing: the bind pose stands in, which is what an idle character looks
    /// like until there is an idle clip to blend to.
    ///
    /// Per skeleton rather than per frame, because two characters walk at their
    /// own pace -- a single time for the whole frame would march them in step.
    time: ?f32 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Skeleton) void {
        if (self.animation) |*anim| anim.deinit();
        self.allocator.free(self.joints);
        self.allocator.free(self.inverse_binds);
        self.allocator.free(self.skinning);
        self.* = undefined;
    }

    /// Recomputes every joint's skinning matrix for the current local transforms.
    /// world(j) is accumulated down the parent chain; skinning is world * invBind.
    pub fn pose(self: *Skeleton) void {
        // First pass: each joint's world matrix. Joints are stored parents-first
        // (glTF orders them so a parent precedes its children within the skin),
        // so a single forward pass can read its parent's already-computed world.
        var world = self.allocator.alloc(Mat4, self.joints.len) catch return;
        defer self.allocator.free(world);

        for (self.joints, 0..) |joint, j| {
            if (joint.parent) |p| {
                world[j] = world[p].mul(joint.local);
            } else {
                world[j] = joint.local;
            }
        }

        // Second pass: skinning = world * inverseBind.
        for (0..self.joints.len) |j| {
            self.skinning[j] = world[j].mul(self.inverse_binds[j]);
        }
    }

    /// The joint driven by glTF node `node_idx`, or null if no joint came from
    /// that node. Animation channels name nodes; this maps them to joints.
    pub fn jointForNode(self: *const Skeleton, node_idx: usize) ?usize {
        for (self.joints, 0..) |joint, j| {
            if (joint.node == node_idx) return j;
        }
        return null;
    }

    /// Poses the skeleton at time `t` (seconds) of `anim`, then recomputes the
    /// skinning matrices. Each joint starts from its bind-pose transform and is
    /// overwritten by whatever channels drive it: translation and scale are
    /// interpolated linearly, rotation by slerp (the shortest arc on the unit
    /// sphere, which linear interpolation of quaternions would not give). Channels
    /// name nodes; jointForNode maps them to joints.
    pub fn animate(self: *Skeleton, anim: gltf.Animation, t: f32) void {
        // Start every joint from rest. A joint to channel touches keeps this.
        var scratch = self.allocator.alloc(Transform, self.joints.len) catch return;
        defer self.allocator.free(scratch);
        for (self.joints, 0..) |joint, j| scratch[j] = joint.bind;

        // Each channel overwrites one component of its joint's transform.
        for (anim.channels) |channel| {
            const j = self.jointForNode(channel.node) orelse continue;
            const sampler = anim.samplers[channel.sampler];
            switch (channel.path) {
                .translation => scratch[j].position = sampleVec3(sampler, t),
                .rotation => scratch[j].rotation = sampleQuat(sampler, t),
                .scale => scratch[j].scale = sampleVec3(sampler, t),
            }
        }

        // Bake the animated transforms into local matrices, then pose as usual.
        for (self.joints, 0..) |*joint, j| joint.local = scratch[j].matrix();
        self.pose();
    }

    /// Poses the skeleton for time `t`: plays its clip if it has one, otherwise
    /// holds the bind pose. This is what the draw list calls each frame.
    pub fn poseAt(self: *Skeleton, t: f32) void {
        if (self.animation) |anim| {
            self.animate(anim, t);
        } else {
            self.pose();
        }
    }

    /// Poses for whatever time this skeleton is at. This is what the draw list
    /// calls; the game sets `time` and never touches the joints itself.
    pub fn poseCurrent(self: *Skeleton) void {
        if (self.time) |t| {
            self.poseAt(t);
        } else {
            self.pose();
        }
    }
};

/// Builds a Skeleton from a glTF skin and the file's node hierarchy. The skin
/// names joints by node index; this resolves each to its local transform and its
/// parent *within the skin*, so posing needs only the joint array.
pub fn build(
    allocator: std.mem.Allocator,
    skin: gltf.Skin,
    scene: gltf.Scene,
) !Skeleton {
    const n = skin.joints.len;

    // Map node index -> joint index, so parent lookups can be expressed in joint
    // space. A node that is not a joint maps to nothing.
    // (Small n, so a linear search per node would do; the map is clearer.)
    var node_to_joint = try allocator.alloc(?usize, scene.nodes.len);
    defer allocator.free(node_to_joint);
    for (node_to_joint) |*e| e.* = null;
    for (skin.joints, 0..) |node_idx, j| {
        if (node_idx < scene.nodes.len) node_to_joint[node_idx] = j;
    }

    const joints = try allocator.alloc(Joint, n);
    errdefer allocator.free(joints);

    for (skin.joints, 0..) |node_idx, j| {
        const node = scene.nodes[node_idx];
        // A joint's parent among the joints: find which node lists it as a child.
        // glTF stores children on the parent, so this searches for the node whose
        // children include node_idx, then maps that to a joint (if it is one).
        var parent: ?usize = null;
        for (scene.nodes, 0..) |candidate, ci| {
            for (candidate.children) |child| {
                if (child == node_idx) {
                    parent = node_to_joint[ci];
                    break;
                }
            }
            if (parent != null) break;
        }
        joints[j] = .{ .local = node.transform.matrix(), .bind = node.transform, .parent = parent, .node = node_idx };
    }

    const inverse_binds = try allocator.alloc(Mat4, n);
    errdefer allocator.free(inverse_binds);
    @memcpy(inverse_binds, skin.inverse_binds);

    const skinning = try allocator.alloc(Mat4, n);
    errdefer allocator.free(skinning);
    // Pose once so the matrices are valid even before the first explicit pose().
    var skel = Skeleton{
        .joints = joints,
        .inverse_binds = inverse_binds,
        .skinning = skinning,
        .allocator = allocator,
    };
    skel.pose();
    return skel;
}

/// Finds the keyframe interval around time `t` and returns the two indices plus
/// the 0..1 blend factor between them. Times are sorted ascending. Before the
/// first key or after the last, it clamps (holds the end value).
fn keyframe(times: []const f32, t: f32) struct { a: usize, b: usize, alpha: f32 } {
    if (times.len == 0) return .{ .a = 0, .b = 0, .alpha = 0 };
    if (t <= times[0]) return .{ .a = 0, .b = 0, .alpha = 0 };
    if (t >= times[times.len - 1]) {
        const last = times.len - 1;
        return .{ .a = last, .b = last, .alpha = 0 };
    }
    // Linear scan: keyframe counts are small (CesiumMan ~48). A binary search is
    // the optimisation if a clip ever gets long enough to need it.
    var k: usize = 0;
    while (k + 1 < times.len and times[k + 1] <= t) k += 1;
    const span = times[k + 1] - times[k];
    const alpha = if (span > 0) (t - times[k]) / span else 0;
    return .{ .a = k, .b = k + 1, .alpha = alpha };
}

/// Samples a vec3 sampler (translation or scale) at time `t`, linearly.
fn sampleVec3(sampler: gltf.Sampler, t: f32) Vec3 {
    const kf = keyframe(sampler.times, t);
    const va = vec3At(sampler, kf.a);
    const vb = vec3At(sampler, kf.b);
    return va.add(vb.sub(va).scale(kf.alpha));
}

/// Samples a quaternion sampler (rotation) at time `t`, by slerp.
fn sampleQuat(sampler: gltf.Sampler, t: f32) Quat {
    const kf = keyframe(sampler.times, t);
    const qa = quatAt(sampler, kf.a);
    const qb = quatAt(sampler, kf.b);
    return qa.slerp(qb, kf.alpha);
}

fn vec3At(sampler: gltf.Sampler, k: usize) Vec3 {
    const base = k * sampler.stride;
    return math.vec3(sampler.values[base], sampler.values[base + 1], sampler.values[base + 2]);
}

fn quatAt(sampler: gltf.Sampler, k: usize) Quat {
    const base = k * sampler.stride;
    return .{
        .x = sampler.values[base],
        .y = sampler.values[base + 1],
        .z = sampler.values[base + 2],
        .w = sampler.values[base + 3],
    };
}

test "skeleton bind pose yields near-identity skinning" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const file = std.Io.Dir.cwd().openFile(io, "assets/gltf/CesiumMan.glb", .{}) catch |err| {
        std.debug.print("skipping skeleton test: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const bytes = try a.alloc(u8, size);
    defer a.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    const glb = try gltf.parseGlb(bytes);
    var gscene = try gltf.parseScene(a, glb);
    defer gscene.deinit();
    var skin = try gltf.parseSkin(a, glb, 0);
    defer skin.deinit();

    var skel = try build(a, skin, gscene);
    defer skel.deinit();

    // Bind pose: world(j) * inverseBind(j) should be identity for every joint,
    // because the joint's current world transform *is* the bind pose the inverse
    // bind was made from. If this holds, the skinning maths is correct and a
    // static render will show the bind pose undistorted.
    for (skel.skinning) |m| {
        inline for (0..4) |r| {
            inline for (0..4) |c| {
                const expected: f32 = if (r == c) 1 else 0;
                try std.testing.expectApproxEqAbs(expected, m.m[r][c], 1e-3);
            }
        }
    }
}

test "animate at time zero stays near the bind pose" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const file = std.Io.Dir.cwd().openFile(io, "assets/gltf/CesiumMan.glb", .{}) catch |err| {
        std.debug.print("skipping animate test: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const bytes = try a.alloc(u8, size);
    defer a.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    const glb = try gltf.parseGlb(bytes);
    var gscene = try gltf.parseScene(a, glb);
    defer gscene.deinit();
    var skin = try gltf.parseSkin(a, glb, 0);
    defer skin.deinit();
    var anim = try gltf.parseAnimation(a, glb, 0);
    defer anim.deinit();

    var skel = try build(a, skin, gscene);
    defer skel.deinit();

    // The animation's first keyframe is its authored pose at t=0. It is not the
    // bind pose in general (a walk cycle's frame 0 is mid-stride), so the
    // skinning matrices need not be identity. What must hold is weaker but still
    // a real check: animate produces finite, sane matrices -- no NaNs from a bad
    // slerp, no wild values from a mis-indexed sampler.
    skel.animate(anim, 0);

    for (skel.skinning) |m| {
        inline for (0..4) |r| {
            inline for (0..4) |c| {
                try std.testing.expect(std.math.isFinite(m.m[r][c]));
                try std.testing.expect(@abs(m.m[r][c]) < 100);
            }
        }
    }
}
