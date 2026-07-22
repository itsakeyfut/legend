//! Collision queries for a kinematic character controller.
//!
//! The engine's part is only the geometry: it answers "does this capsule
//! overlap that box, and which way do I push it out", and slides a capsule
//! through a set of boxes. Gravity, jumping and velocity are dynamics -- state
//! the game owns and advances, the same way locomotion already lives in game
//! code (there is no Player type; see the skinned example).
//!
//! The character is a vertical capsule (the shape Unreal's UCapsuleComponent and
//! Unity's CharacterController both use). The world is a set of axis-aligned
//! boxes. Collisions are resolved discretely -- move, then push out of whatever
//! was entered (minimum translation vector) -- rather than by a continuous
//! sweep. At a fixed 60 Hz a character moving a few metres a second travels only
//! centimetres a step, far less than its own radius, so it cannot tunnel through
//! a wall between two steps; the sweep that guards against that is a later
//! addition, not a foundation.

const std = @import("std");
const math = @import("../math/math.zig");

const Vec3 = math.Vec3;

/// An axis-aligned bounding box, the world's collision primitive.
pub const Aabb = struct {
    min: Vec3,
    max: Vec3,

    /// A box of the given full size centred on a point
    pub fn fromCenterSize(center: Vec3, half: Vec3) Aabb {
        return .{ .min = center.sub(half), .max = center.add(half) };
    }
};

/// A push-out: unit direction to move along, and how far, to just separate
pub const Mtv = struct {
    normal: Vec3,
    depth: f32,
};

/// The result of sliding a capsule one move through the world.
pub const SlideResult = struct {
    pos: Vec3,
    /// A surface faced up enough to stand on was pushed against this move.
    grounded: bool,
    /// A near-vertical surface was pushed against -- a wall, not a floor.
    wall: bool,
};

/// The point of `box` closest to `p`: `p` with each axis clamped to the box.
pub fn closestPointOnAabb(p: Vec3, box: Aabb) Vec3 {
    return math.vec3(
        std.math.clamp(p.x(), box.min.x(), box.max.x()),
        std.math.clamp(p.y(), box.min.y(), box.max.y()),
        std.math.clamp(p.z(), box.min.z(), box.max.z()),
    );
}

/// Overlap between a vertical capsule and a box, or null if they are apart.
///
/// The capsule is the segment `a`..`b` (its two sphere centres) swept by
/// `radius`; `a` and `b` are expected to share x and z, with `a.y <= b.y`. The
/// segment and box are separable in each axis because the segment is vertical
/// and the box axis-aligned, so the closest point is found directly, without the
/// iteration a general segment-vs-box test would need. Generalising to a tilted
/// capsule -- ragdoll bones, later -- is a separate extension.
pub fn capsuleVsAabb(a: Vec3, b: Vec3, radius: f32, box: Aabb) ?Mtv {
    // Horizontal: the segment's x and z are constant, so the nearest box point
    // in those axes is just the clamp.
    const qx = std.math.clamp(a.x(), box.min.x(), box.max.x());
    const qz = std.math.clamp(a.z(), box.min.z(), box.max.z());

    // Vertical: nearest pair between the segment's y-span and the box's.
    const ay = a.y();
    const by = b.y();
    const miny = box.min.y();
    const maxy = box.max.y();
    var sy: f32 = undefined; // y on the segment
    var qy: f32 = undefined; // y on the box
    if (by < miny) {
        sy = by;
        qy = miny;
    } else if (ay > maxy) {
        sy = ay;
        qy = maxy;
    } else {
        // The spans overlap: pick a segment y inside the overlap, closest to the
        // box's middle, and the box meets it there.
        sy = std.math.clamp((miny + maxy) * 0.5, ay, by);
        qy = std.math.clamp(sy, miny, maxy);
    }

    const s = math.vec3(a.x(), sy, a.z()); // closest point on the segment
    const q = math.vec3(qx, qy, qz); // closest point on the box
    const away = s.sub(q); // box -> segment
    const dist = away.length();

    if (dist >= radius) return null;

    if (dist > 1e-6) {
        // The axis is outside the box: push straight out along the gap.
        return .{ .normal = away.scale(1.0 / dist), .depth = radius - dist };
    }

    // The axis runs through the box (the character is inside it). Leave along
    // the nearest face -- the least push that frees it -- plus the radius so the
    // capsule's side clears too.
    const to_lo = s.sub(box.min); // distance out through each min face
    const to_hi = box.max.sub(s); // distance out through each max face
    var normal = math.vec3(0, 1, 0);
    var pen = to_hi.y(); // default: push up
    inline for (.{
        .{ to_lo.x(), math.vec3(-1, 0, 0) },
        .{ to_hi.x(), math.vec3(1, 0, 0) },
        .{ to_lo.y(), math.vec3(0, -1, 0) },
        .{ to_hi.y(), math.vec3(0, 1, 0) },
        .{ to_lo.z(), math.vec3(0, 0, -1) },
        .{ to_hi.z(), math.vec3(0, 0, 1) },
    }) |face| {
        if (face[0] < pen) {
            pen = face[0];
            normal = face[1];
        }
    }
    return .{ .normal = normal, .depth = pen + radius };
}

/// Move a vertical capsule (feet at `pos`, of `radius` and total `height`) by
/// `delta`, then push it out of every box it entered, sliding along the
/// surfaces. A few passes settle corners where two boxes meet.
///
/// Sliding is not special-cases: pushing out along a surface's normal removes
/// only the motion into it and leaves the motion along it, which is a slide.
pub fn moveAndSlide(
    pos: Vec3,
    radius: f32,
    height: f32,
    delta: Vec3,
    world: []const Aabb,
) SlideResult {
    var p = pos.add(delta);
    var grounded = false;
    var wall = false;

    var pass: usize = 0;
    while (pass < 4) : (pass += 1) {
        // The capsule's sphere centres, recomputed as the position shifts. The
        // clamp keeps the segment valid if height is ever less than 2*radius.
        const a = p.add(math.vec3(0, radius, 0));
        const b = p.add(math.vec3(0, @max(radius, height - radius), 0));

        var pushed = false;
        for (world) |box| {
            if (capsuleVsAabb(a, b, radius, box)) |mtv| {
                p = p.add(mtv.normal.scale(mtv.depth));
                pushed = true;
                if (mtv.normal.y() > 0.7) {
                    grounded = true;
                } else {
                    wall = true;
                }
            }
        }
        if (!pushed) break;
    }

    return .{ .pos = p, .grounded = grounded, .wall = wall };
}

test "closestPointOnAabb clamps outside points and keeps inside ones" {
    const box = Aabb{ .min = math.vec3(-1, -1, -1), .max = math.vec3(1, 1, 1) };

    const outside = closestPointOnAabb(math.vec3(2, 0, 0), box);
    try std.testing.expectApproxEqAbs(@as(f32, 1), outside.x(), 1e-6);

    const inside = closestPointOnAabb(math.vec3(0.5, 0, 0), box);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), inside.x(), 1e-6);
}

test "capsuleVsAabb reports no overlap when the capsule clears the box" {
    // Floor with its top at y = 0.
    const floor = Aabb{ .min = math.vec3(-5, -1, -5), .max = math.vec3(5, 0, 5) };
    // Feet at 0.05: the lower sphere centre sits at 0.35, above the top by more
    // than the radius.
    const a = math.vec3(0, 0.35, 0);
    const b = math.vec3(0, 1.35, 0);
    try std.testing.expect(capsuleVsAabb(a, b, 0.3, floor) == null);
}

test "capsuleVsAabb pushes up out of a floor" {
    const floor = Aabb{ .min = math.vec3(-5, -1, -5), .max = math.vec3(5, 0, 5) };
    // Feet at -0.1: lower sphere centre at 0.2, within a radius of the top.
    const a = math.vec3(0, 0.2, 0);
    const b = math.vec3(0, 1.2, 0);
    const mtv = capsuleVsAabb(a, b, 0.3, floor).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), mtv.normal.y(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), mtv.depth, 1e-6);
}

test "moveAndSlide lands a falling capsule on the floor" {
    const world = [_]Aabb{
        .{ .min = math.vec3(-5, -1, -5), .max = math.vec3(5, 0, 5) },
    };
    // Start above the floor and fall a metre.
    const r = moveAndSlide(math.vec3(0, 0.5, 0), 0.3, 1.7, math.vec3(0, -1, 0), &world);
    try std.testing.expect(r.grounded);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.pos.y(), 1e-5);
}

test "moveAndSlide stops at a wall and keeps motion along it" {
    const world = [_]Aabb{
        // A wall whose near face is at x = 1.
        .{ .min = math.vec3(1, -1, -5), .max = math.vec3(1.5, 2, 5) },
    };
    // Walk diagonally into the wall: +x is blocked, +z should survive.
    const r = moveAndSlide(math.vec3(0.9, 0, 0), 0.3, 1.7, math.vec3(0.3, 0, 0.3), &world);
    try std.testing.expect(r.wall);
    // Feet stop a radius short of the face.
    try std.testing.expect(r.pos.x() <= 0.71);
    // The move along the wall was kept.
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), r.pos.z(), 1e-5);
}
