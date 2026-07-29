//! Turning a glTF skin into a shared rig.
//!
//! gltf.zig read the skin as neutral data: which nodes are joints, and each
//! joint's inverse bind matrix. This file builds the rig from that -- the joints
//! in skin order, their parents among the joints, and the clips the model was
//! authored with -- and offers the sampling a pose is made of.
//!
//! What it does not do is play or pose. A rig is shared: every character on the
//! same model reads these same joints and clips. Where each character has got to
//! in a clip, and the matrices that evaluates to, are per-character state an
//! Animator holds. The skinning matrix for joint j is world(j) * inverseBind(j),
//! and the Animator is where that product is formed.

const std = @import("std");
const math = @import("../math/math.zig");
const gltf = @import("../render/gltf.zig");

const Transform = @import("../render/mesh.zig").Transform;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Quat = math.Quat;

/// One joint's place in the skeleton: its rest transform, and its parent among
/// the joints (or null if it is a root joint). Built from the glTF node tree.
pub const Joint = struct {
    /// The rest transform, as TRS. A pose is sampled starting from this, so it is
    /// the un-animated baseline every clip departs from. Never mutated: the rig
    /// is shared, and posing writes to an Animator's scratch, not here.
    bind: Transform,
    /// Index into the skeleton's joint array, or null for a root.
    parent: ?usize,
    /// The glTF node this joint came from. Animation channels target nodes, so
    /// this is how a channel finds its joint.
    node: usize,
    /// The joint's name, copied from the glTF node. Owned by the skeleton.
    /// Animation loaded from a separate file binds to this by name, because the
    /// node indices of another file mean nothing here.
    name: []const u8,
};

/// A shared rig: the joints in skin order, their inverse binds, and the clips
/// the model was authored with. No playback state and no scratch -- an Animator
/// holds those, one per character. Owns its allocations.
pub const Skeleton = struct {
    joints: []Joint,
    inverse_binds: []Mat4,
    /// Every clip the file brought, in file order. Empty when the model is not
    /// animated. Owned: the skeleton frees them.
    ///
    /// A rig holds all of them rather than one, because switching between clips
    /// is the ordinary case -- idle, walk, run -- and a blend needs two of them
    /// alive at the same time.
    clips: []gltf.Animation = &.{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Skeleton) void {
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        for (self.joints) |joint| self.allocator.free(joint.name);
        self.allocator.free(self.joints);
        self.allocator.free(self.inverse_binds);
        self.* = undefined;
    }

    /// The joint driven by glTF node `node_idx`, or null if no joint came from
    /// that node. Animation channels name nodes; this maps them to joints.
    pub fn jointForNode(self: *const Skeleton, node_idx: usize) ?usize {
        for (self.joints, 0..) |joint, j| {
            if (joint.node == node_idx) return j;
        }
        return null;
    }

    /// The index of the clip with this name, or null. Names come from the file
    /// ("Survey", "Walk", "Run" in Fox.glb); a game asks for the one it means
    /// rather than counting positions in a list it did not write.
    pub fn clipByName(self: *const Skeleton, name: []const u8) ?usize {
        for (self.clips, 0..) |clip, i| {
            if (std.mem.eql(u8, clip.name, name)) return i;
        }
        return null;
    }

    /// Fills `out` with the pose `anim` holds at time `t` -- one Transform per
    /// joint, in joint order.
    ///
    /// A pose is a value here: sampling one touches nothing, which is what lets
    /// two of them be blended before either reaches the joints. Translation and
    /// scale interpolate linearly, rotation by slerp (the shortest arc on the
    /// unit sphere, which a linear blend of quaternions would not trace).
    ///
    /// A joint no channel drives keeps its bind transform, so a clip that
    /// animates only the arms leaves the legs standing rather than collapsing.
    pub fn samplePose(self: *const Skeleton, anim: gltf.Animation, t: f32, out: []Transform) void {
        for (self.joints, 0..) |joint, j| out[j] = joint.bind;

        for (anim.channels) |channel| {
            const j = self.jointForNode(channel.node) orelse continue;
            const sampler = anim.samplers[channel.sampler];
            switch (channel.path) {
                .translation => out[j].position = sampleVec3(sampler, t),
                .rotation => out[j].rotation = sampleQuat(sampler, t),
                .scale => out[j].scale = sampleVec3(sampler, t),
            }
        }
    }

    /// Fills `out` with the rest pose. The pose a skeleton holds when nothing
    /// drives it, and -- until there is an idle clip -- the thing a walk blends
    /// out to when the character stops.
    pub fn sampleBindPose(self: *const Skeleton, out: []Transform) void {
        for (self.joints, 0..) |joint, j| out[j] = joint.bind;
    }

    /// Mixes two poses into `out`: `weight` of 0 gives `a`, 1 gives `b`.
    ///
    /// Poses are blended as transforms, never as matrices. Interpolating two
    /// rotation matrices bends the result out of shape -- it stops being a
    /// rotation partway through -- whereas slerping the quaternions traces the
    /// arc between them and stays a rotation the whole way.
    ///
    /// The weight is one number for the whole skeleton today. Per-joint weights
    /// are what layered blending needs (an upper body doing one thing while the
    /// legs do another), and would change this signature and nothing else.
    pub fn blendPoses(
        a: []const Transform,
        b: []const Transform,
        weight: f32,
        out: []Transform,
    ) void {
        const w = std.math.clamp(weight, 0, 1);
        for (out, 0..) |*t, j| {
            t.position = a[j].position.add(b[j].position.sub(a[j].position).scale(w));
            t.scale = a[j].scale.add(b[j].scale.sub(a[j].scale).scale(w));
            t.rotation = a[j].rotation.slerp(b[j].rotation, w);
        }
    }

    /// The transform one joint holds in `anim` at time `t`.
    ///
    /// Sampling a whole pose to read one joint would be the tidier call, but the
    /// outgoing pose of a blend is read exactly once per joint, and a second
    /// scratch array to hold it would be allocated for the length of one loop.
    pub fn sampleJoint(self: *const Skeleton, anim: gltf.Animation, t: f32, joint: usize) Transform {
        var result = self.joints[joint].bind;
        const node = self.joints[joint].node;

        for (anim.channels) |channel| {
            if (channel.node != node) continue;
            const sampler = anim.samplers[channel.sampler];
            switch (channel.path) {
                .translation => result.position = sampleVec3(sampler, t),
                .rotation => result.rotation = sampleQuat(sampler, t),
                .scale => result.scale = sampleVec3(sampler, t),
            }
        }
        return result;
    }
};

/// Builds a skeleton from a glTF skin and the scene its joints live in. The skin
/// names joints by node index; this resolves each to its rest transform and its
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
        const joint_name = try allocator.dupe(u8, node.name);
        errdefer allocator.free(joint_name);
        joints[j] = .{ .bind = node.transform, .parent = parent, .node = node_idx, .name = joint_name };
    }

    const inverse_binds = try allocator.alloc(Mat4, n);
    errdefer allocator.free(inverse_binds);
    @memcpy(inverse_binds, skin.inverse_binds);

    return .{
        .joints = joints,
        .inverse_binds = inverse_binds,
        .allocator = allocator,
    };
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

test "a model's clips load and resolve by name" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const file = std.Io.Dir.cwd().openFile(io, "assets/gltf/Fox.glb", .{}) catch |err| {
        std.debug.print("skipping clip test: {}\n", .{err});
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

    // Fox carries three: an idle ("Survey"), a walk, and a run.
    const count = try gltf.animationCount(a, glb);
    try std.testing.expectEqual(@as(usize, 3), count);

    const clips = try a.alloc(gltf.Animation, count);
    for (0..count) |i| clips[i] = try gltf.parseAnimation(a, glb, i);
    skel.clips = clips; // the skeleton owns them from here

    // Names come from the file, and asking by name is how a game says which clip
    // it means. Posing and blending are the Animator's to test, not the rig's.
    const walk = skel.clipByName("Walk") orelse return error.TestUnexpectedResult;
    const run = skel.clipByName("Run") orelse return error.TestUnexpectedResult;
    try std.testing.expect(walk != run);
    try std.testing.expect(skel.clipByName("NoSuchClip") == null);

    // Each clip has its own length -- a fixed loop duration would be wrong for
    // at least two of the three.
    for (skel.clips) |clip| try std.testing.expect(clip.duration > 0);
}
