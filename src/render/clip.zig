//! Near-plane clipping in homogeneous clip space (before the perspective divide).
//!
//! Without this, any triangle with a vertex behind the eye has to be dropped
//! whole, so geometry vanishes as the camera moves into it. Clipping splits
//! such triangles at the near plane instead, so only the part behind the eye
//! is discarded.

const math = @import("../math/math.zig");
const Vec2 = math.Vec2;
const Vec4 = math.Vec4;

/// A vertex in clip space: position is still homogeneous (no divide yet), so
/// attributes can be interpolated linearly here and stay perspective-correct.
pub const ClipVertex = struct {
    pos: Vec4,
    uv: Vec2,

    pub fn lerp(a: ClipVertex, b: ClipVertex, t: f32) ClipVertex {
        return .{
            .pos = a.pos.lerp(b.pos, t),
            .uv = a.uv.lerp(b.uv, t),
        };
    }
};

/// Signed distance to the near plane. The OpenGL-style clip volume has
/// -w <= z, so a vertex is inside the near plane when z + w >= 0.
fn nearDistance(v: ClipVertex) f32 {
    return v.pos.z() + v.pos.w();
}

/// Clips a triangle against the near plane (Sutherland-Hodgman, one plane).
/// Writes the resulting polygon into `out` and returns its vertex count:
/// 0 = entirely behind the near plane, 3 = a triangle, 4 = a quad.
/// A triangle clipped by a single plane can never produce more than 4 vertices.
pub fn clipTriangleNear(tri: [3]ClipVertex, out: *[4]ClipVertex) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const cur = tri[i];
        const nxt = tri[(i + 1) % 3];
        const d_cur = nearDistance(cur);
        const d_nxt = nearDistance(nxt);

        // Keep the current vertex when it's on the visible side.
        if (d_cur >= 0) {
            out[n] = cur;
            n += 1;
        }
        // The edge crosses the plane: emit the intersection point.
        if ((d_cur >= 0) != (d_nxt >= 0)) {
            const t = d_cur / (d_cur - d_nxt);
            out[n] = ClipVertex.lerp(cur, nxt, t);
            n += 1;
        }
    }
    return n;
}

const std = @import("std");

test "fully visible triangle passes through unchanged" {
    const v = [3]ClipVertex{
        .{ .pos = math.vec4(0, 0, 1, 2), .uv = math.vec2(0, 0) },
        .{ .pos = math.vec4(1, 0, 1, 2), .uv = math.vec2(1, 0) },
        .{ .pos = math.vec4(0, 1, 1, 2), .uv = math.vec2(0, 1) },
    };
    var out: [4]ClipVertex = undefined;
    try std.testing.expectEqual(@as(usize, 3), clipTriangleNear(v, &out));
}

test "triangle fully behind the near plane is discarded" {
    // z + w < 0 for every vertex.
    const v = [3]ClipVertex{
        .{ .pos = math.vec4(0, 0, -3, 1), .uv = math.vec2(0, 0) },
        .{ .pos = math.vec4(1, 0, -3, 1), .uv = math.vec2(1, 0) },
        .{ .pos = math.vec4(0, 1, -3, 1), .uv = math.vec2(0, 1) },
    };
    var out: [4]ClipVertex = undefined;
    try std.testing.expectEqual(@as(usize, 0), clipTriangleNear(v, &out));
}

test "straddling triangle is split into a quad" {
    // Two vertices inside (z + w >= 0), one outside.
    const v = [3]ClipVertex{
        .{ .pos = math.vec4(0, 0, 1, 2), .uv = math.vec2(0, 0) }, // inside
        .{ .pos = math.vec4(1, 0, 1, 2), .uv = math.vec2(1, 0) }, // inside
        .{ .pos = math.vec4(0, 1, -3, 1), .uv = math.vec2(0, 1) }, // outside
    };
    var out: [4]ClipVertex = undefined;
    try std.testing.expectEqual(@as(usize, 4), clipTriangleNear(v, &out));
}
