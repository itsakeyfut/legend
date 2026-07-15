//! glTF 2.0 loading -- the binary .glb container, and enough of the JSON to pull
//! meshes and a node hierarchy out of it.
//!
//! glTF is a JSON document describing a scene, plus a block of raw bytes the JSON
//! indexes into. A .glb wraps both in one binary file: a small header, a JSON
//! chunk, and a BIN chunk. This file opens that container; interpreting the JSON
//! is the next step.
//!
//! The JSON is a web of indices -- a mesh names an accessor, which names a buffer
//! view, which names a byte range in the buffer. Pulling one vertex stream out
//! means walking that whole chain. It looks indirect, and is: the point is that
//! one block of bytes can be read many ways.

const std = @import("std");
const json = std.json;

const math = @import("../math/math.zig");
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const Vertex = mesh_mod.Vertex;

pub const Error = error{
    NotGlb,
    UnsupportedVersion,
    BadChunk,
    MissingJsonChunk,
    MissingBinChunk,
    // -- JSON interpretation --
    MalformedGltf,
    NoMeshes,
    MissingAttributes,
    UnsupportedComponentType,
    UnsupportedPrimitiveMode,
    AccessorOutOfRange,
};

const magic_gltf: u32 = 0x46546C67; // "glTF", little-endian
const chunk_json: u32 = 0x4E4F534A; // "JSON"
const chunk_bin: u32 = 0x004E4942; // "BIN\0"

/// The two chunks of a .glb, still raw: the JSON text, and the binary blob its
/// accessors point into. Both borrow from the file bytes the caller holds.
pub const Glb = struct {
    json: []const u8,
    bin: []const u8,
};

/// Splits a .glb file into its JSON and BIN chunks without interpreting either.
/// `bytes` must outlive the result: the slices point into it.
pub fn parseGlb(bytes: []const u8) !Glb {
    if (bytes.len < 12) return Error.NotGlb;

    const magic = readU32(bytes, 0);
    const version = readU32(bytes, 4);
    const total = readU32(bytes, 8);

    if (magic != magic_gltf) return Error.NotGlb;
    if (version != 2) return Error.UnsupportedVersion;
    if (total > bytes.len) return Error.BadChunk;

    var json_chunk: ?[]const u8 = null;
    var bin_chunk: ?[]const u8 = null;

    // Chunks follow the 12-byte header back to back: each is a length, a type
    // tag, then that many bytes of body.
    var off: usize = 12;
    while (off + 8 <= total) {
        const clen = readU32(bytes, off);
        const ctype = readU32(bytes, off + 4);
        const body_start = off + 8;
        const body_end = body_start + clen;
        if (body_end > total) return Error.BadChunk;

        const body = bytes[body_start..body_end];
        switch (ctype) {
            chunk_json => json_chunk = body,
            chunk_bin => bin_chunk = body,
            else => {}, // unknown chunk types are allowed to exist; skip them
        }
        off = body_end;
    }

    return .{
        .json = json_chunk orelse return Error.MissingJsonChunk,
        .bin = bin_chunk orelse return Error.MissingBinChunk,
    };
}

/// Little-endian u32 read. glTF is little-endian on every field, so this is the
/// only byte-order path in the file.
fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

// -- glTF magic numbers ------------------------------------------------------
// The spec encodes types as integers; these name the ones we handle.
const component_u16: i64 = 5123; // unsigned short
const component_u32: i64 = 5125; // unsigned int
const component_f32: i64 = 5126; // float
const primitive_triangles: i64 = 4; // the only mode we draw

// -- small helpers over std.json.Value ---------------------------------------
// glTF routinely omits fields -- Box has no UVs -- so every lookup is optional
// by default, and the caller decides whether absence is fatal.

fn obj(v: json.Value) ?json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn field(v: json.Value, name: []const u8) ?json.Value {
    const o = obj(v) orelse return null;
    return o.get(name);
}

/// An integer, whether JSON stored it as an int or (as some exporters do) a
/// float with no fractional part.
fn asInt(v: json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn asFloat(v: json.Value) ?f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn fieldInt(v: json.Value, name: []const u8) ?i64 {
    return asInt(field(v, name) orelse return null);
}

fn arr(v: json.Value) ?json.Array {
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

/// The `index`-th element of a top-level array like "accessors" or "meshes".
fn nth(root: json.Value, name: []const u8, index: usize) ?json.Value {
    const a = arr(field(root, name) orelse return null) orelse return null;
    if (index >= a.items.len) return null;
    return a.items[index];
}

// -- reading accessors -------------------------------------------------------
// An accessor is the join between the JSON and the bytes: it says which buffer
// view to read, at what offset, as what type, how many times. Following it is
// the whole game -- position, normal, and index streams are all just accessors
// with different element types.

/// Where an accessor's data physically lives, once its chain is resolved: a byte
/// range in the BIN blob, plus how the elements are packed.
const AccessorView = struct {
    /// The bytes this accessor spans, already sliced out of the BIN blob.
    bytes: []const u8,
    /// Elements in the accessor (vertives, or indices).
    count: usize,
    /// componentType: 5123 (u16), 5125 (u32), or 5126 (f32)
    component_type: i64,
    /// Components per element: 1 for SCALAR, 3 for VEC3, and so on.
    components: usize,
    /// Bytes from one element to the next. Zero in the JSON means tightly
    /// packed, which the resolver fills in as components * component size.
    stride: usize,
};

fn componentSize(component_type: i64) !usize {
    return switch (component_type) {
        component_u16 => 2,
        component_u32 => 4,
        component_f32 => 4,
        else => Error.UnsupportedComponentType,
    };
}

fn typeComponents(type_str: []const u8) usize {
    if (std.mem.eql(u8, type_str, "SCALAR")) return 1;
    if (std.mem.eql(u8, type_str, "VEC2")) return 2;
    if (std.mem.eql(u8, type_str, "VEC3")) return 3;
    if (std.mem.eql(u8, type_str, "VEC4")) return 4;
    return 0; // unknown; caller treats as malformed
}

/// Resolves accessor N down to the bytes it covers. This is the accessor ->
/// bufferView -> buffer walk, in one place.
fn resolveAccessor(root: json.Value, bin: []const u8, index: usize) !AccessorView {
    const accessor = nth(root, "accessors", index) orelse return Error.AccessorOutOfRange;

    const buffer_view_idx: usize = @intCast(fieldInt(accessor, "bufferView") orelse return Error.MalformedGltf);
    const component_type = fieldInt(accessor, "componentType") orelse return Error.MalformedGltf;
    const count: usize = @intCast(fieldInt(accessor, "count") orelse return Error.MalformedGltf);
    // The accessor may start partway into its buffer view.
    const accessor_offset: usize = @intCast(fieldInt(accessor, "byteOffset") orelse 0);

    const type_val = field(accessor, "type") orelse return Error.MalformedGltf;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return Error.MalformedGltf,
    };
    const components = typeComponents(type_str);
    if (components == 0) return Error.MalformedGltf;

    const view = nth(root, "bufferViews", buffer_view_idx) orelse return Error.MalformedGltf;
    const view_offset: usize = @intCast(fieldInt(view, "byteOffset") orelse 0);
    const view_length: usize = @intCast(fieldInt(view, "byteLength") orelse return Error.MalformedGltf);

    const elem_size = try componentSize(component_type);
    // Stride: the JSON's byteStride if present (interleaved data), otherwise the
    // element packs tightly.
    const stride: usize = if (fieldInt(view, "byteStride")) |s| @intCast(s) else components * elem_size;

    // The window into BIN: the buffer view's range, then the accessor's offset
    // within it. We only ever have buffer 0 (the BIN blob) in a .glb.
    const start = view_offset + accessor_offset;
    const span = view_length;
    if (start + span > bin.len) return Error.AccessorOutOfRange;

    return .{
        .bytes = bin[start .. view_offset + view_length],
        .count = count,
        .component_type = component_type,
        .components = components,
        .stride = stride,
    };
}

/// Reads one f32 vector element (2, 3, or 4 wide) from an accessor by index.
/// `out` must have room for `view.components` floats.
fn readVec(view: AccessorView, i: usize, out: []f32) void {
    const base = i * view.stride;
    for (0..view.components) |c| {
        const off = base + c * 4;
        out[c] = @bitCast(std.mem.readInt(u32, view.bytes[off..][0..4], .little));
    }
}

/// Reads one index, whether the accessor stores u16 or u32.
fn readIndex(view: AccessorView, i: usize) u32 {
    const off = i * view.stride;
    return switch (view.component_type) {
        component_u16 => std.mem.readInt(u16, view.bytes[off..][0..2], .little),
        component_u32 => std.mem.readInt(u32, view.bytes[off..][0..4], .little),
        else => 0,
    };
}

test "parseGlb splits a minimal glb" {
    // A hand-built minimal .glb: header + a JSON chunk + a BIN chunk.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const a = std.testing.allocator;

    const json_body = "{\"asset\":{\"version\":\"2.0\"}}";
    const bin_body = [_]u8{ 1, 2, 3, 4 };

    // Header is written last (it needs the total length), so assemble the body
    // first in a scratch list.
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(a);
    try appendU32(&body, a, @intCast(json_body.len));
    try appendU32(&body, a, chunk_json);
    try body.appendSlice(a, json_body);
    try appendU32(&body, a, bin_body.len);
    try appendU32(&body, a, chunk_bin);
    try body.appendSlice(a, &bin_body);

    const total: u32 = @intCast(12 + body.items.len);
    try appendU32(&buf, a, magic_gltf);
    try appendU32(&buf, a, 2);
    try appendU32(&buf, a, total);
    try buf.appendSlice(a, body.items);

    const glb = try parseGlb(buf.items);
    try std.testing.expectEqualStrings(json_body, glb.json);
    try std.testing.expectEqualSlices(u8, &bin_body, glb.bin);
}

fn appendU32(list: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try list.appendSlice(a, &tmp);
}
