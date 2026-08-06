//! Debug drawing: an immediate-mode line renderer for shapes the game wants to
//! see but not ship -- hitboxes, hurtboxes, collision bounds. The way Unreal's
//! DrawDebug* and Unity's Gizmos work: the game asks for a shape, this turns it
//! into line segments, and the renderer draws them.
//!
//! What to show is a per-category toggle (Unreal's `show Collision`, `stat fps`),
//! so one kind can be on while another is off. Only collision is wired today;
//! the flags for stats and the like are where they will join.
//!
//! The frame's lines go into a buffer the caller owns and reuses -- the same
//! fixed-buffer, no-per-frame-allocation shape the draw list (`buildDrawList`)
//! uses. No `std.ArrayList`: its API has churned across Zig versions and an
//! overlay does not need a growable container it would have to track. Segments
//! past the buffer's end are dropped, which is the right failure for debug draw
//! -- best-effort by nature, and the cap (`gpu.max_line_vertices`) is generous.
//!
//! This is the debug-draw state: what is shown, and the lines built for this
//! frame. Held by the game, cleared and refilled each frame, handed to the
//! renderer.

const std = @import("std");
const math = @import("../math/math.zig");
const collision = @import("../collision/root.zig");
const LineVertex = @import("../gpu/root.zig").LineVertex;

const Vec3 = math.Vec3;

const Self = @This();

/// Whether collision volumes -- hit/hurt capsules, world bounds -- are drawn.
/// Off by default; a game toggles it (a key, a console) when tuning.
show_collision: bool = false,
/// Whether the debug stats overlay (FPS, position, clip, etc.) is drawn.
/// On by default -- useful while developing; a game hides it for a clean
/// screen or replaces it with its own HUD.
show_stats: bool = true,

/// The caller-owned buffer this frame's line vertices are written into, two
/// per segment. Borrowed, never freed here; size it to `gpu.max_line_vertices`
/// so the GPU-side buffer can take everything this fills.
buf: []LineVertex,
/// How much of `buf` this frame has used.
count: usize = 0,

pub fn init(buffer: []LineVertex) Self {
    return .{ .buf = buffer };
}

/// Drops the frame's lines. Called at the top of a frame, before anything is
/// added, so each frame draws only what it asks for.
pub fn clear(self: *Self) void {
    self.count = 0;
}

/// The lines built this frame, to hand to the renderer's draw call.
pub fn lines(self: *const Self) []const LineVertex {
    return self.buf[0..self.count];
}

/// One segment, two coloured endpoints. Silently dropped once the buffer is
/// full -- a missing debug line is a non-event, so this never errors and
/// callers never have to handle a failure.
pub fn line(self: *Self, a: Vec3, b: Vec3, color: Vec3) void {
    if (self.count + 2 > self.buf.len) return;
    self.buf[self.count] = .{ .position = a.v, .color = color.v };
    self.buf[self.count + 1] = .{ .position = b.v, .color = color.v };
    self.count += 2;
}

/// A capsule as wireframe: rings at each end perpendicular to the axis, a few
/// verticals joining them, and short spokes toward each cap's pole. Enough to
/// read the shape and where it sits, not a full hemisphere tessellation.
pub fn capsule(self: *Self, cap: collision.Capsule, color: Vec3) void {
    const segments = 12;
    const a = cap.a;
    const b = cap.b;

    const axis = b.sub(a);
    const axis_len = axis.length();
    const axis_n = if (axis_len > 1e-6) axis.scale(1.0 / axis_len) else math.vec3(0, 1, 0);
    const basis = perpBasis(axis_n);
    const u = basis[0];
    const v = basis[1];

    // A point on the ring at `center`, at angle `ang`.
    const ringPoint = struct {
        fn at(center: Vec3, uu: Vec3, vv: Vec3, r: f32, ang: f32) Vec3 {
            return center.add(uu.scale(r * @cos(ang))).add(vv.scale(r * @sin(ang)));
        }
    }.at;

    // The two end rings.
    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const a0 = tau * @as(f32, @floatFromInt(i)) / segments;
        const a1 = tau * @as(f32, @floatFromInt(i + 1)) / segments;
        self.line(ringPoint(a, u, v, cap.radius, a0), ringPoint(a, u, v, cap.radius, a1), color);
        self.line(ringPoint(b, u, v, cap.radius, a0), ringPoint(b, u, v, cap.radius, a1), color);
    }

    // Four verticals joining the rings, and spokes to each pole.
    const cap_a = a.sub(axis_n.scale(cap.radius));
    const cap_b = b.add(axis_n.scale(cap.radius));
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        const ang = tau * @as(f32, @floatFromInt(k)) / 4.0;
        const pa = ringPoint(a, u, v, cap.radius, ang);
        const pb = ringPoint(b, u, v, cap.radius, ang);
        self.line(pa, pb, color);
        self.line(pa, cap_a, color);
        self.line(pb, cap_b, color);
    }
}

/// An arrow from `from` to `to`: the shaft, plus a four-pronged head at the
/// tip. For directions and magnitudes -- a velocity, a facing, a normal --
/// where a bare line would not show which end is which.
pub fn arrow(self: *Self, from: Vec3, to: Vec3, color: Vec3) void {
    self.line(from, to, color);

    const axis = to.sub(from);
    const axis_len = axis.length();
    if (axis_len < 1e-6) return;
    const axis_n = axis.scale(1.0 / axis_len);
    const basis = perpBasis(axis_n);

    // The head: from the tip, back along the axis a fraction of the length.
    // splayed out to four corners.
    const head_len = axis_len * 0.2;
    const head_width = head_len * 0.5;
    const base = to.sub(axis_n.scale(head_len));
    const dirs = [_]Vec3{ basis[0], basis[1], basis[0].scale(-1), basis[1].scale(-1) };
    for (dirs) |d| {
        self.line(to, base.add(d.scale(head_width)), color);
    }
}

/// A sphere as three rings, one in each axis plane. For a point or a radius
/// -- a target, a range -- where a capsule with equal ends would do but a
/// clean three-ring sphere reads better.
pub fn sphere(self: *Self, center: Vec3, radius: f32, color: Vec3) void {
    const segments = 12;
    const planes = [_][2]Vec3{
        .{ math.vec3(1, 0, 0), math.vec3(0, 1, 0) }, // xy
        .{ math.vec3(0, 1, 0), math.vec3(0, 0, 1) }, // yz
        .{ math.vec3(1, 0, 1), math.vec3(1, 0, 0) }, // zx
    };
    for (planes) |p| {
        var i: usize = 0;
        while (i < segments) : (i += 1) {
            const a0 = tau * @as(f32, @floatFromInt(i)) / segments;
            const a1 = tau * @as(f32, @floatFromInt(i + 1)) / segments;
            const pt0 = center.add(p[0].scale(radius * @cos(a0))).add(p[1].scale(radius * @sin(a0)));
            const pt1 = center.add(p[0].scale(radius * @cos(a1))).add(p[1].scale(radius * @sin(a1)));
            self.line(pt0, pt1, color);
        }
    }
}

/// An axis-aligned box as its twelve edges.
pub fn aabb(self: *Self, box: collision.Aabb, color: Vec3) void {
    const lo = box.min;
    const hi = box.max;
    const xs = [2]f32{ lo.x(), hi.x() };
    const ys = [2]f32{ lo.y(), hi.y() };
    const zs = [2]f32{ lo.z(), hi.z() };
    // The 4 edges along each axis.
    for (ys) |yy| for (zs) |zz| self.line(math.vec3(xs[0], yy, zz), math.vec3(xs[1], yy, zz), color);
    for (xs) |xx| for (zs) |zz| self.line(math.vec3(xx, ys[0], zz), math.vec3(xx, ys[1], zz), color);
    for (xs) |xx| for (ys) |yy| self.line(math.vec3(xx, yy, zs[0]), math.vec3(xx, yy, zs[1]), color);
}

const tau = 2.0 * std.math.pi;

/// Two orthonormal vectors perpendicular to `axis`, for laying out a ring around
/// it. The reference is swapped near the poles so the cross product stays stable.
fn perpBasis(axis: Vec3) [2]Vec3 {
    const ref = if (@abs(axis.y()) < 0.9) math.vec3(0, 1, 0) else math.vec3(1, 0, 0);
    const u = axis.cross(ref).normalize();
    const v = axis.cross(u).normalize();
    return .{ u, v };
}

test "lines accumulate and clear; overflow drops" {
    var buf: [8]LineVertex = undefined;
    var dbg = Self.init(&buf);

    dbg.line(math.vec3(0, 0, 0), math.vec3(1, 0, 0), math.vec3(1, 1, 1));
    try std.testing.expectEqual(@as(usize, 2), dbg.lines().len);

    // Fills to the cap, then drops the rest rather than overrunning the buffer.
    dbg.line(math.vec3(0, 0, 0), math.vec3(0, 1, 0), math.vec3(1, 1, 1));
    dbg.line(math.vec3(0, 0, 0), math.vec3(0, 0, 1), math.vec3(1, 1, 1));
    dbg.line(math.vec3(0, 0, 0), math.vec3(0, 0, 1), math.vec3(1, 1, 1)); // dropped: no room
    try std.testing.expectEqual(@as(usize, 8), dbg.lines().len);

    dbg.clear();
    try std.testing.expectEqual(@as(usize, 0), dbg.lines().len);
}
