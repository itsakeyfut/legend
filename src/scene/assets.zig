//! Assets: meshes and textures living in GPU memory, addressed by handle.
//!
//! This is the half of the old Scene that depends on the GPU and is never
//! serialized. A mesh here is VkBuffers, a texture is a VkImage and a descriptor
//! set -- none of which can be written to disk or read back. What goes in a
//! saved scene is a *handle* to one of these, resolved at load time; the asset
//! itself is loaded separately and lives only in memory.

const std = @import("std");
const slotmap = @import("slotmap");

const gpu = @import("../gpu/root.zig");
const GpuMesh = gpu.GpuMesh;
const GpuTexture = gpu.GpuTexture;
const Context = gpu.Context;

const image = @import("../image/root.zig");
const Mesh = @import("../render/mesh.zig").Mesh;

pub const MeshMap = slotmap.SlotMap(GpuMesh);
pub const TextureMap = slotmap.SlotMap(GpuTexture);

pub const MeshHandle = MeshMap.Key;
pub const TextureHandle = TextureMap.Key;

pub const Assets = struct {
    ctx: *Context,
    meshes: MeshMap,
    textures: TextureMap,

    /// A 1x1 white texture. A material wanting a flat colour binds this and sets
    /// its tint, so the shader never needs an "untextured" branch -- the same
    /// trick the software path used, now on the GPU.
    white: TextureHandle,

    pub fn init(allocator: std.mem.Allocator, ctx: *Context) !Assets {
        var meshes = try MeshMap.init(allocator);
        errdefer meshes.deinit();
        var textures = try TextureMap.init(allocator);
        errdefer textures.deinit();

        // One opaque white texel, expanded to RGBA for upload.
        const white_pixels = [_]u8{ 255, 255, 255, 255 };
        var white_tex = try ctx.uploadTexture(&white_pixels, 1, 1);
        errdefer white_tex.deinit();
        const white = try textures.insert(white_tex);

        return .{
            .ctx = ctx,
            .meshes = meshes,
            .textures = textures,
            .white = white,
        };
    }

    pub fn deinit(self: *Assets) void {
        // The GPU must be idle before any of its resources are freed.
        self.ctx.waitIdle();

        var mesh_it = self.meshes.iterator();
        while (mesh_it.next()) |e| e.value_ptr.deinit();
        self.meshes.deinit();

        var tex_it = self.textures.iterator();
        while (tex_it.next()) |e| e.value_ptr.deinit();
        self.textures.deinit();
    }

    /// Uploads a CPU mesh and takes ownership of the GPU result. The CPU mesh is
    /// the caller's to free -- upload copies what it needs.
    pub fn addMesh(self: *Assets, allocator: std.mem.Allocator, cpu_mesh: Mesh) !MeshHandle {
        var gpu_mesh = try self.ctx.uploadMesh(allocator, cpu_mesh);
        errdefer gpu_mesh.deinit();
        return self.meshes.insert(gpu_mesh);
    }

    /// Uploads an RGB image as a texture. The image is the caller's to free.
    pub fn addTexture(self: *Assets, img: image.Image(.rgb)) !TextureHandle {
        const rgba = try rgbToRgba(img);
        defer img.allocator.free(rgba);
        var tex = try self.ctx.uploadTexture(rgba, img.width, img.height);
        errdefer tex.deinit();
        return self.textures.insert(tex);
    }

    /// Uploads an already-RGBA image as a texture. PNG-decoded textures arrive
    /// in this form, so unlike addTexture there is no channel widening to do --
    /// the bytes go straight to the GPU.
    pub fn addTextureRgba(self: *Assets, img: image.Image(.rgba)) !TextureHandle {
        var tex = try self.ctx.uploadTexture(img.bytes(), img.width, img.height);
        errdefer tex.deinit();
        return self.textures.insert(tex);
    }

    pub fn mesh(self: *Assets, handle: MeshHandle) ?*GpuMesh {
        return self.meshes.getPtr(handle);
    }

    pub fn texture(self: *Assets, handle: TextureHandle) ?*GpuTexture {
        return self.textures.getPtr(handle);
    }
};

/// RGB to RGBA, opaque. Vulkan has no 24-bit sampled format in practice, so the
/// fourth byte is not optional. Allocated with the image's own allocator so the
/// caller frees it the same way.
fn rgbToRgba(img: image.Image(.rgb)) ![]u8 {
    const out = try img.allocator.alloc(u8, img.pixels.len * 4);
    for (img.pixels, 0..) |p, i| {
        out[i * 4 + 0] = p.r;
        out[i * 4 + 1] = p.g;
        out[i * 4 + 2] = p.b;
        out[i * 4 + 3] = 255;
    }
    return out;
}
