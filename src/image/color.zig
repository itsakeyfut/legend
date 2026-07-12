const std = @import("std");

pub const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

pub fn Pixel(comptime ch: Channels) type {
    return switch (ch) {
        .rgb => extern struct {
            r: u8,
            g: u8,
            b: u8,
            pub const channels = Channels.rgb;
        },
        .rgba => extern struct {
            r: u8,
            g: u8,
            b: u8,
            a: u8,
            pub const channels = Channels.rgba;
        },
    };
}

pub const Rgb = Pixel(.rgb);
pub const Rgba = Pixel(.rgba);

pub fn Image(comptime ch: Channels) type {
    return struct {
        const Self = @This();
        pub const Px = Pixel(ch);
        pub const channels = ch;

        width: u32,
        height: u32,
        pixels: []Px,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Self {
            const count = @as(usize, width) * @as(usize, height);
            const pixels = try allocator.alloc(Px, count);
            return .{
                .width = width,
                .height = height,
                .pixels = pixels,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.pixels);
        }

        pub fn at(self: *Self, x: u32, y: u32) *Px {
            return &self.pixels[@as(usize, y) * self.width + x];
        }

        pub fn bytes(self: Self) []u8 {
            return std.mem.sliceAsBytes(self.pixels);
        }
    };
}

test "pixel byte sizes are tight" {
    try std.testing.expectEqual(@as(usize, 3), @sizeOf(Rgb));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Rgba));
}

test "image alloc / index / free" {
    var img = try Image(.rgb).init(std.testing.allocator, 4, 2);
    defer img.deinit();
    img.at(1, 1).* = .{ .r = 10, .g = 20, .b = 30 };
    try std.testing.expectEqual(@as(u8, 20), img.at(1, 1).g);
    try std.testing.expectEqual(@as(usize, 4 * 2 * 3), img.bytes().len);
}
