//! Rasterization primitives: lines, solid triangles, and perspective-correct
//! textured triangles, plus the mesh-level draw entry point.

const std = @import("std");
const image = @import("../image/root.zig");
const math = @import("../math/math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const Vertex = mesh_mod.Vertex;
const clip = @import("clip.zig");
const ClipVertex = clip.ClipVertex;
const fb_mod = @import("framebuffer.zig");
const Framebuffer = fb_mod.Framebuffer;
const Color = fb_mod.Color;

/// Screen-space vertex for a flat-shaded triangle.
pub const Vert = struct { x: f32, y: f32, z: f32 };

/// Screen-space vertex carrying 1/w so UVs can be interpolated
/// perspective-correctly.
pub const TexVert = struct {
    x: f32,
    y: f32,
    z: f32,
    inv_w: f32,
    u: f32,
    v: f32,
};

/// Front faces are wound counter-clockwise when seen from outside. The
/// viewport transform flips Y, which flips the sign of the signed area, so a
/// front-facing triangle ends up with a *negative* area on screen.
/// If a model renders inside-out, flip this.
const front_face_is_negative_area = true;

pub fn line(fb: *Framebuffer, x0: i32, y0: i32, x1: i32, y1: i32, c: Color) void {
    var x = x0;
    var y = y0;

    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err: i32 = dx + dy;

    while (true) {
        fb.setPixel(x, y, c);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

/// Twice the signed area of triangle (a, b, p). Used both for the inside test
/// and for the barycentric weights.
fn edge(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32) f32 {
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

/// Screen-space bounding box of a triangle, clamped to the framebuffer.
const Bounds = struct { min_x: i32, min_y: i32, max_x: i32, max_y: i32 };

fn boundsOf(fb: *Framebuffer, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) Bounds {
    const fw: i32 = @intCast(fb.width());
    const fh: i32 = @intCast(fb.height());
    var b: Bounds = .{
        .min_x = @intFromFloat(@floor(@min(ax, @min(bx, cx)))),
        .min_y = @intFromFloat(@floor(@min(ay, @min(by, cy)))),
        .max_x = @intFromFloat(@ceil(@max(ax, @max(bx, cx)))),
        .max_y = @intFromFloat(@ceil(@max(ay, @max(by, cy)))),
    };
    b.min_x = @max(b.min_x, 0);
    b.min_y = @max(b.min_y, 0);
    b.max_x = @min(b.max_x, fw - 1);
    b.max_y = @min(b.max_y, fh - 1);
    return b;
}

/// Fills a triangle with a single color, depth-tested.
pub fn triangle(fb: *Framebuffer, a: Vert, b: Vert, c: Vert, color: Color) void {
    const area = edge(a.x, a.y, b.x, b.y, c.x, c.y);
    if (area == 0) return;
    const inv_area = 1.0 / area;

    const bb = boundsOf(fb, a.x, a.y, b.x, b.y, c.x, c.y);
    const fb_w: usize = fb.width();

    var y: i32 = bb.min_y;
    while (y <= bb.max_y) : (y += 1) {
        var x: i32 = bb.min_x;
        while (x <= bb.max_x) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;

            // Dividing by the *signed* area makes this work for both windings.
            const w0 = edge(b.x, b.y, c.x, c.y, px, py) * inv_area;
            const w1 = edge(c.x, c.y, a.x, a.y, px, py) * inv_area;
            const w2 = edge(a.x, a.y, b.x, b.y, px, py) * inv_area;
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;

            const z = w0 * a.z + w1 * b.z + w2 * c.z;
            const idx = @as(usize, @intCast(y)) * fb_w + @as(usize, @intCast(x));
            if (z >= fb.depth[idx]) continue;
            fb.depth[idx] = z;
            fb.color.pixels[idx] = color;
        }
    }
}

/// Nearest-neighbour texture fetch. UVs are clamped to [0, 1].
fn sample(tex: image.Image(.rgb), u: f32, v: f32) Color {
    const uu = std.math.clamp(u, 0.0, 1.0);
    const vv = std.math.clamp(v, 0.0, 1.0);
    const tw: f32 = @floatFromInt(tex.width);
    const th: f32 = @floatFromInt(tex.height);
    var tx: u32 = @intFromFloat(uu * (tw - 1.0));
    var ty: u32 = @intFromFloat(vv * (th - 1.0));
    if (tx >= tex.width) tx = tex.width - 1;
    if (ty >= tex.height) ty = tex.height - 1;
    return tex.pixels[ty * tex.width + tx];
}

fn shadeChannel(ch: u8, intensity: f32) u8 {
    const v = @as(f32, @floatFromInt(ch)) * intensity;
    return @intFromFloat(std.math.clamp(v, 0.0, 255.0));
}

fn shade(c: Color, intensity: f32) Color {
    return .{
        .r = shadeChannel(c.r, intensity),
        .g = shadeChannel(c.g, intensity),
        .b = shadeChannel(c.b, intensity),
    };
}

/// Fills a triangle with a texture, depth-tested, with perspective-correct UVs
/// and a flat shading factor.
pub fn triangleTextured(
    fb: *Framebuffer,
    a: TexVert,
    b: TexVert,
    c: TexVert,
    tex: image.Image(.rgb),
    intensity: f32,
) void {
    const area = edge(a.x, a.y, b.x, b.y, c.x, c.y);
    if (area == 0) return;
    const inv_area = 1.0 / area;

    const bb = boundsOf(fb, a.x, a.y, b.x, b.y, c.x, c.y);
    const fb_w: usize = fb.width();

    var y: i32 = bb.min_y;
    while (y <= bb.max_y) : (y += 1) {
        var x: i32 = bb.min_x;
        while (x <= bb.max_x) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;

            const w0 = edge(b.x, b.y, c.x, c.y, px, py) * inv_area;
            const w1 = edge(c.x, c.y, a.x, a.y, px, py) * inv_area;
            const w2 = edge(a.x, a.y, b.x, b.y, px, py) * inv_area;
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;

            const z = w0 * a.z + w1 * b.z + w2 * c.z;
            const idx = @as(usize, @intCast(y)) * fb_w + @as(usize, @intCast(x));
            if (z >= fb.depth[idx]) continue;

            // Perspective correction: interpolate u/w and 1/w linearly in
            // screen space, then divide at the end.
            const iw = w0 * a.inv_w + w1 * b.inv_w + w2 * c.inv_w;
            const u = (w0 * a.u * a.inv_w + w1 * b.u * b.inv_w + w2 * c.u * c.inv_w) / iw;
            const v = (w0 * a.v * a.inv_w + w1 * b.v * b.inv_w + w2 * c.v * c.inv_w) / iw;

            fb.depth[idx] = z;
            // Bounds were already clamped, so write straight into the buffer.
            fb.color.pixels[idx] = shade(sample(tex, u, v), intensity);
        }
    }
}

/// Perspective divide plus viewport transform.
fn toScreen(v: ClipVertex, w: f32, h: f32) TexVert {
    const inv_w = 1.0 / v.pos.w();
    return .{
        .x = (v.pos.x() * inv_w * 0.5 + 0.5) * w,
        .y = (1.0 - (v.pos.y() * inv_w * 0.5 + 0.5)) * h,
        .z = v.pos.z() * inv_w,
        .inv_w = inv_w,
        .u = v.uv.x(),
        .v = v.uv.y(),
    };
}

/// Draws a mesh with flat Lambert shading.
/// `model` takes the mesh to world space; `vp` is projection * view.
pub fn drawMesh(
    fb: *Framebuffer,
    mesh: Mesh,
    model: Mat4,
    vp: Mat4,
    tex: image.Image(.rgb),
    light_dir: Vec3,
    ambient: f32,
) void {
    const mvp = vp.mul(model);
    // Normals need the inverse-transpose, or non-uniform scale skews them.
    const normal_mat = model.normalMatrix();

    const w: f32 = @floatFromInt(fb.width());
    const h: f32 = @floatFromInt(fb.height());

    var tri: usize = 0;
    while (tri < mesh.indices.len) : (tri += 3) {
        const v0 = mesh.vertices[mesh.indices[tri + 0]];
        const v1 = mesh.vertices[mesh.indices[tri + 1]];
        const v2 = mesh.vertices[mesh.indices[tri + 2]];

        // Flat shading: one normal for the whole face.
        const n = normal_mat.mulVec4(v0.normal.toVec4(0)).xyz().normalize();
        const diffuse = @max(0.0, n.dot(light_dir));
        const intensity = ambient + (1.0 - ambient) * diffuse;

        // Transform to clip space and clip against the near plane *before*
        // the perspective divide.
        const tri_clip = [3]ClipVertex{
            .{ .pos = mvp.mulVec4(v0.pos.toVec4(1)), .uv = v0.uv },
            .{ .pos = mvp.mulVec4(v1.pos.toVec4(1)), .uv = v1.uv },
            .{ .pos = mvp.mulVec4(v2.pos.toVec4(1)), .uv = v2.uv },
        };
        var poly: [4]ClipVertex = undefined;
        const n_poly = clip.clipTriangleNear(tri_clip, &poly);
        if (n_poly < 3) continue;

        // Fan-triangulate the clipped polygon (3 or 4 vertices).
        var k: usize = 1;
        while (k + 1 < n_poly) : (k += 1) {
            const a = toScreen(poly[0], w, h);
            const b = toScreen(poly[k], w, h);
            const c = toScreen(poly[k + 1], w, h);

            // Back-face culling: skip triangles facing away from the camera.
            const area = edge(a.x, a.y, b.x, b.y, c.x, c.y);
            const front = if (front_face_is_negative_area) area < 0 else area > 0;
            if (!front) continue;

            triangleTextured(fb, a, b, c, tex, intensity);
        }
    }
}

test "line draws both endpoints" {
    var fb = try Framebuffer.init(std.testing.allocator, 16, 16);
    defer fb.deinit();
    fb.clear(.{ .r = 0, .g = 0, .b = 0 });

    line(&fb, 2, 2, 10, 6, .{ .r = 255, .g = 255, .b = 255 });

    try std.testing.expectEqual(@as(u8, 255), fb.color.at(2, 2).r);
    try std.testing.expectEqual(@as(u8, 255), fb.color.at(10, 6).r);
}

test "triangle fills interior and respects depth" {
    var fb = try Framebuffer.init(std.testing.allocator, 8, 8);
    defer fb.deinit();
    fb.clear(.{ .r = 0, .g = 0, .b = 0 });

    triangle(&fb, .{ .x = 1, .y = 1, .z = 0 }, .{ .x = 6, .y = 1, .z = 0 }, .{ .x = 1, .y = 6, .z = 0 }, .{ .r = 255, .g = 0, .b = 0 });
    try std.testing.expectEqual(@as(u8, 255), fb.color.at(2, 2).r);

    triangle(&fb, .{ .x = 1, .y = 1, .z = 0.5 }, .{ .x = 6, .y = 1, .z = 0.5 }, .{ .x = 1, .y = 6, .z = 0.5 }, .{ .r = 0, .g = 0, .b = 255 });
    try std.testing.expectEqual(@as(u8, 255), fb.color.at(2, 2).r);
    try std.testing.expectEqual(@as(u8, 0), fb.color.at(2, 2).b);
}

test "sample reads texel" {
    var tex = try image.Image(.rgb).init(std.testing.allocator, 2, 2);
    defer tex.deinit();
    tex.at(0, 0).* = .{ .r = 10, .g = 0, .b = 0 };
    tex.at(1, 1).* = .{ .r = 40, .g = 0, .b = 0 };
    try std.testing.expectEqual(@as(u8, 10), sample(tex, 0.0, 0.0).r);
    try std.testing.expectEqual(@as(u8, 40), sample(tex, 1.0, 1.0).r);
}
