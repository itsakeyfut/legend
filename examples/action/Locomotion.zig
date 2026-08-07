//! The player's ground movement: input-driven horizontal velocity and yaw,
//! gravity and jump, `moveAndSlide` against the world, the step-offset
//! payback, and the respawn safety net below the floor. Owns the jump latch
//! -- set by `beginFrame`'s input poll, spent by the first fixed step that
//! can act on it -- so a press between simulation steps is never lost.
//!
//! Exposes `moving`/`running_now`/`travelled`, this step's movement facts,
//! for `Character.chooseClip` and the clip-clock advance that follow it --
//! both need to know how the character actually moved, not just its raw
//! button state. Does NOT choose a clip itself.

const std = @import("std");
const legend = @import("legend");
const math = legend.math;
const collision = legend.collision;

const Character = @import("Character.zig");
const Frame = @import("Frame.zig");
const mathx = @import("mathx.zig");

const Self = @This();

jump_queued: bool = false,

// This step's movement, computed here and read by the clip-clock
// advance in Game.fixedUpdate (chooseClip recomputes its own copy --
// see its doc comment for why).
moving: bool = false,
running_now: bool = false,
// Ground distance actually covered this step (horizontal only,
// post-collision) -- what the clip-clock advance paces the run/walk
// cycle against.
travelled: f32 = 0,

pub fn fixedUpdate(self: *Self, char: *Character, frame: Frame) void {
    const mx = frame.input.value(.move_x);
    const mz = frame.input.value(.move_z);
    const moving = mx != 0 or mz != 0;
    const running_now = moving and frame.input.held(.sprint);
    self.moving = moving;
    self.running_now = running_now;

    const speed = if (running_now) frame.tuning.run_speed else frame.tuning.walk_speed;
    const before = char.pos;

    // Horizontal velocity is set outright from input rather than
    // accumulated: a character walks at the speed asked for and stops
    // when the key is let go, which is control, not physics.
    var horizontal = math.vec3(0, 0, 0);
    if (moving) {
        const cf = frame.camera.forward();
        const flat = math.vec3(cf.x(), 0, cf.z()).normalize();
        const dir = flat.scale(mz).add(frame.camera.right().scale(mx)).normalize();
        horizontal = dir.scale(speed);

        const target_yaw = std.math.atan2(dir.x(), dir.z());
        char.yaw = mathx.approachAngle(char.yaw, target_yaw, frame.tuning.turn_rate, frame.fixed_dt);
    }

    // Standing on something cancels the fall that put the character
    // there; without this, gravity would build a downward speed all the
    // while it stands, and the first step off a ledge would drop it
    // like a stone.
    var vy = char.vel.y();
    if (char.grounded and vy < 0) vy = 0;
    if (char.grounded and self.jump_queued) {
        vy = frame.tuning.jump_speed;
        self.jump_queued = false;
        char.grounded = false;
    }
    vy += frame.tuning.gravity * frame.fixed_dt;

    // Velocity carries the vertical motion between steps -- what makes
    // a jump rise and slow rather than teleport. The horizontal part is
    // rewritten from input each step; only y accumulates.
    char.vel = math.vec3(horizontal.x(), vy, horizontal.z());

    // One move, then pushed back out of whatever it entered.
    const result = collision.moveAndSlide(
        frame.controller,
        char.pos,
        char.vel.scale(frame.fixed_dt),
        char.grounded,
        frame.world,
    );
    char.pos = result.pos;
    char.grounded = result.grounded;
    // Take on the step's rise as a debt against what is drawn, never
    // more than one step's worth, and pay it down every step.
    char.step_offset = @min(char.step_offset + result.stepped, frame.controller.step_height);
    char.step_offset -= char.step_offset * @min(1.0, frame.tuning.step_smooth_rate * frame.fixed_dt);
    // Landing, or hitting a ceiling, ends the vertical motion: the
    // push-out has already removed the distance, and keeping the speed
    // would only fight the surface next step.
    if (result.grounded and char.vel.y() < 0) {
        char.vel = math.vec3(char.vel.x(), 0, char.vel.z());
    }

    if (char.pos.y() < frame.tuning.respawn_below) {
        char.pos = math.vec3(0, 2, 0);
        char.vel = math.vec3(0, 0, 0);
        // A teleport is not motion: start the interpolation over, or
        // the render would smear the character across the gap.
        char.prev_pos = char.pos;
        char.step_offset = 0;
    }

    // Only the ground covered counts toward the walk cycle. Falling is
    // distance too, and counting it would run the legs in mid-air.
    const moved = char.pos.sub(before);
    self.travelled = math.vec3(moved.x(), 0, moved.z()).length();
}
