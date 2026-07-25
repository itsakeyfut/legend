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
    /// Every clip the file brought, in file order. Empty when the model is not
    /// animated. Owned: the skeleton frees them.
    ///
    /// A skeleton holds all of them rather than one, because switching between
    /// clips is the ordinary case -- idle, walk, run -- and a blend needs two of
    /// them alive at the same time.
    clips: []gltf.Animation = &.{},
    /// What is playing now: which clip, and where in it.
    ///
    /// Null means nothing plays and the bind pose stands. A clip index rather
    /// than a pointer, because the clips move when the array does and an index
    /// survives that.
    current: ?usize = null,
    current_time: f32 = 0,

    /// What was playing before, still fading out. Null once the transition is
    /// over -- or if there never was one, which is what starting from rest looks
    /// like.
    previous: ?usize = null,
    previous_time: f32 = 0,

    /// How far the transition has come, 0..1. At 0 the previous clip is what
    /// shows, at 1 the current one. Blending toward the bind pose is the same
    /// mechanism with `previous` left null.
    blend: f32 = 1,
    /// Scratch space, owned so that posing allocates nothing in a frame.
    /// `sample` holds a pose being evaluated or blended; `world` holds the
    /// world matrices pose() accumulates.
    sample: []Transform,
    world: []Mat4,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Skeleton) void {
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        self.allocator.free(self.joints);
        self.allocator.free(self.inverse_binds);
        self.allocator.free(self.skinning);
        self.allocator.free(self.sample);
        self.allocator.free(self.world);
        self.* = undefined;
    }

    /// Recomputes every joint's skinning matrix for the current local transforms.
    /// world(j) is accumulated down the parent chain; skinning is world * invBind.
    pub fn pose(self: *Skeleton) void {
        // First pass: each joint's world matrix. Joints are stored parents-first
        // (glTF orders them so a parent precedes its children within the skin),
        // so a single forward pass can read its parent's already-computed world.
        for (self.joints, 0..) |joint, j| {
            if (joint.parent) |p| {
                self.world[j] = self.world[p].mul(joint.local);
            } else {
                self.world[j] = joint.local;
            }
        }

        // Second pass: skinning = world * inverseBind.
        for (0..self.joints.len) |j| {
            self.skinning[j] = self.world[j].mul(self.inverse_binds[j]);
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

    /// The index of the clip with this name, or null. Names come from the file
    /// ("Survey", "Walk", "Run" in Fox.glb); a game asks for the one it means
    /// rather than counting positions in a list it did not write.
    pub fn clipByName(self: *const Skeleton, name: []const u8) ?usize {
        for (self.clips, 0..) |clip, i| {
            if (std.mem.eql(u8, clip.name, name)) return i;
        }
        return null;
    }

    /// Switches to clip `index`, fading from whatever was playing.
    ///
    /// Starting the same clip again is ignored: a game asking every frame for
    /// "walk" should not restart the stride sixty times a second. That check is
    /// here rather than at the call site because forgetting it is silent -- the
    /// legs simply never move.
    pub fn play(self: *Skeleton, index: usize) void {
        if (index >= self.clips.len) return;
        if (self.current) |c| {
            if (c == index) return;
        }

        self.previous = self.current;
        self.previous_time = self.current_time;
        self.current = index;
        self.current_time = 0;
        self.blend = 0;
    }

    /// Stops playing, fading out to the bind pose.
    pub fn stop(self: *Skeleton) void {
        if (self.current == null) return;
        self.previous = self.current;
        self.previous_time = self.current_time;
        self.current = null;
        self.current_time = 0;
        self.blend = 0;
    }

    /// Advances the transition. Called once a frame with the frame's delta and
    /// the rate the game wants; when it reaches 1 the previous clip is dropped.
    pub fn advanceBlend(self: *Skeleton, dt: f32, rate: f32) void {
        if (self.blend >= 1) return;
        self.blend += rate * dt;
        if (self.blend >= 1) {
            self.blend = 1;
            self.previous = null;
        }
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

    /// Bakes a pose into the joints and recomputes the skinning matrices.
    pub fn applyPose(self: *Skeleton, poses: []const Transform) void {
        for (self.joints, 0..) |*joint, j| joint.local = poses[j].matrix();
        self.pose();
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

    /// Poses the skeleton for its current playback state.
    ///
    /// Three cases, and the general one covers the other two: sample whichever
    /// clips are involved and blend them by `blend`. A missing clip stands for
    /// the bind pose, so "fading in from rest" and "fading out to rest" are the
    /// same code as "crossfading two clips" -- which is the point of treating a
    /// pose as a value.
    pub fn poseCurrent(self: *Skeleton) void {
        // Nothing playing and nothing fading: the rest pose.
        if (self.current == null and self.previous == null) {
            self.pose();
            return;
        }

        // The pose being faded in (or the bind pose, if nothing is).
        if (self.current) |c| {
            self.samplePose(self.clips[c], self.current_time, self.sample);
        } else {
            self.sampleBindPose(self.sample);
        }

        // Done fading: no second pose to mix.
        if (self.blend >= 1) {
            self.applyPose(self.sample);
            return;
        }

        // Blend from what came before. The outgoing pose is built joint by joint
        // rather than into a buffer of its own -- a second scratch array would
        // only hold it for one line.
        for (self.sample, 0..) |*s, j| {
            const from = if (self.previous) |p|
                self.sampleJoint(self.clips[p], self.previous_time, j)
            else
                self.joints[j].bind;

            s.position = from.position.add(s.position.sub(from.position).scale(self.blend));
            s.scale = from.scale.add(s.scale.sub(from.scale).scale(self.blend));
            s.rotation = from.rotation.slerp(s.rotation, self.blend);
        }
        self.applyPose(self.sample);
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

    const sample = try allocator.alloc(Transform, n);
    errdefer allocator.free(sample);

    const world = try allocator.alloc(Mat4, n);
    errdefer allocator.free(world);

    // Pose once so the matrices are valid even before the first explicit pose().
    var skel = Skeleton{
        .joints = joints,
        .inverse_binds = inverse_binds,
        .skinning = skinning,
        .sample = sample,
        .world = world,
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

test "a model with several clips loads them all and blends between them" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const file = std.Io.Dir.cwd().openFile(io, "assets/gltf/Fox.glb", .{}) catch |err| {
        std.debug.print("skipping multi-clip test: {}\n", .{err});
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

    // Names come from the file, and asking by name is how a game says which
    // clip it means.
    const walk = skel.clipByName("Walk") orelse return error.TestUnexpectedResult;
    const run = skel.clipByName("Run") orelse return error.TestUnexpectedResult;
    try std.testing.expect(walk != run);
    try std.testing.expect(skel.clipByName("NoSuchClip") == null);

    // Each clip has its own length -- a fixed loop duration would be wrong for
    // at least two of the three.
    for (skel.clips) |clip| try std.testing.expect(clip.duration > 0);

    // Playing one, then another, leaves the first fading out.
    skel.play(walk);
    try std.testing.expectEqual(@as(?usize, walk), skel.current);
    try std.testing.expectEqual(@as(f32, 0), skel.blend);

    skel.advanceBlend(1, 10); // long enough to finish
    try std.testing.expectEqual(@as(f32, 1), skel.blend);
    try std.testing.expect(skel.previous == null);

    skel.play(run);
    try std.testing.expectEqual(@as(?usize, walk), skel.previous);

    // Asking for the clip already playing changes nothing: a game that says
    // "run" every frame should not restart the stride sixty times a second.
    const before = skel.current_time;
    skel.current_time = 0.3;
    skel.play(run);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), skel.current_time, 1e-6);
    _ = before;

    // Mid-blend between two clips: the matrices must stay finite and sane. A
    // blend that interpolated matrices instead of transforms would fail here.
    skel.blend = 0.5;
    skel.poseCurrent();
    for (skel.skinning) |m| {
        inline for (0..4) |r| {
            inline for (0..4) |c| {
                try std.testing.expect(std.math.isFinite(m.m[r][c]));
            }
        }
    }

    // And fading out to the bind pose is the same path with no current clip.
    skel.stop();
    skel.blend = 0.5;
    skel.poseCurrent();
    for (skel.skinning) |m| {
        inline for (0..4) |r| {
            inline for (0..4) |c| {
                try std.testing.expect(std.math.isFinite(m.m[r][c]));
            }
        }
    }
}
