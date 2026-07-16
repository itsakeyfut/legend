//! PNG decoding, enough of it to read the textures glTF models carry: 8-bit
//! RGB and RGBA, no palette, no interlacing.
//!
//! A PNG is an 8-byte signature followed by a run of chunks, each a length, a
//! four-letter type, that many bytes of data, and a CRC. Three chunk types
//! matter here: IHDR (dimensions and format, always first), IDAT (the pixel
//! data, zlib-compressed, possibly split across several chunks), and IEND (the
//! end). Everything else is skipped.
//!
//! Decoding is three steps: gather IDAT bytes, inflate them (that part is
//! std.compress.flate's job), then undo the per-row filtering PNG applies to
//! help compression -- which is the step unique to PNG.

const std = @import("std");

const color = @import("color.zig");

pub const Error = error{
    NotPng,
    Truncated,
    UnsupportedColorType,
    UnsupportedBitDepth,
    UnsupportedInterlace,
    MissingHeader,
    MissingData,
};

// The 8 bytes that open every PNG. The odd mix is a deliberate integrity check:
// it catches files mangled by text-mode transfers, stray CR/LF conversion, and
// bytes with the high bit stripped.
const signature = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

/// The IHDR fields we act on. Width and height are obvious: color_type and
/// bit_depth together decide how many bytes a pixel takes and how to read it.
const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,

    /// Bytes per pixel, for the color types we support (all 8-bit).
    fn bytesPerPixel(self: Header) !usize {
        return switch (self.color_type) {
            2 => 3, // RGB
            6 => 4, // RGBA
            else => Error.UnsupportedColorType,
        };
    }
};

/// Reads the IHDR chunk's fields. IHDR is always the first chunk, and its data
/// is a fixed 13 bytes: width(4), height(4), bit depth(1), color type(1), then
/// compression/filter/interlace method(1, each).
fn parseHeader(data: []const u8) !Header {
    if (data.len < 13) return Error.Truncated;
    const h = Header{
        .width = std.mem.readInt(u32, data[0..4], .big),
        .height = std.mem.readInt(u32, data[4..8], .big),
        .bit_depth = data[8],
        .color_type = data[9],
    };
    // interlace method is data[12]; we only handle non-interlaced (0).
    if (data[12] != 0) return Error.UnsupportedInterlace;
    if (h.bit_depth != 8) return Error.UnsupportedBitDepth;
    _ = try h.bytesPerPixel(); // reject unsupported color types early
    return h;
}

/// Walks the chunk stream, returning the header and the concatenated IDAT bytes.
/// The IDAT payload is still compressed; inflating it is the caller's next step.
/// The returned IDAT slice is freshly allocated and owned by the caller.
fn readChunks(allocator: std.mem.Allocator, bytes: []const u8) !struct { header: Header, idat: []u8 } {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return Error.NotPng;

    var header: ?Header = null;
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    errdefer idat.deinit(allocator);

    // Chunks begin right after the 8-byte signature.
    var off: usize = 8;
    while (off + 8 <= bytes.len) {
        const len: usize = @intCast(std.mem.readInt(u32, bytes[off..][0..4], .big));
        const ctype = bytes[off + 4 ..][0..4];
        const data_start = off + 8;
        const data_end = data_start + len;
        if (data_end + 4 > bytes.len) return Error.Truncated; // +4 for the CRC

        const data = bytes[data_start..data_end];

        if (std.mem.eql(u8, ctype, "IHDR")) {
            header = try parseHeader(data);
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            try idat.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
        // Every other chunk type is skipped: advance past data and its CRC.

        off = data_end + 4;
    }

    const h = header orelse return Error.MissingHeader;
    if (idat.items.len == 0) return Error.MissingData;

    return .{ .header = h, .idat = try idat.toOwnedSlice(allocator) };
}

const flate = std.compress.flate;

/// Inflates the zlib-compressed IDAT bytes. This is the borrowed part: PNG's
/// compression is plain zlib, and std does it. The result is the raw scanlines,
/// each still prefixed with a filter byte.
fn inflate(allocator: std.mem.Allocator, idat: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(idat);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&input, .zlib, &window);
    return decompress.reader.allocRemaining(allocator, .unlimited);
}

/// The Paeth predictor: picks whichever of left, up, or up-left is closest to
/// the plane they define. PNG's most effective filter, and the fiddliest to undo.
fn paeth(left: u8, up: u8, up_left: u8) u8 {
    const a: i32 = left;
    const b: i32 = up;
    const c: i32 = up_left;
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return left;
    if (pb <= pc) return up;
    return up_left;
}

/// Undoes PNG's per-row filtering in place, turning filtered scanlines back into
/// real pixel bytes. Each row is prefixed with a filter-type byte; the filters
/// predict a byte from its neighbours (left, the row above, the pixel up-left)
/// and store only the difference, so this walks top to bottom adding those
/// predictions back.
fn unfilter(
    raw: []const u8,
    width: usize,
    height: usize,
    bpp: usize,
    out: []u8,
) !void {
    const stride = width * bpp; // bytes of pixel data per row
    // Each raw row is one filter byte plus `stride` pixel bytes.
    if (raw.len < height * (stride + 1)) return Error.Truncated;

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const filter = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const dst = out[y * stride ..][0..stride];
        const prev = if (y > 0) out[(y - 1) * stride ..][0..stride] else null;

        var i: usize = 0;
        while (i < stride) : (i += 1) {
            const x = src[i];
            // The already-reconstructed neighbours.
            const left: u8 = if (i >= bpp) dst[i - bpp] else 0;
            const up: u8 = if (prev) |p| p[i] else 0;
            const up_left: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;

            dst[i] = switch (filter) {
                0 => x, // None
                1 => x +% left, // Sub
                2 => x +% up, // Up
                3 => x +% @as(u8, @intCast((@as(u16, left) + up) / 2)), // Average
                4 => x +% paeth(left, up, up_left), // Paeth
                else => return Error.Truncated, // unknown filter type
            };
        }
    }
}

/// Decodes a PNG into an RGBA image. RGB sources are widened to RGBA with a fully
/// opaque alpha, so the caller always gets four channels.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !color.Image(.rgba) {
    const chunks = try readChunks(allocator, bytes);
    defer allocator.free(chunks.idat);
    const header = chunks.header;

    const raw = try inflate(allocator, chunks.idat);
    defer allocator.free(raw);

    const bpp = try header.bytesPerPixel();
    const width: usize = @intCast(header.width);
    const height: usize = @intCast(header.height);

    // Unfilter into a tight pixel buffer in the source's own channel count.
    const pixels = try allocator.alloc(u8, width * height * bpp);
    defer allocator.free(pixels);
    try unfilter(raw, width, height, bpp, pixels);

    // Produce RGBA regardless of source. Source RGB gets an opaque alpha.
    var img = try color.Image(.rgba).init(allocator, header.width, header.height);
    errdefer img.deinit();

    // Produce RGBA regardless of source. Source RGB gets an opaque alpha. The
    // image stores pixels as structs, not loose bytes, so each is assembled and
    // written whole.
    const src_pixels = width * height;
    var p: usize = 0;
    while (p < src_pixels) : (p += 1) {
        const s = p * bpp;
        img.pixels[p] = .{
            .r = pixels[s + 0],
            .g = pixels[s + 1],
            .b = pixels[s + 2],
            .a = if (bpp == 4) pixels[s + 3] else 255,
        };
    }

    return img;
}

// A 2x2 RGB PNG, filter None: red, green / blue, white. Small enough to embed,
// with every pixel a known value -- so a wrong unfilter, a byte-order slip, or a
// broken inflate all show up as a wrong colour.
const test_png = [_]u8{
    137, 80,  78,  71,  13,  10,  26,  10,  0,   0,   0,   13,
    73,  72,  68,  82,  0,   0,   0,   2,   0,   0,   0,   2,
    8,   2,   0,   0,   0,   253, 212, 154, 115, 0,   0,   0,
    18,  73,  68,  65,  84,  120, 156, 99,  248, 207, 192, 192,
    0,   194, 12,  255, 129, 0,   0,   31,  238, 5,   251, 11,
    217, 104, 139, 0,   0,   0,   0,   73,  69,  78,  68,  174,
    66,  96,  130,
};

test "decode 2x2 RGB PNG" {
    const a = std.testing.allocator;
    var img = try decode(a, &test_png);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);

    // RGBA out, four bytes per pixel, row-major from top-left.
    const px = img.pixels;

    // (0,0) red
    try std.testing.expectEqual(@as(u8, 255), px[0].r);
    try std.testing.expectEqual(@as(u8, 0), px[0].g);
    try std.testing.expectEqual(@as(u8, 0), px[0].b);
    try std.testing.expectEqual(@as(u8, 255), px[0].a); // opaque alpha added

    // (1,0) green
    try std.testing.expectEqual(@as(u8, 0), px[1].r);
    try std.testing.expectEqual(@as(u8, 255), px[1].g);
    try std.testing.expectEqual(@as(u8, 0), px[1].b);

    // (0,1) blue -- second row, pixel index 2
    try std.testing.expectEqual(@as(u8, 0), px[2].r);
    try std.testing.expectEqual(@as(u8, 0), px[2].g);
    try std.testing.expectEqual(@as(u8, 255), px[2].b);

    // (1,1) white
    try std.testing.expectEqual(@as(u8, 255), px[3].r);
    try std.testing.expectEqual(@as(u8, 255), px[3].g);
    try std.testing.expectEqual(@as(u8, 255), px[3].b);
}
