const std = @import("std");

pub fn write(io: std.Io, allocator: std.mem.Allocator, path: []const u8, image: anytype) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "P6\n{d} {d}\n255\n",
        .{ image.width, image.height },
    );

    const count = @as(usize, image.width) * @as(usize, image.height);
    const data = try allocator.alloc(u8, header.len + count * 3);
    defer allocator.free(data);

    @memcpy(data[0..header.len], header);

    var o: usize = header.len;
    for (image.pixels) |px| {
        data[o + 0] = px.r;
        data[o + 1] = px.g;
        data[o + 2] = px.b;
        o += 3;
    }

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}
