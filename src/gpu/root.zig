//! GPU subsystem: Vulkan.

const context = @import("context.zig");
pub const Context = context.Context;

test {
    @import("std").testing.refAllDecls(@This());
    _ = context;
}
