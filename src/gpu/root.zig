//! GPU subsystem: Vulkan.

const context = @import("context.zig");
pub const Context = context.Context;

const device = @import("device.zig");
pub const Device = device.Device;
pub const QueueFamilies = device.QueueFamilies;

test {
    @import("std").testing.refAllDecls(@This());
    _ = context;
    _ = device;
}
