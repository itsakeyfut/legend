//! GPU subsystem: Vulkan.

const context = @import("context.zig");
pub const Context = context.Context;

const device = @import("device.zig");
pub const Device = device.Device;
pub const QueueFamilies = device.QueueFamilies;

const swapchain = @import("swapchain.zig");
pub const Swapchain = swapchain.Swapchain;

const pipeline = @import("pipeline.zig");
pub const RenderPass = pipeline.RenderPass;
pub const Pipeline = pipeline.Pipeline;

const renderer = @import("renderer.zig");
pub const Renderer = renderer.Renderer;

const memory = @import("memory.zig");
pub const Buffer = memory.Buffer;
pub const Uploader = memory.Uploader;

const mesh = @import("mesh.zig");
pub const GpuMesh = mesh.GpuMesh;
pub const GpuVertex = mesh.GpuVertex;

const depth = @import("depth.zig");
pub const DepthBuffer = depth.DepthBuffer;

pub const DrawItem = renderer.DrawItem;
pub const PushConstants = pipeline.PushConstants;

test {
    @import("std").testing.refAllDecls(@This());
    _ = context;
    _ = device;
    _ = swapchain;
    _ = pipeline;
    _ = renderer;
    _ = memory;
    _ = mesh;
    _ = depth;
}
