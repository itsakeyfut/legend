//! Angle helpers: wrap-aware turning and interpolation.

const std = @import("std");

/// Turns `current` toward `target` at a rate, taking the short way round.
///
/// Angles wrap, so the naive difference can send a character the long way round
/// for a turn of a few degrees. Folding the difference into -pi..pi first is
/// what makes a turn from 179 to -179 degrees a two-degree step rather than a
/// 358-degree spin.
pub fn approachAngle(current: f32, target: f32, rate: f32, dt: f32) f32 {
    var diff = target - current;
    while (diff > std.math.pi) diff -= std.math.tau;
    while (diff < -std.math.pi) diff += std.math.tau;
    return current + diff * @min(1.0, rate * dt);
}

/// Interpolates between two angles by `t` in [0, 1], taking the short way round.
///
/// A plain lerp of angles sweeps the long way when the two straddle the +pi/-pi
/// seam -- 179 to -179 degrees would travel 358 degrees. Folding the difference
/// into -pi..pi first makes it the two-degree step it should be. This is what
/// keeps the interpolated facing from spinning as the character crosses due
/// south.
pub fn lerpAngle(a: f32, b: f32, t: f32) f32 {
    var diff = b - a;
    while (diff > std.math.pi) diff -= std.math.tau;
    while (diff < -std.math.pi) diff += std.math.tau;
    return a + diff * t;
}
