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
