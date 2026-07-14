//! Vulkan bring-up, complete: instance, validation, surface, device, swapchain,
//! Slang shader, pipeline, command buffers, synchronisation, and a draw loop.
//!
//! The triangle's vertices live in the shader and its colours are interpolated
//! by the rasterizer -- the same barycentric interpolation the software renderer
//! did by hand, now in silicon.
//!
//!   zig build run-triangle

const std = @import("std");
const legend = @import("legend");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const width: u32 = 960;
    const height: u32 = 640;

    var win = try legend.Window.initVulkan("LegendEngine - Vulkan", width, height);
    defer win.deinit();

    var ctx = try legend.gpu.Context.init(gpa, &win, width, height);
    defer ctx.deinit(&win);

    std.debug.print("gpu: {s}\n", .{ctx.device.deviceName()});
    std.debug.print("graphics queue family: {d}\n", .{ctx.device.families.graphics});
    std.debug.print("present queue family:  {d}\n", .{ctx.device.families.present});
    std.debug.print("swapchain: {d} images, {d}x{d}\n", .{
        ctx.swapchain.count,
        ctx.swapchain.extent.width,
        ctx.swapchain.extent.height,
    });

    while (true) {
        const input = win.pollInput();
        if (input.quit) break;
        try ctx.drawFrame();
    }
}
