//! A mesh living in GPU memory, and the vertex layout the pipeline expects.

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;

const render_mesh = @import("../render/mesh.zig");
const Vertex = render_mesh.Vertex;

const memory = @import("memory.zig");
const Buffer = memory.Buffer;
const Uploader = memory.Uploader;

/// The vertex as the GPU sees it. `extern` because Zig's default struct layout
/// is deliberately unspecified, and the offsets below have to be the real ones.
pub const GpuVertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
    normal: [3]f32,
};

/// The vertex for a skinned mesh: the static fields plus the four joints each
/// vertex follows and their weights. Kept separate from GpuVertex so that static
/// meshes -- the overwhelming majority in any scene -- carry no skinning data
/// they will never use. This is the standard split every production engine makes.
pub const SkinnedVertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
    normal: [3]f32,
    joints: [4]u32,
    weights: [4]f32,
};

pub const skinned_binding_description = c.VkVertexInputBindingDescription{
    .binding = 0,
    .stride = @sizeOf(SkinnedVertex),
    .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
};

pub const skinned_attribute_description = [_]c.VkVertexInputAttributeDescription{
    .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(SkinnedVertex, "pos") },
    .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(SkinnedVertex, "uv") },
    .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(SkinnedVertex, "normal") },
    .{ .location = 3, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_UINT, .offset = @offsetOf(SkinnedVertex, "joints") },
    .{ .location = 4, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(SkinnedVertex, "weights") },
};

/// How the vertex buffer is strided.
pub const binding_description = c.VkVertexInputBindingDescription{
    .binding = 0,
    .stride = @sizeOf(GpuVertex),
    // PER_VERTEX rather than PER_INSTANCE: the buffer advances once per vertex.
    .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
};

/// Where each field sits within one vertex, and how the shader should read it.
/// `location` matches the attribute index the shader declares.
pub const attribute_descriptions = [_]c.VkVertexInputAttributeDescription{
    .{
        .location = 0,
        .binding = 0,
        .format = c.VK_FORMAT_R32G32B32_SFLOAT,
        .offset = @offsetOf(GpuVertex, "pos"),
    },
    .{
        .location = 1,
        .binding = 0,
        .format = c.VK_FORMAT_R32G32_SFLOAT,
        .offset = @offsetOf(GpuVertex, "uv"),
    },
    .{
        .location = 2,
        .binding = 0,
        .format = c.VK_FORMAT_R32G32B32_SFLOAT,
        .offset = @offsetOf(GpuVertex, "normal"),
    },
};

pub const GpuMesh = struct {
    vertices: Buffer,
    indices: Buffer,
    index_count: u32,

    /// Uploads a CPU mesh. The vertices are repacked into GpuVertex on the way,
    /// which costs one pass at load time and buys a layout we can rely on.
    pub fn init(
        allocator: std.mem.Allocator,
        uploader: *Uploader,
        vertices: []const Vertex,
        indices: []const u32,
    ) !GpuMesh {
        const packed_verts = try allocator.alloc(GpuVertex, vertices.len);
        defer allocator.free(packed_verts);
        for (vertices, 0..) |v, i| {
            packed_verts[i] = .{
                .pos = v.pos.v,
                .uv = v.uv.v,
                .normal = v.normal.v,
            };
        }

        var vertex_buffer = try uploader.upload(
            std.mem.sliceAsBytes(packed_verts),
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        errdefer vertex_buffer.deinit();

        const index_buffer = try uploader.upload(
            std.mem.sliceAsBytes(indices),
            c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        );

        return .{
            .vertices = vertex_buffer,
            .indices = index_buffer,
            .index_count = @intCast(indices.len),
        };
    }

    /// Uploads a mesh as skinned vertices -- the same geometry, but packed with
    /// joints and weights for the skinning pipeline. The CPU Vertex already
    /// carries them (defaulting to the static {0}/{1,0,0,0} for unrigged meshes).
    pub fn initSkinned(
        allocator: std.mem.Allocator,
        uploader: *Uploader,
        vertices: []const Vertex,
        indices: []const u32,
    ) !GpuMesh {
        const packed_verts = try allocator.alloc(SkinnedVertex, vertices.len);
        defer allocator.free(packed_verts);
        for (vertices, 0..) |v, i| {
            packed_verts[i] = .{
                .pos = v.pos.v,
                .uv = v.uv.v,
                .normal = v.normal.v,
                .joints = .{ v.joints[0], v.joints[1], v.joints[2], v.joints[3] },
                .weights = v.weights,
            };
        }

        var vertex_buffer = try uploader.upload(
            std.mem.sliceAsBytes(packed_verts),
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        errdefer vertex_buffer.deinit();

        var index_buffer = try uploader.upload(
            std.mem.sliceAsBytes(indices),
            c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        );
        errdefer index_buffer.deinit();

        return .{
            .vertices = vertex_buffer,
            .indices = index_buffer,
            .index_count = @intCast(indices.len),
        };
    }

    pub fn deinit(self: *GpuMesh) void {
        self.vertices.deinit();
        self.indices.deinit();
        self.* = undefined;
    }

    /// Binds the buffers and issues the draw.
    pub fn draw(self: *const GpuMesh, cmd: c.VkCommandBuffer) void {
        const offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(cmd, 0, 1, &self.vertices.handle, &offset);
        c.vkCmdBindIndexBuffer(cmd, self.indices.handle, 0, c.VK_INDEX_TYPE_UINT32);
        c.vkCmdDrawIndexed(cmd, self.index_count, 1, 0, 0, 0);
    }
};
