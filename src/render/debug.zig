//! Debug drawing: an immediate-mode line renderer for shapes the game wants to
//! see but not ship -- hitboxes, hurtboxes, collision bounds. The way Unreal's
//! DrawDebug* and Unity's Gizmos work: the game asks for a shape, this turns it
//! into line segments, and the renderer draws them.
//!
//! What to show is a per-category toggle (Unreal's `show Collision`, `stat fps`),
//! so one kind can be on while another is off. Only collision is wired today;
//! the flags for stats and the like are where they will join.

const std = @import("std");
const math = @import("../math/math.zig");
const collision = @import("../collision/root.zig");
const LineVertex = @import("../gpu/root.zig").LineVertex;

const Vec3 = math.Vec3;

/// The debug-draw state: what is shown, and the lines built for this frame.
/// Held by the game, cleared and refilled each frame, handed to the renderer.
pub const Debug = struct {
    /// Whether collision volumes -- hit/hurt capsules, world bounds -- are drawn.
    /// Off by default; a game toggles it (a key, a console) when tuning.
    show_collision: bool = false,

    /// This frame's line vertices, two per segment. Cleared each frame.
    lines: std.ArrayList(LineVertex),

    pub fn init(allocator: std.mem.Allocator) Debug {
        return .{ .lines = std.ArrayList(LineVertex).init(allocator) };
    }

    pub fn deinit(self: *Debug) void {
        self.lines.deinit();
    }

    /// Drops the frame's lines. Called at the top of a frame, before anything is
    /// added, so each frame draws only what it asks for.
    pub fn clear(self: *Debug) void {
        self.lines.clearRetainingCapacity();
    }

    /// One segment, two coloured endpoints.
    pub fn line(self: *Debug, a: Vec3, b: Vec3, color: Vec3) !void {
        try self.lines.append(.{ .position = a.v, .color = color.v });
        try self.lines.append(.{ .position = b.v, .color = color.v });
    }

    /// A capsule as wireframe: rings at each end perpendicular to the axis, a few
    /// verticals joining them, and short spokes toward each cap's pole. Enough to
    /// read the shape and where it sits, not a full hemisphere tessellation.
    pub fn capsule(self: *Debug, cap: collision.Capsule, color: Vec3) !void {
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
            try self.line(ringPoint(a, u, v, cap.radius, a0), ringPoint(a, u, v, cap.radius, a1), color);
            try self.line(ringPoint(b, u, v, cap.radius, a0), ringPoint(b, u, v, cap.radius, a1), color);
        }

        // Four verticals joining the rings, and spokes to each pole.
        const cap_a = a.sub(axis_n.scale(cap.radius));
        const cap_b = b.add(axis_n.scale(cap.radius));
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            const ang = tau * @as(f32, @floatFromInt(k)) / 4.0;
            const pa = ringPoint(a, u, v, cap.radius, ang);
            const pb = ringPoint(b, u, v, cap.radius, ang);
            try self.line(pa, pb, color);
            try self.line(pa, cap_a, color);
            try self.line(pb, cap_b, color);
        }
    }

    /// An axis-aligned box as its twelve edges.
    pub fn aabb(self: *Debug, box: collision.Aabb, color: Vec3) !void {
        const lo = box.min;
        const hi = box.max;
        const xs = [2]f32{ lo.x(), hi.x() };
        const ys = [2]f32{ lo.y(), hi.y() };
        const zs = [2]f32{ lo.z(), hi.z() };
        // The 4 edges along each axis.
        for (ys) |yy| for (zs) |zz| try self.line(math.vec3(xs[0], yy, zz), math.vec3(xs[1], yy, zz), color);
        for (xs) |xx| for (zs) |zz| try self.line(math.vec3(xx, ys[0], zz), math.vec3(xx, ys[1], zz), color);
        for (xs) |xx| for (ys) |yy| try self.line(math.vec3(xx, yy, zs[0]), math.vec3(xx, yy, zs[1]), color);
    }
};

const tau = 2.0 * std.math.pi;

/// Two orthonormal vectors perpendicular to `axis`, for laying out a ring around
/// it. The reference is swapped near the poles so the cross product stays stable.
fn perpBasis(axis: Vec3) [2]Vec3 {
    const ref = if (@abs(axis.y()) < 0.9) math.vec3(0, 1, 0) else math.vec3(1, 0, 0);
    const u = axis.cross(ref).normalize();
    const v = axis.cross(u).normalize();
    return .{ u, v };
}
