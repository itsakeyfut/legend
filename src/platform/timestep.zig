//! Fixed timestep: the simulation advances in equal steps, decoupled from how
//! often the screen refreshes. Movement and, later, physics, run on this fixed
//! step so they behave the same at any frame rate -- the same jump reaches the
//! same height whether the machine renders 60 or 300 times a second.

const std = @import("std");

pub const FixedTimestep = struct {
    /// Seconds per simulation step. 1/60 by default -- the rate gameplay and
    /// physics run at, independent of render rate.
    fixed_dt: f32 = 1.0 / 60.0,

    /// Real frame times longer than this are clamped before they enter the
    /// accumulator. A stall -- a breakpoint, an alt-tab, a slow first frame --
    /// would otherwise leave a huge backlog the sim tries to burn down all at
    /// once, each catch-up step making the next frame slower still: the "spiral
    /// of death". Clamped, the sim simply falls behind real time instead.
    max_frame: f32 = 0.25,

    /// Unspent real time carried between frames, always less than one step once
    /// step() has drained it.
    accumulator: f32 = 0,

    /// Feed one real frame's duration, in seconds.
    pub fn addFrame(self: *FixedTimestep, frame_dt: f32) void {
        self.accumulator += @min(frame_dt, self.max_frame);
    }

    /// Drives the fixed loop: `while (ts.step()) simulate(ts.fixed_at);`. Each
    /// call consumes one step, returning false once the leftover is smaller
    /// than a whole step.
    pub fn step(self: *FixedTimestep) bool {
        if (self.accumulator < self.fixed_dt) return false;
        self.accumulator -= self.fixed_dt;
        return true;
    }

    /// How far the render sits between the last simulated state and the next,
    /// 0..1. Unused until render interpolation is added; exposed now so the
    /// loop can be shaped for it from the start.
    pub fn alpha(self: FixedTimestep) f32 {
        return self.accumulator / self.fixed_dt;
    }
};

test "accumulator yields whole steps and keeps the remainder" {
    var ts = FixedTimestep{ .fixed_dt = 0.1 };

    ts.addFrame(0.25); // 2 whole steps, 0.05 left over
    var steps: usize = 0;
    while (ts.step()) steps += 1;
    try std.testing.expectEqual(@as(usize, 2), steps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), ts.alpha(), 1e-6); // 0.05 / 0.1
}

test "a long stall is clamped, not accumulated" {
    var ts = FixedTimestep{ .fixed_dt = 0.1, .max_frame = 0.25 };

    ts.addFrame(5.0); // clamped to 0.25 -> only 2 steps, not 50
    var steps: usize = 0;
    while (ts.step()) steps += 1;
    try std.testing.expectEqual(@as(usize, 2), steps);
}
