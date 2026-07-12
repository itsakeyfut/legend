//! Fiber subsystem: stackful coroutines.
//! The substrate for a future job system; not yet used by the renderer.
//! Carried over from the standalone `fiber` repository.

const fiber = @import("fiber.zig");

pub const Fiber = fiber.Fiber;
pub const State = fiber.State;
pub const yield = fiber.Fiber.yield;

test {
    @import("std").testing.refAllDecls(@This());
    _ = fiber;
}
