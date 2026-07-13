//! Convenience loaders: read an encoded image off disk and hand back a buffer
//! the renderer can sample directly.

const std = @import("std");
const color = @import("color.zig");
const qoi = @import("qoi.zig");

/// Reads a QOI file and drops alpha: the framebuffer and the texture sampler
/// are both RGB, so carrying it further would be dead weight
pub fn loadQoiRgb(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !color.Image(.rgb) {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const size: usize = @intCast(try file.length(io));
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    var rgba = try qoi.decode(allocator, bytes);
    defer rgba.deinit();

    const rgb = try color.Image(.rgb).init(allocator, rgba.width, rgba.height);
    for (rgba.pixels, 0..) |px, i| {
        rgb.pixels[i] = .{ .r = px.r, .g = px.g, .b = px.b };
    }
    return rgb;
}
