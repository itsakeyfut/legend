//! GPU subsystem: Vulkan.

const vk = @import("vk.zig");
pub const Error = vk.Error;

const device = @import("device.zig");
pub const Device = device.Device;
pub const QueueFamilies = device.QueueFamilies;

const swapchain = @import("swapchain.zig");
pub const Swapchain = swapchain.Swapchain;

const depth = @import("depth.zig");
pub const DepthBuffer = depth.DepthBuffer;

const memory = @import("memory.zig");
pub const Buffer = memory.Buffer;
pub const GpuImage = memory.GpuImage;
pub const Uploader = memory.Uploader;

const mesh = @import("mesh.zig");
pub const GpuMesh = mesh.GpuMesh;
pub const GpuVertex = mesh.GpuVertex;

const texture = @import("texture.zig");
pub const Sampler = texture.Sampler;
pub const TexturePool = texture.TexturePool;
pub const GpuTexture = texture.GpuTexture;

const pipeline = @import("pipeline.zig");
pub const RenderPass = pipeline.RenderPass;
pub const Pipeline = pipeline.Pipeline;
pub const PushConstants = pipeline.PushConstants;

const renderer = @import("renderer.zig");
pub const Renderer = renderer.Renderer;
pub const DrawItem = renderer.DrawItem;

const context = @import("context.zig");
pub const Context = context.Context;

test {
    @import("std").testing.refAllDecls(@This());
    _ = vk;
    _ = device;
    _ = swapchain;
    _ = depth;
    _ = memory;
    _ = mesh;
    _ = texture;
    _ = pipeline;
    _ = renderer;
    _ = context;
}
