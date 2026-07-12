const std = @import("std");
const math = @import("../math/math.zig");
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pub const Vertex = struct {
    pos: Vec3,
    uv: Vec2,
    normal: Vec3,
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
};

pub const Transform = struct {
    position: Vec3 = math.vec3(0, 0, 0),
    rotation: Vec3 = math.vec3(0, 0, 0),
    scale: Vec3 = math.vec3(1, 1, 1),

    pub fn matrix(self: Transform) Mat4 {
        const t = Mat4.translation(self.position);
        const r = Mat4.rotationY(self.rotation.y())
            .mul(Mat4.rotationX(self.rotation.x()))
            .mul(Mat4.rotationZ(self.rotation.z()));
        const s = Mat4.scaling(self.scale);
        return t.mul(r).mul(s);
    }
};

test "cube 24 verts and 36 indices" {
    var m = try Mesh.cube(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 24), m.vertices.len);
    try std.testing.expectEqual(@as(usize, 36), m.indices.len);
}
