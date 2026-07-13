//! Procedurally generated textures. Useful before there is an asset pipeline,
//! and useful afterwards for placeholders and debug surfaces.

const std = @import("std");
const color = @import("color.zig");

pub const Rgb = color.Rgb;
const Image = color.Image;

/// A solid colour, 1x1. Combined with a material tint this is how a flat-shaded
/// object is expressed without giving the rasterizer an "untextured" branch.
pub fn solid(allocator: std.mem.Allocator, c: Rgb) !Image(.rgb) {
    var img = try Image(.rgb).init(allocator, 1, 1);
    img.pixels[0] = c;
    return img;
}

/// A checkerboard of `cells` squares per side.
pub fn checker(
    allocator: std.mem.Allocator,
    size: u32,
    cells: u32,
    light: Rgb,
    dark: Rgb,
) !Image(.rgb) {
    var img = try Image(.rgb).init(allocator, size, size);
    const cell = @max(1, size / cells);
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const on = ((x / cell) + (y / cell)) % 2 == 0;
            img.at(x, y).* = if (on) light else dark;
        }
    }
    return img;
}

/// A single grid cell: a line along two edges, flat colour elsewhere. Tiled by
/// UV repetition it reads as a ground plane, which makes distance and motion
/// legible in a way an empty floor does not.
pub fn grid(
    allocator: std.mem.Allocator,
    size: u32,
    line_width: u32,
    line: Rgb,
    fill: Rgb,
) !Image(.rgb) {
    var img = try Image(.rgb).init(allocator, size, size);
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const on_line = x < line_width or y < line_width;
            img.at(x, y).* = if (on_line) line else fill;
        }
    }
    return img;
}

test "solid is one texel" {
    var img = try solid(std.testing.allocator, .{ .r = 1, .g = 2, .b = 3 });
    defer img.deinit();
    try std.testing.expectEqual(@as(usize, 1), img.pixels.len);
    try std.testing.expectEqual(@as(u8, 2), img.pixels[0].g);
}

test "checker alternates" {
    var img = try checker(std.testing.allocator, 4, 2, .{ .r = 255, .g = 255, .b = 255 }, .{ .r = 0, .g = 0, .b = 0 });
    defer img.deinit();
    try std.testing.expectEqual(@as(u8, 255), img.at(0, 0).r);
    try std.testing.expectEqual(@as(u8, 0), img.at(2, 0).r);
    try std.testing.expectEqual(@as(u8, 255), img.at(2, 2).r);
}

test "grid draws lines on two edges" {
    var img = try grid(std.testing.allocator, 8, 1, .{ .r = 255, .g = 255, .b = 255 }, .{ .r = 0, .g = 0, .b = 0 });
    defer img.deinit();
    try std.testing.expectEqual(@as(u8, 255), img.at(0, 4).r); // left edge
    try std.testing.expectEqual(@as(u8, 255), img.at(4, 0).r); // top edge
    try std.testing.expectEqual(@as(u8, 0), img.at(4, 4).r); // interior
}
