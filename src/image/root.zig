//! Image subsystem: typed pixel buffers, QOI decoding, PPM writing.
//! Carried over from the standalone `image` repository.

const color = @import("color.zig");
pub const Channels = color.Channels;
pub const Image = color.Image;
pub const Rgb = color.Rgb;
pub const Rgba = color.Rgba;

pub const png = @import("png.zig");

pub const writePpm = @import("ppm.zig").write;
pub const decodeQoi = @import("qoi.zig").decode;
pub const loadQoiRgb = @import("load.zig").loadQoiRgb;
pub const procedural = @import("procedural.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = color;
    _ = @import("ppm.zig");
    _ = @import("qoi.zig");
    _ = @import("load.zig");
    _ = @import("procedural.zig");
    _ = @import("png.zig");
}
