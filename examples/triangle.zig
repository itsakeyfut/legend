//! Vulkan bring-up, step 1: create an instance, switch on the validation
//! layers, and get a surface out of the window.
//!
//! Nothing is drawn yet. The point is to prove the plumbing: that the SDK
//! headers resolve, the loader links, validation is talking to us, and SDL can
//! hand Vulkan a surface. Everything after this builds on exactly these pieces.
//!
//!   zig build run-triangle

const std = @import("std");
const legend = @import("legend");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var win = try legend.Window.initVulkan("LegendEngine - Vulkan", 960, 640);
    defer win.deinit();

    var ctx = try legend.gpu.Context.init(gpa, &win);
    defer ctx.deinit(&win);

    std.debug.print("vulkan instance created\n", .{});
    std.debug.print("surface created\n", .{});
    std.debug.print("(window will be blank -- nothing is drawn yet)\n", .{});

    while (true) {
        const input = win.pollInput();
        if (input.quit) break;
        win.delay(16);
    }
}
