const std = @import("std");
const math = @import("../math/math.zig");
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Quat = math.Quat;

pub const Vertex = struct {
    pos: Vec3,
    uv: Vec2,
    normal: Vec3,
    /// The (up to four) skeleton joints this vertex follows, by index into the
    /// skin's joint list. Static meshes leave these zero.
    joints: [4]u16 = .{ 0, 0, 0, 0 },
    /// How much each of those joints influences this vertex; the four sum to 1
    /// for a skinned vertex. A static vertex uses {1,0,0,0} -- fully bound to a
    /// single identity joint, which leaves it unmoved.
    weights: [4]f32 = .{ 1, 0, 0, 0 },
};

pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Mesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
    }

    pub fn cube(allocator: std.mem.Allocator) !Mesh {
        const p = math.vec3;
        const corners = [8]Vec3{
            p(-1, -1, -1), p(1, -1, -1), p(1, 1, -1), p(-1, 1, -1),
            p(-1, -1, 1),  p(1, -1, 1),  p(1, 1, 1),  p(-1, 1, 1),
        };
        const FaceDef = struct { idx: [4]usize, n: Vec3 };
        const faces = [6]FaceDef{
            .{ .idx = .{ 4, 5, 6, 7 }, .n = p(0, 0, 1) },
            .{ .idx = .{ 1, 0, 3, 2 }, .n = p(0, 0, -1) },
            .{ .idx = .{ 0, 4, 7, 3 }, .n = p(-1, 0, 0) },
            .{ .idx = .{ 5, 1, 2, 6 }, .n = p(1, 0, 0) },
            .{ .idx = .{ 3, 7, 6, 2 }, .n = p(0, 1, 0) },
            .{ .idx = .{ 0, 1, 5, 4 }, .n = p(0, -1, 0) },
        };
        const uv = [4]Vec2{ math.vec2(0, 0), math.vec2(1, 0), math.vec2(1, 1), math.vec2(0, 1) };

        const verts = try allocator.alloc(Vertex, 24);
        errdefer allocator.free(verts);
        const idx = try allocator.alloc(u32, 36);
        errdefer allocator.free(idx);

        var vi: usize = 0;
        var ii: usize = 0;
        for (faces) |f| {
            const base: u32 = @intCast(vi);
            for (0..4) |k| {
                verts[vi] = .{ .pos = corners[f.idx[k]], .uv = uv[k], .normal = f.n };
                vi += 1;
            }
            idx[ii + 0] = base + 0;
            idx[ii + 1] = base + 1;
            idx[ii + 2] = base + 2;
            idx[ii + 3] = base + 0;
            idx[ii + 4] = base + 2;
            idx[ii + 5] = base + 3;
            ii += 6;
        }
        return .{ .vertices = verts, .indices = idx, .allocator = allocator };
    }

    /// A flat quad on the XZ plane, centered at the origin, `size` units across.
    /// `tiles` repeats the UVs so a small texture can cover a large floor
    /// without stretching.
    pub fn plane(allocator: std.mem.Allocator, size: f32, tiles: f32) !Mesh {
        const h = size * 0.3;
        const up = math.vec3(0, 1, 0);

        const verts = try allocator.alloc(Vertex, 4);
        errdefer allocator.free(verts);
        const idx = try allocator.alloc(u32, 6);
        errdefer allocator.free(idx);

        // Counter-clockwise seen from above, matching the cube's winding
        verts[0] = .{ .pos = math.vec3(-h, 0, h), .uv = math.vec2(0, 0), .normal = up };
        verts[1] = .{ .pos = math.vec3(h, 0, h), .uv = math.vec2(tiles, 0), .normal = up };
        verts[2] = .{ .pos = math.vec3(h, 0, -h), .uv = math.vec2(tiles, tiles), .normal = up };
        verts[3] = .{ .pos = math.vec3(-h, 0, -h), .uv = math.vec2(0, tiles), .normal = up };

        idx[0] = 0;
        idx[1] = 1;
        idx[2] = 2;
        idx[3] = 0;
        idx[4] = 2;
        idx[5] = 3;

        return .{ .vertices = verts, .indices = idx, .allocator = allocator };
    }
};

pub const Transform = struct {
    position: Vec3 = math.vec3(0, 0, 0),
    rotation: Quat = Quat.identity(),
    scale: Vec3 = math.vec3(1, 1, 1),

    pub fn matrix(self: Transform) Mat4 {
        const t = Mat4.translation(self.position);
        const r = self.rotation.toMat4();
        const s = Mat4.scaling(self.scale);
        // T * R * S: scale first, then rotate, then translate -- read right to
        // left, the order the vector actually passes through them.
        return t.mul(r).mul(s);
    }

    /// Builds a Transform from a full 4x4 matrix, by pulling translation, scale,
    /// and rotation back out of it -- the inverse of `matrix()`.
    ///
    /// glTF nodes may store their transform either as separate T/R/S or as one
    /// matrix. The spec guarantees any such matrix decomposes cleanly (no shear,
    /// no projection), so this is exact for well-formed files: translation is the
    /// last column, scale is the length of each basis column, and rotation is
    /// what remains once the scale is divided out.
    pub fn decompose(m: Mat4) Transform {
        const a = m.m;

        const translation = math.vec3(a[0][3], a[1][3], a[2][3]);

        // Each basis column's length is that axis's scale.
        const sx = math.vec3(a[0][0], a[1][0], a[2][0]).length();
        const sy = math.vec3(a[0][1], a[1][1], a[2][1]).length();
        const sz = math.vec3(a[0][2], a[1][2], a[2][2]).length();
        const scale = math.vec3(sx, sy, sz);

        // Divide the scale out of the 3x3 to leave a pure rotation, then read the
        // quaternion off it. Guard against a zero-scale axis producing NaNs.
        var r = m;
        if (sx != 0) {
            r.m[0][0] /= sx;
            r.m[1][0] /= sx;
            r.m[2][0] /= sx;
        }
        if (sy != 0) {
            r.m[0][1] /= sy;
            r.m[1][1] /= sy;
            r.m[2][1] /= sy;
        }
        if (sz != 0) {
            r.m[0][2] /= sz;
            r.m[1][2] /= sz;
            r.m[2][2] /= sz;
        }
        const rotation = Quat.fromMat4(r);

        return .{ .position = translation, .rotation = rotation, .scale = scale };
    }
};

test "cube 24 verts and 36 indices" {
    var m = try Mesh.cube(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 24), m.vertices.len);
    try std.testing.expectEqual(@as(usize, 36), m.indices.len);
}

test "plane faces up" {
    var m = try Mesh.plane(std.testing.allocator, 10, 4);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 4), m.vertices.len);
    try std.testing.expectEqual(@as(usize, 6), m.indices.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1), m.vertices[0].normal.y(), 1e-6);
}

test "Transform decompose inverts matrix" {
    const original = Transform{
        .position = math.vec3(3, -2, 5),
        .rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), math.radians(40)),
        .scale = math.vec3(2, 2, 2),
    };

    // Round trip: build the matrix, tear it back apart, and the pieces should
    // match what went in.
    const recovered = Transform.decompose(original.matrix());

    try std.testing.expectApproxEqAbs(original.position.x(), recovered.position.x(), 1e-4);
    try std.testing.expectApproxEqAbs(original.position.y(), recovered.position.y(), 1e-4);
    try std.testing.expectApproxEqAbs(original.scale.z(), recovered.scale.z(), 1e-4);

    // Rotation compared by dot product, sign-independent.
    const d = @abs(original.rotation.dot(recovered.rotation));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), d, 1e-4);
}
