//! Turning a string into the quads that draw it.
//!
//! One glyph becomes one TextItem: a rectangle in pixels, a slice of the font
//! atlas, and a colour. Nothing here touches the GPU -- the atlas texture is
//! passed in as a descriptor set the caller already owns, and the items go into
//! a buffer the caller supplies. That keeps the layout arithmetic testable and
//! the frame free of allocation.
//!
//! Coordinates are pixels from the top left, which is how anyone positioning an
//! overlay thinks. The shader converts.

const std = @import("std");

const gpu = @import("../gpu/root.zig");
const TextItem = gpu.TextItem;
const TextPush = gpu.TextPush;

const font = @import("font.zig");

/// A colour with alpha, 0..1.
pub const Color = [4]f32;

pub const white: Color = .{ 1, 1, 1, 1 };
pub const yellow: Color = .{ 1, 0.9, 0.3, 1 };
pub const grey: Color = .{ 0.7, 0.7, 0.75, 1 };

/// How wide one glyph is at the given scale. Glyphs are square and the font is
/// monospaced, so this is the whole of the metrics.
pub fn advance(scale: f32) f32 {
    return @as(f32, @floatFromInt(font.glyph_size)) * scale;
}

/// Appends the quads for `str` to `out`, starting at (x, y) in pixels and
/// returning how many were written.
///
/// Writes stop when `out` is full rather than growing it: an overlay that would
/// not fit is truncated, which is better than an allocation in the middle of a
/// frame. Newlines move to the next line and back to the starting x.
pub fn layout(
    out: []TextItem,
    atlas_set: gpu.DescriptorSet,
    screen_w: f32,
    screen_h: f32,
    x: f32,
    y: f32,
    scale: f32,
    color: Color,
    str: []const u8,
) usize {
    const size = advance(scale);
    // The atlas is a square grid of glyphs, so one glyph spans this much of it
    // along each axis.
    const uv_span = 1.0 / @as(f32, @floatFromInt(font.atlas_glyphs));

    var n: usize = 0;
    var pen_x = x;
    var pen_y = y;

    for (str) |ch| {
        if (n >= out.len) break;

        if (ch == '\n') {
            pen_x = x;
            pen_y += size;
            continue;
        }

        const index = font.glyphIndex(ch);
        // A space draws nothing; skipping it saves a draw call per gap.
        if (index != 0) {
            const gx: f32 = @floatFromInt(index % font.atlas_glyphs);
            const gy: f32 = @floatFromInt(index / font.atlas_glyphs);

            out[n] = .{
                .texture = atlas_set,
                .push = .{
                    .rect = .{ pen_x, pen_y, size, size },
                    .uv_rect = .{ gx * uv_span, gy * uv_span, uv_span, uv_span },
                    .color = color,
                    .screen = .{ screen_w, screen_h, 0, 0 },
                },
            };
            n += 1;
        }

        pen_x += size;
    }

    return n;
}

test "layout writes one quad per visible glyph" {
    var items: [16]TextItem = undefined;
    const dummy: gpu.DescriptorSet = null;

    // Two words, one space: three glyphs plus three, and nothing for the gap.
    const n = layout(&items, dummy, 800, 600, 0, 0, 1, white, "ABC DEF");
    try std.testing.expectEqual(@as(usize, 6), n);

    // The first glyph sits at the origin and is one glyph wide.
    try std.testing.expectEqual(@as(f32, 0), items[0].push.rect[0]);
    try std.testing.expectEqual(advance(1), items[0].push.rect[2]);
    // The fourth visible glyph is 'D', which follows the space -- four cells in.
    try std.testing.expectEqual(advance(1) * 4, items[3].push.rect[0]);
}

test "a newline returns to the starting column" {
    var items: [16]TextItem = undefined;
    const dummy: gpu.DescriptorSet = null;

    const n = layout(&items, dummy, 800, 600, 10, 20, 2, white, "A\nB");
    try std.testing.expectEqual(@as(usize, 2), n);

    try std.testing.expectEqual(@as(f32, 10), items[0].push.rect[0]);
    try std.testing.expectEqual(@as(f32, 20), items[0].push.rect[1]);
    // Second line: same column, one glyph height down.
    try std.testing.expectEqual(@as(f32, 10), items[1].push.rect[0]);
    try std.testing.expectEqual(20 + advance(2), items[1].push.rect[1]);
}

test "output is truncated rather than overrun" {
    var items: [3]TextItem = undefined;
    const dummy: gpu.DescriptorSet = null;

    const n = layout(&items, dummy, 800, 600, 0, 0, 1, white, "ABCDEFGH");
    try std.testing.expectEqual(@as(usize, 3), n);
}
