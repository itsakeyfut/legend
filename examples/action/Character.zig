//! A character in the world: the unit gameplay acts on. The player and every
//! enemy share this type -- what differs is who drives it (input vs AI), not
//! what it is made of. The scene handles say how it is drawn; the kinematics
//! are its sim-space motion, kept one step back so the render can interpolate.

const legend = @import("legend");
const math = legend.math;
const Assets = legend.Assets;

const Locomotion = @import("Locomotion.zig");
const Combat = @import("Combat.zig");
const Reactions = @import("Reactions.zig");
const Frame = @import("Frame.zig");
const clips = @import("clips.zig");
const mathx = @import("mathx.zig");

// Scene binding: what the renderer draws for this character.
root: legend.ObjectHandle,
skeleton: ?legend.SkeletonHandle = null,
animator: ?legend.AnimatorHandle = null,

// Kinematics (sim space) plus one step of history, so the render can lerp
// from where the character was to where it now is.
pos: math.Vec3,
prev_pos: math.Vec3,
yaw: f32 = 0,
prev_yaw: f32 = 0,
vel: math.Vec3 = math.vec3(0, 0, 0),
grounded: bool = false,
// How far below its true position the character is currently drawn.
//
// A step-up moves the capsule a whole ledge's height in one step, which
// reads as a jolt however smoothly the rest is interpolated. Rather than
// slow the capsule down -- it must be on top of the step to stand there --
// the rise is subtracted from what is drawn and paid back over the next few
// frames. What the game simulates is unchanged; only the view lags.
step_offset: f32 = 0,

// Combat: what a hit lands on / takes off.
health: f32 = 100,

// Which clip means what, resolved once against the loaded rig. A model
// may not have them, so each is optional and the game falls back to
// what it has. Set only for the player -- the enemy's idle/hit/death
// lookups live on its own `Reactions` component instead.
clip_idle: ?usize = null,
clip_walk: ?usize = null,
clip_run: ?usize = null,

// Optional components: what drives this character, if anything does.
// The player gets `locomotion` and `combat`; the enemy gets
// `reactions` -- its idle/flinch/dead FSM. Neither side needs all
// three.
locomotion: ?Locomotion = null,
combat: ?Combat = null,
reactions: ?Reactions = null,

const Self = @This();

/// Save this step's pose before it is advanced, so the render can
/// interpolate toward the new one. Called at the top of a sim step.
pub fn carryHistory(self: *Self) void {
    self.prev_pos = self.pos;
    self.prev_yaw = self.yaw;
}

/// The drawn position, `alpha` of the way from the last sim pose to the
/// current one. Step-up offset is the caller's to subtract.
pub fn renderPos(self: Self, alpha: f32) math.Vec3 {
    return self.prev_pos.lerp(self.pos, alpha);
}

/// The drawn facing, taking the short way round the wrap.
pub fn renderYaw(self: Self, alpha: f32) f32 {
    return mathx.lerpAngle(self.prev_yaw, self.yaw, alpha);
}

/// Advance one of this character's clip clocks by `step` and loop it by the
/// clip's own length. The shared mechanism behind the player's locomotion
/// clock and an enemy's looping state clips. `clip` is the clip that clock
/// belongs to (anim.current / anim.previous); a null clip is a no-op. The
/// caller chooses `step` -- distance-based for the player, time-based for an
/// enemy -- and any non-looping case (a death pose held on its last frame)
/// stays with the caller.
pub fn advanceClipTime(self: Self, assets: *Assets, clip: ?usize, time: *f32, step: f32) void {
    const c = clip orelse return;
    const duration = clips.clipDuration(assets, self.skeleton, c);
    time.* += step;
    if (duration > 0) {
        while (time.* > duration) time.* -= duration;
    }
}

/// The attack -> run -> walk -> idle clip selection: attack overrides
/// locomotion while a swing is playing, then running, walking, idle
/// underneath -- the ordinary locomotion cycle. Reads this step's
/// *pre-swing* `combat.attack_time`: called before `Combat.fixedUpdate`'s
/// start-swing latch, so a freshly queued attack's clip begins on the
/// next fixed step, not this one (I5). `moving`/`running_now` are
/// recomputed from `frame.input` rather than read off `Locomotion` --
/// they're pure functions of this step's input, so recomputing them
/// here gives the same values Locomotion's own movement step just used,
/// without this needing to depend on Locomotion having run first.
pub fn chooseClip(self: *Self, combat: ?*const Combat, frame: Frame) void {
    const ah = self.animator orelse return;
    const anim = frame.scene.animator(ah) orelse return;

    if (combat) |c| {
        if (c.attack_time != null and c.attacks[c.attack_current].clip != null) {
            anim.play(c.attacks[c.attack_current].clip.?);
            return;
        }
    }

    const mx = frame.input.value(.move_x);
    const mz = frame.input.value(.move_z);
    const moving = mx != 0 or mz != 0;
    const running_now = moving and frame.input.held(.sprint);

    if (running_now and self.clip_run != null) {
        anim.play(self.clip_run.?);
    } else if (moving) {
        if (self.clip_walk) |w| anim.play(w);
    } else if (self.clip_idle) |i| {
        anim.play(i);
    } else {
        anim.stop();
    }
}
