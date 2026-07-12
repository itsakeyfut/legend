//! Wavefront OBJ mesh loading.
//!
//! Parsed in two passes: the first counts how many positions / uvs / normals /
//! triangles the file holds, the second fills exactly-sized buffers. That means
//! no dynamic containers are needed anywhere in this file.
//!
//! Vertices are not deduplicated: every triangle gets its own three vertices.
//! This costs memory but keeps flat shading correct (each face keeps its own
//! normal even when it shares positions with its neighbours) and keeps the
//! parser simple. Deduplication is a later optimisation.

const std = @import("std");
const math = @import("../math/math.zig");
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const Vertex = mesh_mod.Vertex;

pub const Error = error{
    MalformedFace,
    MalformedVector,
    IndexOutOfRange,
    TooManyFaceCorners,
    NoFaces,
};

/// Faces with more corners than this are rejected rather than heap-allocated.
const max_face_corners = 64;

/// OBJ keeps positions, uvs and normals in separate index streams, so one
/// corner of a face is a triple of indices. uv and normal are optional.
const Corner = struct {
    pos: u32,
    uv: ?u32,
    normal: ?u32,
};

/// OBJ indices are 1-based, and may be negative to mean "counting back from the
/// most recent element". Resolves either form to a 0-based index.
fn resolveIndex(raw: i64, count: usize) !u32 {
    if (raw > 0) {
        const i: u64 = @intCast(raw - 1);
        if (i >= count) return Error.IndexOutOfRange;
        return @intCast(i);
    }
    if (raw < 0) {
        const back: i64 = @as(i64, @intCast(count)) + raw; // -1 => last
        if (back < 0) return Error.IndexOutOfRange;
        return @intCast(back);
    }
    return Error.MalformedFace; // 0 is never a valid OBJ index
}

/// Parses one face corner: `v`, `v/vt`, `v//vn` or `v/vt/vn`.
fn parseCorner(token: []const u8, n_pos: usize, n_uv: usize, n_normal: usize) !Corner {
    var parts = std.mem.splitScalar(u8, token, '/');

    const s_pos = parts.next() orelse return Error.MalformedFace;
    const raw_pos = std.fmt.parseInt(i64, s_pos, 10) catch return Error.MalformedFace;
    var corner = Corner{
        .pos = try resolveIndex(raw_pos, n_pos),
        .uv = null,
        .normal = null,
    };

    if (parts.next()) |s_uv| {
        if (s_uv.len > 0) { // empty in the `v//vn` form
            const raw = std.fmt.parseInt(i64, s_uv, 10) catch return Error.MalformedFace;
            corner.uv = try resolveIndex(raw, n_uv);
        }
    }
    if (parts.next()) |s_normal| {
        if (s_normal.len > 0) {
            const raw = std.fmt.parseInt(i64, s_normal, 10) catch return Error.MalformedFace;
            corner.normal = try resolveIndex(raw, n_normal);
        }
    }
    return corner;
}

fn readF32(tokens: anytype) !f32 {
    const s = tokens.next() orelse return Error.MalformedVector;
    return std.fmt.parseFloat(f32, s) catch Error.MalformedVector;
}

fn readVec3(tokens: anytype) !Vec3 {
    const x = try readF32(tokens);
    const y = try readF32(tokens);
    const z = try readF32(tokens);
    return math.vec3(x, y, z);
}

/// Reads a `vt`. OBJ puts v = 0 at the *bottom* of the texture, while our image
/// buffers store row 0 at the top, so v is flipped here. If a model's texture
/// comes out upside down, this is the line to look at.
fn readUv(tokens: anytype) !Vec2 {
    const u = try readF32(tokens);
    const v = try readF32(tokens);
    return math.vec2(u, 1.0 - v);
}

const Counts = struct {
    pos: usize = 0,
    uv: usize = 0,
    normal: usize = 0,
    tri: usize = 0,
};

/// First pass: how much of everything is in here?
fn countElements(source: []const u8) !Counts {
    var counts = Counts{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        // Trailing \r matters: OBJ files authored on Windows are CRLF.
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const keyword = tokens.next() orelse continue;

        if (std.mem.eql(u8, keyword, "v")) {
            counts.pos += 1;
        } else if (std.mem.eql(u8, keyword, "vt")) {
            counts.uv += 1;
        } else if (std.mem.eql(u8, keyword, "vn")) {
            counts.normal += 1;
        } else if (std.mem.eql(u8, keyword, "f")) {
            var corners: usize = 0;
            while (tokens.next()) |_| corners += 1;
            if (corners < 3) return Error.MalformedFace;
            counts.tri += corners - 2; // fan triangulation of an n-gon
        }
        // o / g / s / usemtl / mtllib and anything else: ignored.
    }
    return counts;
}

/// Writes the three vertices of one triangle. When the file supplies no normal
/// for a corner, a flat face normal is derived instead. OBJ winds faces
/// counter-clockwise seen from outside, so this cross product points outward.
fn emitTriangle(
    tri: [3]Corner,
    positions: []const Vec3,
    uvs: []const Vec2,
    normals: []const Vec3,
    out: []Vertex,
    cursor: *usize,
) void {
    const p0 = positions[tri[0].pos];
    const p1 = positions[tri[1].pos];
    const p2 = positions[tri[2].pos];

    const cross = p1.sub(p0).cross(p2.sub(p0));
    const len = cross.length();
    const face_normal = if (len > 0) cross.scale(1.0 / len) else math.vec3(0, 1, 0);

    for (0..3) |k| {
        const corner = tri[k];
        out[cursor.* + k] = .{
            .pos = positions[corner.pos],
            .uv = if (corner.uv) |i| uvs[i] else math.vec2(0, 0),
            .normal = if (corner.normal) |i| normals[i] else face_normal,
        };
    }
    cursor.* += 3;
}

/// Parses OBJ text into a Mesh. The caller owns the returned mesh.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Mesh {
    const counts = try countElements(source);
    if (counts.tri == 0) return Error.NoFaces;

    // Scratch: the raw index streams from the file.
    const positions = try allocator.alloc(Vec3, counts.pos);
    defer allocator.free(positions);
    const uvs = try allocator.alloc(Vec2, counts.uv);
    defer allocator.free(uvs);
    const normals = try allocator.alloc(Vec3, counts.normal);
    defer allocator.free(normals);

    // Output: three unshared vertices per triangle.
    const vertex_count = counts.tri * 3;
    const vertices = try allocator.alloc(Vertex, vertex_count);
    errdefer allocator.free(vertices);
    const indices = try allocator.alloc(u32, vertex_count);
    errdefer allocator.free(indices);

    var n_pos: usize = 0;
    var n_uv: usize = 0;
    var n_normal: usize = 0;
    var cursor: usize = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const keyword = tokens.next() orelse continue;

        if (std.mem.eql(u8, keyword, "v")) {
            positions[n_pos] = try readVec3(&tokens);
            n_pos += 1;
        } else if (std.mem.eql(u8, keyword, "vt")) {
            uvs[n_uv] = try readUv(&tokens);
            n_uv += 1;
        } else if (std.mem.eql(u8, keyword, "vn")) {
            normals[n_normal] = try readVec3(&tokens);
            n_normal += 1;
        } else if (std.mem.eql(u8, keyword, "f")) {
            var corners: [max_face_corners]Corner = undefined;
            var n: usize = 0;
            while (tokens.next()) |token| {
                if (n == max_face_corners) return Error.TooManyFaceCorners;
                // Indices resolve against what has been declared *so far*,
                // which is also what negative indices count back from.
                corners[n] = try parseCorner(token, n_pos, n_uv, n_normal);
                n += 1;
            }
            if (n < 3) return Error.MalformedFace;

            // Fan-triangulate: (0, k, k+1) for k = 1 .. n-2.
            var k: usize = 1;
            while (k + 1 < n) : (k += 1) {
                emitTriangle(
                    .{ corners[0], corners[k], corners[k + 1] },
                    positions,
                    uvs,
                    normals,
                    vertices,
                    &cursor,
                );
            }
        }
    }

    // No sharing, so the index buffer is just 0, 1, 2, ...
    for (indices, 0..) |*index, i| index.* = @intCast(i);

    return .{ .vertices = vertices, .indices = indices, .allocator = allocator };
}

/// Reads an OBJ file from disk and parses it.
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Mesh {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const size: usize = @intCast(try file.length(io));
    const source = try allocator.alloc(u8, size);
    defer allocator.free(source);
    _ = try file.readPositionalAll(io, source, 0);

    return parse(allocator, source);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "parses a triangle with positions, uvs and normals" {
    const src =
        \\# a single triangle
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vt 0 0
        \\vt 1 0
        \\vt 0 1
        \\vn 0 0 1
        \\f 1/1/1 2/2/1 3/3/1
    ;
    var mesh = try parse(testing.allocator, src);
    defer mesh.deinit();

    try testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 3), mesh.indices.len);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.vertices[1].pos.x(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.vertices[0].normal.z(), 1e-6);
}

test "quad is fan-triangulated into two triangles" {
    const src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 1 1 0
        \\v 0 1 0
        \\f 1 2 3 4
    ;
    var mesh = try parse(testing.allocator, src);
    defer mesh.deinit();
    try testing.expectEqual(@as(usize, 6), mesh.vertices.len); // 2 triangles
}

test "missing normals are replaced by a computed face normal" {
    // Counter-clockwise seen from +Z, so the face normal must be +Z.
    const src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\f 1 2 3
    ;
    var mesh = try parse(testing.allocator, src);
    defer mesh.deinit();
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.vertices[0].normal.x(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.vertices[0].normal.z(), 1e-6);
}

test "negative indices count back from the most recent element" {
    const src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\f -3 -2 -1
    ;
    var mesh = try parse(testing.allocator, src);
    defer mesh.deinit();
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.vertices[0].pos.x(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.vertices[1].pos.x(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.vertices[2].pos.y(), 1e-6);
}

test "the v//vn form is accepted" {
    const src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vn 0 0 1
        \\f 1//1 2//1 3//1
    ;
    var mesh = try parse(testing.allocator, src);
    defer mesh.deinit();
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.vertices[0].normal.z(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.vertices[0].uv.x(), 1e-6);
}

test "uv v axis is flipped to match top-down image rows" {
    const src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vt 0.25 0.75
        \\f 1/1 2/1 3/1
    ;
    var mesh = try parse(testing.allocator, src);
    defer mesh.deinit();
    try testing.expectApproxEqAbs(@as(f32, 0.25), mesh.vertices[0].uv.x(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), mesh.vertices[0].uv.y(), 1e-6); // 1 - 0.75
}

test "CRLF line endings are handled" {
    const src = "v 0 0 0\r\nv 1 0 0\r\nv 0 1 0\r\nf 1 2 3\r\n";
    var mesh = try parse(testing.allocator, src);
    defer mesh.deinit();
    try testing.expectEqual(@as(usize, 3), mesh.vertices.len);
}

test "a file with no faces is rejected" {
    const src = "v 0 0 0\nv 1 0 0\n";
    try testing.expectError(Error.NoFaces, parse(testing.allocator, src));
}
