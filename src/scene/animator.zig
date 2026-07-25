//! Per-character animation playback.
//!
//! A Skeleton is shared: the joints, their inverse binds, and the clips a model
//! was authored with are the same for every character using that rig. What is
//! not shared is where each character has got to -- which clip, how far into it,
//! how far through a transition -- and the matrix palette that evaluates to. Two
//! foxes walk the same rig at different moments in the stride, so that state
//! lives here, one Animator per character.
//!
//! Unreal splits along the same line (a USkeleton asset, a UAnimInstance per
//! component) and so does Unity (a shared rig, an Animator per object).
//!
//! An Animator never writes to the rig. The pose it samples is already the set
//! of local transforms, so the hierarchy can be walked straight from it, which
//! is what lets one rig serve any number of characters at once.

const std = @import("std");
const math = @import("../math/math.zig");
const gltf = @import("../render/gltf.zig");

const Transform = @import("../render/mesh.zig").Transform;
const Skeleton = @import("skeleton.zig").Skeleton;
const Mat4 = math.Mat4;

pub const Animator = struct {
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

    /// This character's skinning matrices, as of the last evaluate(). One per
    /// joint; this is what the GPU reads, and every character needs its own.
    skinning: []Mat4,

    /// Scratch, owned so that evaluating allocates nothing in a frame. `sample`
    /// holds the pose being evaluated or blended, `world` the world matrices the
    /// hierarchy walk accumulates.
    sample: []Transform,
    world: []Mat4,

    /// How many clips the rig has, kept so play() can reject an index without
    /// being handed the rig. Not a pointer to it: the rig lives in a slot map
    /// that may move its contents, and an Animator outlives any such move.
    clip_count: usize,

    allocator: std.mem.Allocator,

    /// Sized to `rig`. The animator must only ever be evaluated against the rig
    /// it was made for -- the arrays are exactly as long as that rig's joints.
    pub fn init(allocator: std.mem.Allocator, rig: *const Skeleton) !Animator {
        const n = rig.joints.len;

        const skinning = try allocator.alloc(Mat4, n);
        errdefer allocator.free(skinning);
        const sample = try allocator.alloc(Transform, n);
        errdefer allocator.free(sample);
        const world = try allocator.alloc(Mat4, n);
        errdefer allocator.free(world);

        var self = Animator{
            .skinning = skinning,
            .sample = sample,
            .world = world,
            .clip_count = rig.clips.len,
            .allocator = allocator,
        };
        // Evaluate once, so the matrices are valid before the first frame.
        self.evaluate(rig);
        return self;
    }

    pub fn deinit(self: *Animator) void {
        self.allocator.free(self.skinning);
        self.allocator.free(self.sample);
        self.allocator.free(self.world);
        self.* = undefined;
    }

    /// Switches to clip `index`, fading from whatever was playing.
    ///
    /// Starting the same clip again is ignored: a game asking every frame for
    /// "walk" should not restart the stride sixty times a second. That check is
    /// here rather than at the call site because forgetting it is silent -- the
    /// legs simply never move.
    pub fn play(self: *Animator, index: usize) void {
        if (index >= self.clip_count) return;
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
    pub fn stop(self: *Animator) void {
        if (self.current == null) return;
        self.previous = self.current;
        self.previous_time = self.current_time;
        self.current = null;
        self.current_time = 0;
        self.blend = 0;
    }

    /// Advances the transition; when it reaches 1 the previous clip is dropped.
    pub fn advanceBlend(self: *Animator, dt: f32, rate: f32) void {
        if (self.blend >= 1) return;
        self.blend += rate * dt;
        if (self.blend >= 1) {
            self.blend = 1;
            self.previous = null;
        }
    }

    /// Recomputes this character's skinning matrices for its playback state.
    ///
    /// Three cases, and the general one covers the other two: sample whichever
    /// clips are involved and blend them by `blend`. A missing clip stands for
    /// the bind pose, so "fading in from rest" and "fading out to rest" are the
    /// same code as "crossfading two clips" -- which is the point of treating a
    /// pose as a value.
    pub fn evaluate(self: *Animator, rig: *const Skeleton) void {
        if (self.current) |c| {
            rig.samplePose(rig.clips[c], self.current_time, self.sample);
        } else {
            rig.sampleBindPose(self.sample);
        }

        // Mid-transition: mix in what came before. The outgoing pose is built
        // joint by joint rather than into a buffer of its own -- a second
        // scratch array would only hold it for one line.
        if (self.blend < 1) {
            for (self.sample, 0..) |*s, j| {
                const from = if (self.previous) |p|
                    rig.sampleJoint(rig.clips[p], self.previous_time, j)
                else
                    rig.joints[j].bind;

                s.position = from.position.add(s.position.sub(from.position).scale(self.blend));
                s.scale = from.scale.add(s.scale.sub(from.scale).scale(self.blend));
                s.rotation = from.rotation.slerp(s.rotation, self.blend);
            }
        }

        // The sampled pose *is* the local transforms, so the hierarchy walks
        // straight from it -- nothing is written back to the rig, which is what
        // lets one rig serve several characters at once. Joints are stored
        // parents-first, so a single forward pass can read its parent's
        // already-computed world matrix.
        for (rig.joints, 0..) |joint, j| {
            const local = self.sample[j].matrix();
            self.world[j] = if (joint.parent) |p| self.world[p].mul(local) else local;
        }

        for (0..rig.joints.len) |j| {
            self.skinning[j] = self.world[j].mul(rig.inverse_binds[j]);
        }
    }
};

test "two animators on one rig stay independent" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const file = std.Io.Dir.cwd().openFile(io, "assets/gltf/Fox.glb", .{}) catch |err| {
        std.debug.print("skipping animator test: {}\n", .{err});
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

    const skeleton_mod = @import("skeleton.zig");
    var rig = try skeleton_mod.build(a, skin, gscene);
    defer rig.deinit();

    const count = try gltf.animationCount(a, glb);
    const clips = try a.alloc(gltf.Animation, count);
    for (0..count) |i| clips[i] = try gltf.parseAnimation(a, glb, i);
    rig.clips = clips; // the rig owns them from here

    // One rig, two characters.
    var first = try Animator.init(a, &rig);
    defer first.deinit();
    var second = try Animator.init(a, &rig);
    defer second.deinit();

    const walk = rig.clipByName("Walk") orelse return error.TestUnexpectedResult;
    const run = rig.clipByName("Run") orelse return error.TestUnexpectedResult;

    // Playing on one must not touch the other. Sharing the rig is the whole
    // point; sharing the playback state would make every character move alike.
    first.play(walk);
    try std.testing.expectEqual(@as(?usize, walk), first.current);
    try std.testing.expect(second.current == null);

    second.play(run);
    try std.testing.expectEqual(@as(?usize, walk), first.current);
    try std.testing.expectEqual(@as(?usize, run), second.current);

    // Same clip, different moments in it: the palettes must differ, or the two
    // characters would be drawn in lockstep.
    second.play(walk);
    first.blend = 1;
    second.blend = 1;
    second.previous = null;
    first.current_time = 0;
    second.current_time = rig.clips[walk].duration * 0.5;
    first.evaluate(&rig);
    second.evaluate(&rig);

    var differs = false;
    for (first.skinning, second.skinning) |x, y| {
        inline for (0..4) |r| {
            inline for (0..4) |cc| {
                try std.testing.expect(std.math.isFinite(x.m[r][cc]));
                if (@abs(x.m[r][cc] - y.m[r][cc]) > 1e-4) differs = true;
            }
        }
    }
    try std.testing.expect(differs);
}

test "evaluate at bind pose yields near-identity skinning" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const file = std.Io.Dir.cwd().openFile(io, "assets/gltf/CesiumMan.glb", .{}) catch |err| {
        std.debug.print("skipping bind-pose test: {}\n", .{err});
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

    const skeleton_mod = @import("skeleton.zig");
    var rig = try skeleton_mod.build(a, skin, gscene);
    defer rig.deinit();

    // init evaluates with nothing playing, so the animator holds the bind pose.
    // world(j) * inverseBind(j) is then identity for every joint, because the
    // joint's world transform *is* the bind pose the inverse bind was made from.
    // This is the skinning maths that used to be checked on the skeleton; it
    // lives on the animator now, so the check moved with it.
    var anim = try Animator.init(a, &rig);
    defer anim.deinit();

    for (anim.skinning) |m| {
        inline for (0..4) |r| {
            inline for (0..4) |cc| {
                const expected: f32 = if (r == cc) 1 else 0;
                try std.testing.expectApproxEqAbs(expected, m.m[r][cc], 1e-3);
            }
        }
    }
}
