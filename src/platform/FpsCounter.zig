//! Frame timing.
//!
//! Averages over a fixed interval rather than reporting instantaneous values:
//! a single frame's duration is far too noisy to read off a title bar, and the
//! number that actually matters when optimising is the sustained one.

const std = @import("std");

const Self = @This();

/// How long to accumulate before publishing a new average
interval_ms: u64 = 500,

frames: u32 = 0,
accumulated_ms: u64 = 0,

/// Last published values. Zero until the first interval elapses.
fps: f32 = 0,
frame_ms: f32 = 0,

/// Needs one frame's duration in. Returns true when a fresh average became
/// available, which is the caller's cue to update the display.
pub fn tick(self: *Self, dt_ms: u64) bool {
    self.frames += 1;
    self.accumulated_ms += dt_ms;

    if (self.accumulated_ms < self.interval_ms) return false;

    const elapsed: f32 = @floatFromInt(self.accumulated_ms);
    const count: f32 = @floatFromInt(self.frames);
    self.fps = count * 1000.0 / elapsed;
    self.frame_ms = elapsed / count;

    self.frames = 0;
    self.accumulated_ms = 0;
    return true;
}

test "averages over the interval" {
    var counter = Self{ .interval_ms = 100 };

    // Nine frames at 10ms: still inside the interval.
    for (0..9) |_| try std.testing.expect(!counter.tick(10));

    // The tenth crosses it and publishes 100 fps / 10 ms.
    try std.testing.expect(counter.tick(10));
    try std.testing.expectApproxEqAbs(@as(f32, 100), counter.fps, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), counter.frame_ms, 0.01);

    // Counters reset for the next interval.
    try std.testing.expect(!counter.tick(10));
}
