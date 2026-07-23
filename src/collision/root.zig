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
//! sweep. A step of movement is small next to the thickness of the things being
//! collided with, so nothing is passed through between two steps; the sweep that
//! guards against that for thin or fast-moving geometry is a later addition, not
//! a foundation.

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

/// The shape a character collides as, and the limits that decide what it may
/// walk on. Parameters only: where the character is and how fast it moves is
/// game state, not something the engine holds.
pub const Controller = struct {
    /// Capsule radius.
    radius: f32 = 0.3,

    /// Capsule height, feet to head.
    height: f32 = 1.7,

    /// The tallest ledge the character walks up rather than being stopped by
    /// (Unreal's MaxStepHeight, Unity's stepOffset). Zero disables stepping.
    ///
    /// A capsule needs less help than a box here: its rounded base meets a low
    /// ledge at the ledge's top edge, and the push-out is angled enough to
    /// carry it over unaided. That help fades as the ledge approaches the
    /// radius -- the contact turns level and the character simply stops -- and
    /// this is what covers everything from there up.
    step_height: f32 = 0.4,

    /// The steepest floor still counted as ground, in radians from horizontal
    /// (Unreal's walkable floor angle, Unity's slopeLimit). Steeper contacts are
    /// walls: the character is not standing, so gravity keeps pulling and it
    /// slides back down.
    max_slope: f32 = 50.0 * std.math.pi / 180.0,
};

/// The result of moving a capsule once through the world.
pub const SlideResult = struct {
    pos: Vec3,
    /// A surface faced up enough to stand on was pushed against this move.
    grounded: bool,
    /// A surface too steep to stand on was pushed against -- a wall.
    wall: bool,
    /// How much of the rise this move came from stepping up onto a ledge.
    ///
    /// A step-up is a discontinuity: the capsule is lifted the whole height of
    /// the ledge in a single step, far more than it would ever move walking.
    /// The capsule has to move -- it is what the character stands on -- but the
    /// game may want to let what it draws lag behind and catch up, so the
    /// amount is reported rather than hidden.
    stepped: f32 = 0,
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

/// Push a capsule out of every box it overlaps at `start`, sliding along the
/// surfaces. A few passes settle corners where two boxes meet.
///
/// Sliding is not special-cased: pushing out along a surface's normal removes
/// only the motion into it and leaves the motion along it, which is a slide.
fn resolve(ctrl: Controller, start: Vec3, min_ground_y: f32, world: []const Aabb) SlideResult {
    var p = start;
    var grounded = false;
    var wall = false;

    var pass: usize = 0;
    while (pass < 4) : (pass += 1) {
        // The capsule's sphere centres, recomputed as the position shifts. The
        // clamp keeps the segment valid if height is ever less than 2*radius.
        const a = p.add(math.vec3(0, ctrl.radius, 0));
        const b = p.add(math.vec3(0, @max(ctrl.radius, ctrl.height - ctrl.radius), 0));

        var pushed = false;
        for (world) |box| {
            if (capsuleVsAabb(a, b, ctrl.radius, box)) |mtv| {
                p = p.add(mtv.normal.scale(mtv.depth));
                pushed = true;
                if (mtv.normal.y() >= min_ground_y) grounded = true else wall = true;
            }
        }
        if (!pushed) break;
    }

    return .{ .pos = p, .grounded = grounded, .wall = wall };
}

/// Where a capsule dropping straight down first meets a box.
const Landing = struct {
    /// How far it falls before touching.
    drop: f32,
    /// The height of the surface it comes to rest on.
    surface_top: f32,
};

/// How far a vertical capsule with its lower sphere centred at `a` can descend
/// before it touches `box`, or null if it never does.
///
/// Only the vertical axis moves, so this needs no iteration: at horizontal
/// distance `d` from the box the capsule's underside hangs sqrt(r^2 - d^2)
/// below that sphere centre, and it comes to rest where that underside meets the
/// box's top. Directly above the box this is the full radius; off to one side it
/// is less, which is what lands the capsule on a ledge's edge rather than
/// through it.
fn descentOnto(a: Vec3, radius: f32, box: Aabb) ?Landing {
    const dx = @max(@max(box.min.x() - a.x(), 0.0), a.x() - box.max.x());
    const dz = @max(@max(box.min.z() - a.z(), 0.0), a.z() - box.max.z());
    const d = @sqrt(dx * dx + dz * dz);
    if (d >= radius) return null;

    const dip = @sqrt(radius * radius - d * d);
    const drop = a.y() - (box.max.y() + dip);
    if (drop < 0) return null; // already level with it or below

    return .{ .drop = drop, .surface_top = box.max.y() };
}

/// Move a capsule (feet at `pos`) by `delta` through the world, sliding along
/// what it hits and stepping up onto ledges within the controller's reach.
///
/// `grounded` is whether the character was standing before the move: stepping up
/// is something a walking character does, not a falling one, so a jump into a
/// ledge is stopped by it rather than boosted onto it.
pub fn moveAndSlide(
    ctrl: Controller,
    pos: Vec3,
    delta: Vec3,
    grounded: bool,
    world: []const Aabb,
) SlideResult {
    const min_ground_y = @cos(ctrl.max_slope);

    const direct = resolve(ctrl, pos.add(delta), min_ground_y, world);

    // Only a walking character stopped by a wall has anything to step onto.
    if (ctrl.step_height <= 0 or !direct.wall or !grounded) return direct;

    const horizontal = math.vec3(delta.x(), 0, delta.z());
    const distance = horizontal.length();
    if (distance < 1e-6) return direct;
    const forward = horizontal.scale(1.0 / distance);

    // Up, across, down: lift clear of the ledge, carry the move over it, and
    // settle onto whatever is underneath.
    const up = resolve(ctrl, pos.add(math.vec3(0, ctrl.step_height, 0)), min_ground_y, world);
    const over = resolve(ctrl, up.pos.add(horizontal), min_ground_y, world);

    // Worth having only if the raised route got further along the move than
    // being stopped did. A wall too tall to clear blocks both, and fails here.
    const gained_direct = direct.pos.sub(pos).dot(forward);
    const gained_step = over.pos.sub(pos).dot(forward);
    if (gained_step <= gained_direct + 1e-4) return direct;

    // Come back down. Descending is a closed form, so the landing is exact
    // rather than a position dropped through the floor and pushed back out.
    const axis = over.pos.add(math.vec3(0, ctrl.radius, 0));
    var landing: ?Landing = null;
    for (world) |box| {
        if (descentOnto(axis, ctrl.radius, box)) |candidate| {
            if (landing == null or candidate.drop < landing.?.drop) landing = candidate;
        }
    }
    const found = landing orelse return direct; // stepped out over nothing

    // The surface has to be within one step of where the feet started. This is
    // what step_height means, and the whole of what separates a ledge from a
    // wall: without this the character would climb any height at all, a little
    // each move.
    if (found.surface_top > pos.y() + ctrl.step_height + 1e-4) return direct;

    const landed = over.pos.sub(math.vec3(0, found.drop, 0));
    if (landed.y() < pos.y() - 1e-4) return direct; // a drop, not a step

    const settled = resolve(ctrl, landed, min_ground_y, world);
    // A ledge shallow enough to step onto is ground, including where the capsule
    // comes to rest against its edge rather than squarely on its top.
    return .{
        .pos = settled.pos,
        .grounded = true,
        .wall = direct.wall,
        .stepped = settled.pos.y() - pos.y(),
    };
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
    const ctrl = Controller{};
    const world = [_]Aabb{
        .{ .min = math.vec3(-5, -1, -5), .max = math.vec3(5, 0, 5) },
    };
    // Start above the floor and fall a metre.
    const r = moveAndSlide(ctrl, math.vec3(0, 0.5, 0), math.vec3(0, -1, 0), false, &world);
    try std.testing.expect(r.grounded);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.pos.y(), 1e-5);
}

test "moveAndSlide stops at a wall and keeps motion along it" {
    const ctrl = Controller{};
    const world = [_]Aabb{
        // A wall whose near face is at x = 1, far too tall to step onto.
        .{ .min = math.vec3(1, -1, -5), .max = math.vec3(1.5, 2, 5) },
    };
    // Walk diagonally into the wall: +x is blocked, +z should survive.
    const r = moveAndSlide(ctrl, math.vec3(0.9, 0, 0), math.vec3(0.3, 0, 0.3), true, &world);
    try std.testing.expect(r.wall);
    // Feet stop a radius short of the face.
    try std.testing.expect(r.pos.x() <= 0.71);
    // The move along the wall was kept.
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), r.pos.z(), 1e-5);
}

test "moveAndSlide steps up onto a ledge within reach" {
    const ctrl = Controller{}; // step_height 0.4
    const world = [_]Aabb{
        .{ .min = math.vec3(-5, -1, -5), .max = math.vec3(5, 0, 5) }, // floor
        .{ .min = math.vec3(1, 0, -5), .max = math.vec3(3, 0.35, 5) }, // ledge
    };

    // Walk into it. A ledge is climbed over several moves, riding up its edge,
    // so one call is not enough to prove it.
    var pos = math.vec3(0, 0, 0);
    var grounded = false;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const r = moveAndSlide(ctrl, pos, math.vec3(0.05, -0.01, 0), grounded, &world);
        pos = r.pos;
        grounded = r.grounded;
    }

    try std.testing.expect(grounded);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), pos.y(), 1e-3);
    try std.testing.expect(pos.x() > 1);
}

test "moveAndSlide refuses a ledge taller than step_height" {
    const ctrl = Controller{}; // step_height 0.4
    const world = [_]Aabb{
        .{ .min = math.vec3(-5, -1, -5), .max = math.vec3(5, 0, 5) },
        .{ .min = math.vec3(1, 0, -5), .max = math.vec3(3, 0.6, 5) }, // too tall
    };

    var pos = math.vec3(0, 0, 0);
    var grounded = false;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const r = moveAndSlide(ctrl, pos, math.vec3(0.05, -0.01, 0), grounded, &world);
        pos = r.pos;
        grounded = r.grounded;
    }

    // Still on the floor, stopped a radius short of the face.
    try std.testing.expectApproxEqAbs(@as(f32, 0), pos.y(), 1e-3);
    try std.testing.expect(pos.x() <= 0.71);
}

test "max_slope decides whether a steep contact is ground" {
    // Resting against a box's top edge gives a contact 45 degrees from level.
    const world = [_]Aabb{
        .{ .min = math.vec3(-1, -1, -1), .max = math.vec3(0, 0, 1) },
    };
    const pos = math.vec3(0.15, -0.15, 0);
    const still = math.vec3(0, 0, 0);

    const lenient = moveAndSlide(Controller{ .max_slope = 50.0 * std.math.pi / 180.0 }, pos, still, true, &world);
    try std.testing.expect(lenient.grounded);

    const strict = moveAndSlide(Controller{ .max_slope = 40.0 * std.math.pi / 180.0 }, pos, still, true, &world);
    try std.testing.expect(!strict.grounded);
    try std.testing.expect(strict.wall);
}

test "stepping up is reported, and refused ledges report nothing" {
    const ctrl = Controller{};
    const climbable = [_]Aabb{
        .{ .min = math.vec3(-5, -1, -5), .max = math.vec3(5, 0, 5) },
        .{ .min = math.vec3(1, 0, -5), .max = math.vec3(3, 0.35, 5) },
    };
    const too_tall = [_]Aabb{
        .{ .min = math.vec3(-5, -1, -5), .max = math.vec3(5, 0, 5) },
        .{ .min = math.vec3(1, 0, -5), .max = math.vec3(3, 0.6, 5) },
    };

    var climbed: f32 = 0;
    var blocked: f32 = 0;
    var a_pos = math.vec3(0, 0, 0);
    var b_pos = math.vec3(0, 0, 0);
    var a_ground = false;
    var b_ground = false;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const a = moveAndSlide(ctrl, a_pos, math.vec3(0.05, -0.01, 0), a_ground, &climbable);
        a_pos = a.pos;
        a_ground = a.grounded;
        climbed += a.stepped;

        const b = moveAndSlide(ctrl, b_pos, math.vec3(0.05, -0.01, 0), b_ground, &too_tall);
        b_pos = b.pos;
        b_ground = b.grounded;
        blocked += b.stepped;
    }

    try std.testing.expect(climbed > 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), blocked, 1e-6);
}
