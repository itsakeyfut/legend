//! Vulkan bring-up: instance, validation layers, surface, physical/logical
//! device, and the swapchain.
//!
//! Nothing is drawn yet. The point is to prove the plumbing -- that the SDK
//! headers resolve, the loader links, validation is talking to us, SDL can hand
//! Vulkan a surface, and a GPU that can present to it has been found and
//! negotiated with. Everything after this builds on exactly these pieces.
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
    std.debug.print("(window will be blank -- nothing is drawn yet)\n", .{});

    while (true) {
        const input = win.pollInput();
        if (input.quit) break;
        win.delay(16);
    }
}
