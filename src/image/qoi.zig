const std = @import("std");
const color = @import("color.zig");
const Rgba = color.Rgba;
const Image = color.Image;

pub const DecodeError = error{
    InvalidMagic,
    UnexpectedEof,
    UnsupportedChannels,
};

pub const Error = DecodeError || std.mem.Allocator.Error;

const magic = "qoif";

const op_rgb: u8 = 0xFE;
const op_rgba: u8 = 0xFF;

const Tag = enum(u2) { index = 0b00, diff = 0b01, luma = 0b10, run = 0b11 };
const OpByte = packed struct(u8) { data: u6, tag: Tag };

const DiffByte = packed struct(u8) { db: u2, dg: u2, dr: u2, tag: u2 };

const LumaByte2 = packed struct(u8) { db_dg: u4, dr_dg: u4 };

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.data.len) return error.UnexpectedEof;
        const s = self.data[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    fn byte(self: *Reader) DecodeError!u8 {
        const s = try self.take(1);
        return s[0];
    }

    fn u32be(self: *Reader) DecodeError!u32 {
        const s = try self.take(4);
        return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) |
            (@as(u32, s[2]) << 8) | @as(u32, s[3]);
    }
};

fn hash(px: Rgba) usize {
    return (@as(usize, px.r) * 3 + @as(usize, px.g) * 5 +
        @as(usize, px.b) * 7 + @as(usize, px.a) * 11) % 64;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Image(.rgba) {
    var r = Reader{ .data = bytes };

    // --- Header (14 bytes) ---
    const m = try r.take(4);
    if (!std.mem.eql(u8, m, magic)) return error.InvalidMagic;
    const width = try r.u32be();
    const height = try r.u32be();
    const channels = try r.byte();
    _ = try r.byte(); // colorspace
    if (channels != 3 and channels != 4) return error.UnsupportedChannels;

    var img = try Image(.rgba).init(allocator, width, height);
    errdefer img.deinit();

    // --- Decode ---
    var index = [_]Rgba{.{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 64;
    var px = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var run: usize = 0;

    const total: usize = @as(usize, width) * @as(usize, height);
    var i: usize = 0;
    while (i < total) : (i += 1) {
        if (run > 0) {
            run -= 1;
        } else {
            const b1 = try r.byte();
            if (b1 == op_rgb) {
                px.r = try r.byte();
                px.g = try r.byte();
                px.b = try r.byte();
            } else if (b1 == op_rgba) {
                px.r = try r.byte();
                px.g = try r.byte();
                px.b = try r.byte();
                px.a = try r.byte();
            } else {
                const op: OpByte = @bitCast(b1);
                switch (op.tag) {
                    .index => px = index[op.data],
                    .diff => {
                        const d: DiffByte = @bitCast(b1);
                        px.r +%= @as(u8, d.dr) -% 2;
                        px.g +%= @as(u8, d.dg) -% 2;
                        px.b +%= @as(u8, d.db) -% 2;
                    },
                    .luma => {
                        const b2: LumaByte2 = @bitCast(try r.byte());
                        const vg = @as(u8, op.data) -% 32;
                        px.r +%= vg +% (@as(u8, b2.dr_dg) -% 8);
                        px.g +%= vg;
                        px.b +%= vg +% (@as(u8, b2.db_dg) -% 8);
                    },
                    .run => run = op.data,
                }
            }
            index[hash(px)] = px;
        }
        img.pixels[i] = px;
    }

    return img;
}

test "decode a 1x1 RGBA qoi stream" {
    // qoif / 1 / 1 / channels=4 / colorspace=0 /
    // OP_RGBA(0xFF) r=10 g=20 b=30 a=40 / end marker
    const stream = [_]u8{
        'q', 'o', 'i', 'f',
        0, 0, 0, 1, // width
        0, 0, 0, 1, // height
        4, // channels
        0, // colorspace
        0xFF, 10, 20, 30, 40, // OP_RGBA
        0, 0, 0, 0, 0, 0, 0, 1, // end marker
    };

    var img = try decode(std.testing.allocator, &stream);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 1), img.width);
    const p = img.pixels[0];
    try std.testing.expectEqual(@as(u8, 10), p.r);
    try std.testing.expectEqual(@as(u8, 20), p.g);
    try std.testing.expectEqual(@as(u8, 30), p.b);
    try std.testing.expectEqual(@as(u8, 40), p.a);
}

test "invalid magic is rejected" {
    const bad = [_]u8{ 'n', 'o', 'p', 'e' } ++ [_]u8{0} ** 10;
    try std.testing.expectError(error.InvalidMagic, decode(std.testing.allocator, &bad));
}
