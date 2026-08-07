//! The enemy's reaction state machine: idle until hit, a flinch when struck,
//! dead once health runs out. Owns its own clip lookups (idle/hit/death,
//! resolved once at load) and the flinch clip's duration, so it needs
//! nothing from `Game` but the shared `hitstop` clock, passed in each step
//! rather than owned -- decaying it stays `Game.tickHitstop`'s job.

const Character = @import("Character.zig");
const Frame = @import("Frame.zig");
const clips = @import("clips.zig");

/// The target's reactions: idle until hit, a flinch when struck, and dead once
/// health runs out -- after which it neither reacts nor is shoved again. A
/// clip's own length says when a flinch is over.
pub const TargetState = enum { idle, flinch, dead };

const Self = @This();

state: TargetState = .idle,
flinch_time: f32 = 0,
clip_idle: ?usize = null,
clip_hit: ?usize = null,
clip_death: ?usize = null,
clip_hit_dur: f32 = 0,

/// Picks and plays this step's clip (death outranks flinch outranks
/// idle, the same priority shape the player's attack-over-locomotion
/// uses), counts a flinch down while not frozen, and advances the
/// current clip's clock -- held during hitstop and once dead, where the
/// death clip instead clamps to its last frame rather than looping
/// (I2). Only `current` ever advances here: the enemy never blends from
/// a previous clip, so `previous_time` has nothing to do.
pub fn fixedUpdate(self: *Self, char: *Character, frame: Frame, hitstop: f32) void {
    const ah = char.animator orelse return;
    const anim = frame.scene.animator(ah) orelse return;

    switch (self.state) {
        .dead => {
            if (self.clip_death) |d| anim.play(d);
        },
        .flinch => {
            if (self.clip_hit) |h| anim.play(h);
            if (hitstop <= 0) {
                self.flinch_time -= frame.fixed_dt;
                if (self.flinch_time <= 0) self.state = .idle;
            }
        },
        .idle => {
            if (self.clip_idle) |i| anim.play(i);
        },
    }

    anim.advanceBlend(frame.fixed_dt, frame.tuning.blend_rate);
    // Death holds on its last frame; everything else loops. The freeze
    // pauses the clock the same as it does the player.
    if (hitstop <= 0 and self.state != .dead) {
        char.advanceClipTime(frame.assets, anim.current, &anim.current_time, frame.fixed_dt);
    } else if (self.state == .dead) {
        // Advance once to the end, then hold -- a corpse does not loop
        // back to standing.
        if (anim.current) |c| {
            const duration = clips.clipDuration(frame.assets, char.skeleton, c);
            if (duration > 0 and anim.current_time < duration) {
                anim.current_time = @min(anim.current_time + frame.fixed_dt, duration);
            }
        }
    }
}
