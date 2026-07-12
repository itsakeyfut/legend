const std = @import("std");
const image = @import("../image/root.zig");

pub const Color = image.Rgb;

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b };
}

pub const Framebuffer = struct {
    color: image.Image(.rgb),
    depth: []f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !Framebuffer {
        var color = try image.Image(.rgb).init(allocator, w, h);
        errdefer color.deinit();
        const depth = try allocator.alloc(f32, @as(usize, w) * @as(usize, h));
        return .{ .color = color, .depth = depth, .allocator = allocator };
    }

    pub fn deinit(self: *Framebuffer) void {
        self.allocator.free(self.depth);
        self.color.deinit();
    }

    pub fn width(self: Framebuffer) u32 {
        return self.color.width;
    }
    pub fn height(self: Framebuffer) u32 {
        return self.color.height;
    }

    pub fn clear(self: *Framebuffer, c: Color) void {
        for (self.color.pixels) |*px| px.* = c;
        for (self.depth) |*d| d.* = std.math.inf(f32);
    }

    pub fn setPixel(self: *Framebuffer, xi: i32, yi: i32, c: Color) void {
        const w: i32 = @intCast(self.color.width);
        const h: i32 = @intCast(self.color.height);
        if (xi < 0 or yi < 0 or xi >= w or yi >= h) return;
        self.color.at(@intCast(xi), @intCast(yi)).* = c;
    }

    pub fn save(self: Framebuffer, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
        try image.writePpm(io, allocator, path, self.color);
    }
};

test "framebuffer clear / setPixel bounds" {
    var fb = try Framebuffer.init(std.testing.allocator, 4, 4);
    defer fb.deinit();

    fb.clear(rgb(0, 0, 0));
    fb.setPixel(1, 2, rgb(255, 0, 0));
    fb.setPixel(-1, 0, rgb(9, 9, 9));
    fb.setPixel(100, 100, rgb(9, 9, 9));

    try std.testing.expectEqual(@as(u8, 255), fb.color.at(1, 2).r);
    try std.testing.expectEqual(@as(u8, 0), fb.color.at(0, 0).r);
}
