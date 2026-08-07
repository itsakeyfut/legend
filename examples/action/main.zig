//! A character you can walk around, with a camera that follows.
//!
//! CesiumMan is rigged: its mesh carries per-vertex joints and weights, and the
//! file names a skeleton, so load_gltf routes it through the skinning pipeline
//! and buildDrawList poses it. What this example adds on top is the shape of a
//! game rather than a viewer -- input that means "walk", a camera that orbits
//! the character, and a second context (F1) that hands the same keys back to a
//! free-flying camera for looking at the scene.
//!
//! The character is a capsule moving through a handful of boxes: it falls, it
//! stands, it slides along walls, it walks up stairs and it jumps. The boxes are
//! written out here rather than derived from the rendered meshes -- collision
//! geometry is its own thing, and deriving it from art is a later convenience,
//! not a foundation.
//!
//! Animation is split the way the engine draws it: the simulation advances a
//! per-character Animator's clock in fixed steps, the pose it implies is
//! evaluated once a frame, and the draw only uploads the result. One rig, one
//! animator here -- but the seam is what lets a second character in.
//!
//!   zig build run-skinned
//!   zig build run-skinned -- path/to/model.glb

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const Camera = legend.Camera;
const gpu = legend.gpu;

const Assets = legend.Assets;
const Scene = legend.Scene;

const text = legend.text;
const font = legend.font;
const action = legend.action;
const collision = legend.collision;

const mathx = @import("mathx.zig");
const clips = @import("clips.zig");
const Tuning = @import("Tuning.zig");
const Frame = @import("Frame.zig");
const stage = @import("stage.zig");

/// What this example can be asked to do. The engine knows none of these names --
/// they are declared here, and the map is built around them.
const Action = enum {
    move_x,
    move_y,
    move_z,
    look_x,
    look_y,
    toggle_mouse,
    toggle_camera,
    sprint,
    jump,
    quit,
    attack_slice,
    attack_chop,
    attack_stab,
    toggle_collision,
    toggle_stats,
};

/// One melee attack as data: which clip plays, how long it runs, the window
/// within it the hitbox is live, and the shape and bite of that hitbox. Making
/// an attack a value rather than a pile of constants is what lets the player
/// carry several and pick between them -- and later chain them into combos.
const Attack = struct {
    clip: ?usize,
    duration: f32,
    window_start: f32,
    window_end: f32,
    reach: f32,
    radius: f32,
    damage: f32,
};

/// A character in the world: the unit gameplay acts on. The player and every
/// enemy share this type -- what differs is who drives it (input vs AI), not
/// what it is made of. The scene handles say how it is drawn; the kinematics
/// are its sim-space motion, kept one step back so the render can interpolate.
const Character = struct {
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
    fn carryHistory(self: *Self) void {
        self.prev_pos = self.pos;
        self.prev_yaw = self.yaw;
    }

    /// The drawn position, `alpha` of the way from the last sim pose to the
    /// current one. Step-up offset is the caller's to subtract.
    fn renderPos(self: Self, alpha: f32) math.Vec3 {
        return self.prev_pos.lerp(self.pos, alpha);
    }

    /// The drawn facing, taking the short way round the wrap.
    fn renderYaw(self: Self, alpha: f32) f32 {
        return mathx.lerpAngle(self.prev_yaw, self.yaw, alpha);
    }

    /// Advance one of this character's clip clocks by `step` and loop it by the
    /// clip's own length. The shared mechanism behind the player's locomotion
    /// clock and an enemy's looping state clips. `clip` is the clip that clock
    /// belongs to (anim.current / anim.previous); a null clip is a no-op. The
    /// caller chooses `step` -- distance-based for the player, time-based for an
    /// enemy -- and any non-looping case (a death pose held on its last frame)
    /// stays with the caller.
    fn advanceClipTime(self: Self, assets: *Assets, clip: ?usize, time: *f32, step: f32) void {
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
    fn chooseClip(self: *Self, combat: ?*const Combat, frame: Frame) void {
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
};

/// The player's ground movement: input-driven horizontal velocity and yaw,
/// gravity and jump, `moveAndSlide` against the world, the step-offset
/// payback, and the respawn safety net below the floor. Owns the jump latch
/// -- set by `beginFrame`'s input poll, spent by the first fixed step that
/// can act on it -- so a press between simulation steps is never lost.
///
/// Exposes `moving`/`running_now`/`travelled`, this step's movement facts,
/// for `Character.chooseClip` and the clip-clock advance that follow it --
/// both need to know how the character actually moved, not just its raw
/// button state. Does NOT choose a clip itself.
const Locomotion = struct {
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

    fn fixedUpdate(self: *Locomotion, char: *Character, frame: Frame) void {
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
};

/// The player's melee: the base attacks and their combo finishers (shared
/// data resolved once by `loadAttacks`), the weapon socket the sword rides,
/// and the swing/combo state machine. `fixedUpdate` starts a queued swing,
/// advances its clock (held during hitstop, I3), and carries a buffered
/// chain input across the swing boundary into the next link -- everything
/// except the hit test itself, which needs a target and so lives on `Game`
/// as `resolveCombat`, called right after this every step. `lateUpdate`
/// rides the sword on the hand bone.
const Combat = struct {
    attacks: [6]Attack,
    // The player's weapon, ridden on the hand bone.
    sword_root: ?legend.ObjectHandle = null,
    handslot_joint: ?usize = null,

    // The attack's own clock: null when idle, else seconds since the swing
    // began, advanced each sim step and cleared when the swing is over.
    attack_time: ?f32 = null,
    attack_current: usize = 0,
    // Set false while a swing is live, true once it has dealt its damage,
    // so the multi-frame hit window still only lands once.
    attack_spent: bool = false,
    attack_queued: bool = false,
    // The combo: which link of the fixed chain the next mouse-left swing
    // plays, and whether one was buffered during the current swing's
    // window.
    combo_step: usize = 0,
    combo_queued: bool = false,
    // Which finisher input was buffered at the branch (0=left,1=Q,2=E), and
    // the route chosen once we branch.
    combo_finish: usize = 0,
    combo_route: usize = 0,

    /// Start a queued swing, advance the running one, and carry a buffered
    /// chain link across the swing's end into the next one. `hitstop` is
    /// `Game.hitstop`, read here only -- decaying it stays Game's job. The
    /// hit test that used to live in this same block is now
    /// `Game.resolveCombat`.
    fn fixedUpdate(self: *Combat, char: *Character, frame: Frame, hitstop: f32) void {
        _ = char;

        // Start a swing if one is queued and none is running.
        if (self.attack_queued) {
            self.attack_queued = false;
            if (self.attack_time == null) {
                self.attack_time = 0;
                self.attack_spent = false;
            }
        }

        // Advance the swing, and end it when the motion is over.
        if (self.attack_time) |*t| {
            const attack = self.attacks[self.attack_current];
            if (hitstop <= 0) t.* += frame.fixed_dt;

            // The combo window: the back half of the swing. A left-click
            // buffered here chains into the next link when the swing ends.
            const combo_window = t.* >= attack.duration * 0.5;
            if (!combo_window) self.combo_queued = false; // too early: not a chain

            if (t.* >= attack.duration) {
                // Swing over. If a link was buffered in the window and the
                // chain has further to go, start the next link; otherwise
                // the combo ends and the next left-click starts fresh.
                if (self.combo_queued and self.combo_step + 1 < 3) {
                    // Advance the chain. On the branch step (into link 2,
                    // the finisher), the buffered input picks the route.
                    self.combo_step += 1;
                    if (self.combo_step == 2) self.combo_route = self.combo_finish;
                    self.attack_current = combo_routes[self.combo_route].chain[self.combo_step];
                    self.attack_time = 0;
                    self.attack_spent = false;
                    self.combo_queued = false;
                } else {
                    self.attack_time = null;
                    self.combo_step = 0;
                    self.combo_route = 0;
                    self.combo_queued = false;
                }
            }
        }
    }

    /// Ride the sword on the hand bone, every frame (not just the fixed
    /// step), so it tracks the interpolated render pose exactly like the
    /// character's own root does. The bone's world matrix is in the
    /// character's model space, so composing the character's own model
    /// matrix onto it puts the sword where the hand is in the world; the
    /// result is decomposed back to a Transform because that is what an
    /// Object carries.
    fn lateUpdate(self: *Combat, char: *Character, frame: Frame) void {
        const sroot = self.sword_root orelse return;
        const hj = self.handslot_joint orelse return;
        const ah = char.animator orelse return;
        const anim = frame.scene.animator(ah) orelse return;

        const render_pos = char.renderPos(frame.alpha);
        const render_yaw = char.renderYaw(frame.alpha);
        const smoothed_pos = render_pos.sub(math.vec3(0, char.step_offset, 0));

        const char_model = (legend.Transform{
            .position = smoothed_pos,
            .rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), render_yaw),
            .scale = math.vec3(frame.tuning.model_scale, frame.tuning.model_scale, frame.tuning.model_scale),
        }).matrix();
        const sword_world = char_model.mul(anim.world[hj]);
        if (frame.scene.object(sroot)) |sobj| {
            sobj.transform = legend.Transform.decompose(sword_world);
        }
    }
};

/// The point the current swing's hitbox extends from: the sword hand's
/// world position, if the rig names one and it's loaded and posed --
/// otherwise a fallback point on the chest. Shared by the hit test
/// (`Game.resolveCombat`) and the debug-draw hitbox (`Game.render`), so what
/// is drawn is what is tested (I6). Built from `char.pos`, the sim-space
/// position, not the smoothed render pos -- the hit test runs in the fixed
/// step, and the debug draw is deliberately kept consistent with it rather
/// than the interpolated one.
fn attackHitboxOrigin(char: *const Character, combat: *const Combat, frame: Frame) math.Vec3 {
    var origin = char.pos.add(math.vec3(0, 0.6, 0));
    if (combat.handslot_joint) |hj| {
        if (char.animator) |ah| {
            if (frame.scene.animator(ah)) |anim| {
                const char_model = (legend.Transform{
                    .position = char.pos,
                    .rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), char.yaw),
                    .scale = math.vec3(frame.tuning.model_scale, frame.tuning.model_scale, frame.tuning.model_scale),
                }).matrix();
                const bone_world = char_model.mul(anim.world[hj]);
                origin = legend.Transform.decompose(bone_world).position;
            }
        }
    }
    return origin;
}

/// The enemy's reaction state machine: idle until hit, a flinch when struck,
/// dead once health runs out. Owns its own clip lookups (idle/hit/death,
/// resolved once at load) and the flinch clip's duration, so it needs
/// nothing from `Game` but the shared `hitstop` clock, passed in each step
/// rather than owned -- decaying it stays `Game.tickHitstop`'s job.
const Reactions = struct {
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
    fn fixedUpdate(self: *Reactions, char: *Character, frame: Frame, hitstop: f32) void {
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
};

pub const Input = action.Map(Action);

/// Always active, underneath whatever else is pushed: the keys that mean the
/// same thing no matter what the game is doing.
const globals = Input.Context{
    .name = "globals",
    .bindings = &.{
        .{ .source = .{ .key = .escape }, .action = .quit },
        .{ .source = .{ .key = .tab }, .action = .toggle_mouse },
        .{ .source = .{ .key = .f1 }, .action = .toggle_camera },
    },
};

/// Playing: the keys walk the character. Space is a jump, not an ascent -- the
/// character leaves the ground under its own speed and gravity brings it back.
const gameplay = Input.Context{
    .name = "gameplay",
    .bindings = &.{
        .{ .source = .{ .key = .d }, .action = .move_x, .scale = 1 },
        .{ .source = .{ .key = .a }, .action = .move_x, .scale = -1 },
        .{ .source = .{ .key = .w }, .action = .move_z, .scale = 1 },
        .{ .source = .{ .key = .s }, .action = .move_z, .scale = -1 },
        .{ .source = .{ .mouse_button = .right }, .action = .sprint },
        .{ .source = .{ .key = .space }, .action = .jump },
        .{ .source = .{ .mouse_button = .left }, .action = .attack_slice },
        .{ .source = .{ .key = .q }, .action = .attack_chop },
        .{ .source = .{ .key = .e }, .action = .attack_stab },
        .{ .source = .mouse_x, .action = .look_x, .scale = 1 },
        .{ .source = .mouse_y, .action = .look_y, .scale = -1 },
        .{ .source = .{ .key = .f2 }, .action = .toggle_collision },
        .{ .source = .{ .key = .f3 }, .action = .toggle_stats },
    },
};

/// Inspecting the scene: the same keys, a different meaning. W flies the camera
/// rather than walking the character, and space and shift regain their up and
/// down. Swapped in for `gameplay` rather than stacked on top of it -- only one
/// of the two should ever be answering.
const free_camera = Input.Context{
    .name = "free camera",
    .bindings = &.{
        .{ .source = .{ .key = .d }, .action = .move_x, .scale = 1 },
        .{ .source = .{ .key = .a }, .action = .move_x, .scale = -1 },
        .{ .source = .{ .key = .space }, .action = .move_y, .scale = 1 },
        .{ .source = .{ .key = .lshift }, .action = .move_y, .scale = -1 },
        .{ .source = .{ .key = .w }, .action = .move_z, .scale = 1 },
        .{ .source = .{ .key = .s }, .action = .move_z, .scale = -1 },
        .{ .source = .mouse_x, .action = .look_x, .scale = 1 },
        // Screen y grows downward, and looking down should lower the pitch.
        .{ .source = .mouse_y, .action = .look_y, .scale = -1 },
    },
};

/// The target's reactions: idle until hit, a flinch when struck, and dead once
/// health runs out -- after which it neither reacts nor is shoved again. A
/// clip's own length says when a flinch is over.
const TargetState = enum { idle, flinch, dead };

/// One route through the combo: the three attacks (by index into
/// `Combat.attacks`) its links play, and which finisher input picks it.
const ComboRoute = struct { finish: usize, chain: [3]usize };

/// The combo routes: all share the Slice -> Chop intro, then branch on the
/// 3rd input into a different finisher. Add a route here and it just works.
/// finish picks the route at the branch (the 3rd press).
const combo_routes = [_]ComboRoute{
    .{ .finish = 0, .chain = .{ 0, 1, 3 } }, // left-left-LEFT: sweep
    .{ .finish = 1, .chain = .{ 0, 1, 4 } }, // left-left-Q:    heavy chop
    .{ .finish = 2, .chain = .{ 0, 1, 5 } }, // left-left-E:    heavy stab
};

/// Everything that persists across frames: the player and the enemy, the
/// tuning that shapes them, and what setup produced for each -- clip lookups,
/// the sword's attach point, the enemy's own reaction state. The loop reads
/// this instead of closing over a couple dozen locals.
const Game = struct {
    tuning: Tuning,

    player: Character,
    enemy: Character,

    // How long, in seconds, both sides freeze on a hit -- the pause that
    // gives a blow its weight. Counts down; while it runs, clocks and the
    // swing hold.
    hitstop: f32 = 0,
    // Whether F1 has swapped the loop into free-fly inspection mode.
    free_look: bool = false,

    // Borrowed engine handles the lifecycle methods below read every call.
    // Owned by `main` (which outlives `Game`); held here so `fixedUpdate` and
    // `lateUpdate` can reach them through `self` alone, the way their
    // signatures require.
    scene: *Scene,
    assets: *Assets,
    dbg: *legend.Debug,

    // The capsule the player collides as, and what it is allowed to walk on.
    // Fixed for the run, so a value copy is enough -- nothing ever mutates it.
    controller: collision.Controller = stage.controller,
    // Facing +Z at yaw pi/2, so the camera starts behind a character that
    // also faces +Z. Orbits the character while playing; free-flies (F1)
    // while inspecting.
    camera: Camera = .{ .yaw = std.math.pi / 2.0 },
    // Which keys mean what, and what was pressed/held/moved this frame.
    input: Input,

    fps: legend.FpsCounter = .{},
    title_buf: [160]u8 = undefined,
    last_ms: u64 = 0,
    // This frame's real elapsed time, stashed by beginFrame -- lateUpdate's
    // free-camera fly speed needs it too, and runs on the render clock, not
    // the fixed step.
    frame_dt: f32 = 0,
    // Runs the simulation in equal 1/60 s steps, decoupled from render rate.
    ts: legend.FixedTimestep = .{},

    // Per-frame draw scratch: filled by render(), never read between frames.
    items: [256]gpu.DrawItem = undefined,
    text_items: [512]gpu.TextItem = undefined,

    /// Loads the player, the stage, and the enemy, and bundles them with the
    /// tuning that drives them, plus the engine handles and per-run state the
    /// loop needs. Called once at startup.
    pub fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        assets: *Assets,
        scene: *Scene,
        dbg: *legend.Debug,
        model_path: []const u8,
    ) !Game {
        var tuning = Tuning{};
        // Fox is authored ~155 units long, so it needs shrinking hard;
        // KayKit is near life-size and needs almost none. A model's file
        // says nothing about the unit it was built in, so the game picks --
        // keyed off the path until asset metadata carries a scale.
        tuning.model_scale = if (std.mem.indexOf(u8, model_path, "kaykit") != null) 0.5 else 0.012;
        // The height a jump should reach, converted to the speed that
        // reaches it: v = sqrt(2 * g * h). Tuning the height is what a
        // designer wants to do; the speed is derived from it.
        const jump_height: f32 = 1.2;
        tuning.jump_speed = @sqrt(2.0 * -tuning.gravity * jump_height);

        // CesiumMan's texture is JPEG, which the engine doesn't decode;
        // nodes with no usable base-color texture fall back to this flat
        // tint over white.
        const fallback = math.vec3(0.8, 0.8, 0.85);

        const player_load = try loadPlayer(io, gpa, assets, scene, model_path, fallback, tuning.model_scale);
        try stage.buildStage(gpa, assets, scene);
        const enemy_load = try loadEnemy(io, gpa, assets, scene, model_path, fallback, tuning.model_scale);

        std.debug.print("loaded {s}\n", .{model_path});

        // Which keys mean what. Playing starts on `gameplay`; F1 swaps it
        // for `free_camera` (see the toggle_camera handling in beginFrame).
        var input = Input.init();
        input.push(&globals);
        input.push(&gameplay);

        // Give the player its components: locomotion (owns the jump latch),
        // and combat (the attacks setup resolved, the sword, the socket).
        // `reactions` stays null -- only the enemy needs it.
        var player = player_load.character;
        player.clip_idle = player_load.clip_idle;
        player.clip_walk = player_load.clip_walk;
        player.clip_run = player_load.clip_run;
        player.locomotion = Locomotion{};
        player.combat = Combat{
            .attacks = player_load.attacks,
            .sword_root = player_load.sword_root,
            .handslot_joint = player_load.handslot_joint,
        };

        // The enemy gets `reactions`: its idle/flinch/dead FSM, with the
        // clip lookups setup resolved against its own rig.
        var enemy = enemy_load.character;
        enemy.reactions = enemy_load.reactions;

        return Game{
            .tuning = tuning,
            .player = player,
            .enemy = enemy,
            .scene = scene,
            .assets = assets,
            .dbg = dbg,
            .input = input,
        };
    }

    /// Bundles the Game's handles plus this call's dt/fixed_dt/alpha into the
    /// `Frame` every phase below reads from. `fixedUpdate` never touches
    /// `alpha` (it isn't drawing); `render` doesn't advance any clock, so its
    /// `dt`/`fixed_dt` are along for the ride, unread.
    fn buildFrame(self: *Game, dt: f32, fixed_dt: f32, alpha: f32) Frame {
        return .{
            .scene = self.scene,
            .assets = self.assets,
            .input = &self.input,
            .camera = &self.camera,
            .world = &stage.world,
            .controller = self.controller,
            .dbg = self.dbg,
            .dt = dt,
            .fixed_dt = fixed_dt,
            .alpha = alpha,
            .tuning = &self.tuning,
        };
    }

    /// Whether the loop should keep going. Polls the window and folds the
    /// result into input -- the same poll-then-check the old inline loop did
    /// right before its own `if (quit) break;` -- so a quit request stops the
    /// loop before beginFrame, the fixed step, or a render ever run again for
    /// this frame, same as before.
    pub fn running(self: *Game, win: *legend.Window) bool {
        const raw = win.poll();
        self.input.update(raw);
        return !(raw.quit or self.input.pressed(.quit));
    }

    /// Everything driven by the render clock rather than the fixed step: the
    /// frame timer and window title, the mouse-capture/free-cam toggles,
    /// jump and attack input latches (spent later, in fixedUpdate), and
    /// pointing the camera. `running` already polled and updated input this
    /// frame; this reads what that produced. Returns this frame's real
    /// elapsed time, which is also what feeds the fixed-step accumulator.
    pub fn beginFrame(self: *Game, win: *legend.Window) f32 {
        // -- render clock: once per frame, on real elapsed time ------------
        const now_ms = win.ticks();
        const elapsed_ms = now_ms - self.last_ms;
        const frame_dt = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
        self.last_ms = now_ms;
        self.frame_dt = frame_dt;

        if (self.fps.tick(elapsed_ms)) {
            const title = std.fmt.bufPrintZ(
                &self.title_buf,
                "LegendEngine - Skinned | {d:.1} fps",
                .{self.fps.fps},
            ) catch "LegendEngine - Skinned";
            win.setTitle(title);
        }

        if (self.input.pressed(.toggle_mouse)) win.setMouseCaptured(!win.isMouseCaptured());
        if (self.input.pressed(.toggle_camera)) {
            self.free_look = !self.free_look;
            self.input.replaceTop(if (self.free_look) &free_camera else &gameplay);
        }
        // A press is an event on the render clock; the simulation reads the latch.
        if (self.input.pressed(.jump)) self.player.locomotion.?.jump_queued = true;
        // Attack inputs. Out of combat each starts its own attack; during a combo
        // the press is buffered as the branch choice (which finisher).
        if (self.player.combat) |*combat| {
            if (self.input.pressed(.attack_slice)) {
                if (combat.attack_time == null) {
                    combat.combo_step = 0;
                    combat.combo_route = 0; // default route until a branch input says otherwise
                    combat.attack_current = combo_routes[0].chain[0];
                    combat.attack_queued = true;
                } else {
                    combat.combo_queued = true;
                    combat.combo_finish = 0; // left = route with finish 0
                }
            }
            if (self.input.pressed(.attack_chop)) {
                if (combat.attack_time == null) {
                    combat.attack_queued = true;
                    combat.attack_current = 1; // single Chop out of combat
                } else {
                    combat.combo_queued = true;
                    combat.combo_finish = 1; // Q = route with finish 1
                }
            }
            if (self.input.pressed(.attack_stab)) {
                if (combat.attack_time == null) {
                    combat.attack_queued = true;
                    combat.attack_current = 2; // single Stab out of combat
                } else {
                    combat.combo_queued = true;
                    combat.combo_finish = 2; // E = route with finish 2
                }
            }
        }

        if (self.input.pressed(.toggle_collision)) self.dbg.show_collision = !self.dbg.show_collision;
        if (self.input.pressed(.toggle_stats)) self.dbg.show_stats = !self.dbg.show_stats;

        // Looking turns the camera in both modes: orbiting the character while
        // playing, aiming the free camera while inspecting. Presentation, so it
        // runs on the render clock -- as responsive as the screen refreshes.
        self.camera.look(
            self.input.value(.look_x) * self.tuning.mouse_sensitivity,
            self.input.value(.look_y) * self.tuning.mouse_sensitivity,
        );

        // -- simulation: zero or more equal fixed steps --------------------
        // Input was polled once above; every step this frame reads that same
        // snapshot. Movement, gravity and the animation clock advance in
        // fixedUpdate so they behave the same at any frame rate.
        self.ts.addFrame(frame_dt);

        return frame_dt;
    }

    /// One equal 1/60 s simulation step. Carries history, then -- unless
    /// free look has taken the input over -- moves the player
    /// (`Locomotion.fixedUpdate`), picks its clip (`chooseClip`, reading
    /// this step's pre-swing combat state, I5), advances its clip clocks,
    /// advances its swing/combo timing (`Combat.fixedUpdate`), and resolves
    /// a landed hit (`resolveCombat`) -- in that order. Then the enemy's
    /// `Reactions.fixedUpdate` runs unconditionally, reading whatever
    /// reaction state the block above just set on this same step. Then
    /// `tickHitstop` decays hitstop and, once it has, slides the enemy's
    /// knockback -- also unconditional. `dt` is this frame's real elapsed
    /// time, carried into the `Frame` bundle for parity with the other
    /// phases; the step math below reads `frame.fixed_dt` throughout, same
    /// as the old loop's `ts.fixed_dt`.
    pub fn fixedUpdate(self: *Game, dt: f32) void {
        const frame = self.buildFrame(dt, self.ts.fixed_dt, 0);

        // Carry the current pose back one step before advancing it, so the
        // render below can interpolate from where the character was to where
        // it now is. Done every step and in either mode, so the previous
        // pose is always exactly one step behind the current one.
        self.player.carryHistory();
        self.enemy.carryHistory();

        if (!self.free_look) {
            self.player.locomotion.?.fixedUpdate(&self.player, frame);

            // Attack overrides locomotion: while a swing is playing, the
            // swing is what shows. chooseClip runs BEFORE combat.fixedUpdate
            // below starts a newly-queued swing, so it reads this step's
            // *pre-swing* attack_time -- a freshly queued attack's clip
            // begins on the next fixed step, not this one (I5).
            self.player.chooseClip(if (self.player.combat) |*c| c else null, frame);

            // The clip's clock advances while the character moves; its own
            // length decides when it loops. Standing still holds the bind
            // pose, which is not an idle animation -- it is the absence of
            // one, and the honest placeholder until there is a second clip
            // to switch to. The pose these times imply is evaluated once a
            // frame, after the loop -- here the simulation only sets clocks.
            // Not hitstop-gated (I3).
            if (self.player.animator) |ah| {
                if (frame.scene.animator(ah)) |anim| {
                    anim.advanceBlend(frame.fixed_dt, frame.tuning.blend_rate);

                    // Each clip is built for its own pace, so the ground
                    // covered is divided by the speed that clip assumes --
                    // not by one shared number. Get this wrong and the run
                    // skates while the walk is fine, or the reverse.
                    if (anim.current) |_| {
                        const loc = &self.player.locomotion.?;
                        const pace = if (loc.running_now) frame.tuning.run_clip_speed else frame.tuning.clip_speed;
                        const step = if (loc.moving and pace > 0) loc.travelled / pace else frame.fixed_dt;
                        self.player.advanceClipTime(frame.assets, anim.current, &anim.current_time, step);
                    }
                    self.player.advanceClipTime(frame.assets, anim.previous, &anim.previous_time, frame.fixed_dt);
                }
            }

            // Swing/combo timing (I3: swing-clock advance held during
            // hitstop). The hit test itself is resolveCombat, right below --
            // it reads the state this just updated, same step.
            self.player.combat.?.fixedUpdate(&self.player, frame, self.hitstop);
            self.resolveCombat(&self.player, &.{&self.enemy}, frame);
        }

        // The enemy has no controller driving it -- it idles, flinches, and
        // dies, but isn't steered. Its own component ticks its FSM and clip
        // clock here, on the same fixed step, unconditional on free_look
        // (I4) and reading whatever reaction state resolveCombat set above,
        // same step. Advancing its clock here is also what proves two
        // animators tick on independent clocks (the player's driven by
        // distance travelled, this one by time).
        self.enemy.reactions.?.fixedUpdate(&self.enemy, frame, self.hitstop);
        // Count the freeze down and, once it's run out, slide the
        // knockback -- also unconditional on free_look.
        self.tickHitstop(frame.fixed_dt);
    }

    /// Decays `hitstop` toward zero, and once it has, slides the enemy
    /// along its knockback velocity and bleeds that velocity off. While
    /// hitstop is still running, nothing else has advanced this step
    /// either -- `Reactions.fixedUpdate`, called just before this, held its
    /// clip clock on the same guard. `dt` is `frame.fixed_dt` at the call
    /// site.
    fn tickHitstop(self: *Game, dt: f32) void {
        if (self.hitstop > 0) {
            self.hitstop = @max(0, self.hitstop - dt);
        } else if (self.enemy.reactions.?.state != .dead) {
            // Slide the target along its velocity, then bleed the
            // velocity off. moveAndSlide means a wall or a stair stops
            // it, the same as it stops the player.
            const result = collision.moveAndSlide(
                self.controller,
                self.enemy.pos,
                self.enemy.vel.scale(dt),
                true,
                &stage.world,
            );
            self.enemy.pos = result.pos;
            const decay = @max(0.0, 1.0 - self.tuning.knockback_damping * dt);
            self.enemy.vel = self.enemy.vel.scale(decay);
        }
    }

    /// The hit test: does `attacker`'s current swing connect with any of
    /// `targets` this step? Called right after `Combat.fixedUpdate` has
    /// advanced the swing clock (and run the combo window/transition), so
    /// `combat.attack_time`/`window_start`/`window_end` already reflect this
    /// step's state -- the window always closes well before a swing's
    /// duration for every attack in `loadAttacks`, so whether the combo
    /// transition ran first or the hit test did changes nothing observable
    /// (see the report for the full argument). A swing lands at most once:
    /// `attack_spent` (cleared whenever a swing starts) is what keeps a
    /// multi-frame window from hitting every frame it's live, and this stops
    /// at the first target hit. On a landed hit, writes the target's
    /// health/velocity, starts hitstop, marks the swing spent, and
    /// transitions `target.reactions`.
    fn resolveCombat(self: *Game, attacker: *Character, targets: []const *Character, frame: Frame) void {
        if (attacker.combat == null) return;
        const combat = &attacker.combat.?;
        const t = combat.attack_time orelse return;
        if (combat.attack_spent) return;

        const attack = combat.attacks[combat.attack_current];
        const live = t >= attack.window_start and t <= attack.window_end;
        if (!live) return;

        // The hitbox rides the sword hand: take the hand bone's world
        // position -- the same bone the sword is parented to -- so the
        // swing lands where the blade is, not at a fixed point on the
        // chest. If the bone is unavailable it falls back to the chest.
        // Orientation is still the facing for now; the blade's own tilt is
        // a later step.
        const facing = math.vec3(std.math.sin(attacker.yaw), 0, std.math.cos(attacker.yaw));
        const origin = attackHitboxOrigin(attacker, combat, frame);
        const hitbox = collision.Capsule{
            .a = origin,
            .b = origin.add(facing.scale(attack.reach)),
            .radius = attack.radius,
        };

        for (targets) |target| {
            const hurtbox = collision.Capsule{
                .a = target.pos.add(math.vec3(0, frame.tuning.hurt_radius, 0)),
                .b = target.pos.add(math.vec3(0, frame.tuning.hurt_height - frame.tuning.hurt_radius, 0)),
                .radius = frame.tuning.hurt_radius,
            };
            if (collision.capsuleVsCapsule(hitbox, hurtbox)) {
                target.health = @max(0, target.health - attack.damage);
                combat.attack_spent = true;
                self.hitstop = frame.tuning.hitstop_duration;
                target.vel = facing.scale(frame.tuning.knockback_speed);
                // Health gone -> fall and stay down; otherwise flinch, for
                // as long as the flinch clip runs.
                if (target.health <= 0) {
                    target.reactions.?.state = .dead;
                } else {
                    target.reactions.?.state = .flinch;
                    target.reactions.?.flinch_time = target.reactions.?.clip_hit_dur;
                }
                return; // a swing lands at most once
            }
        }
    }

    /// The update phase: bring every animated character's pose up to date
    /// once, after the simulation has finished advancing their clocks, then
    /// reflect the interpolated pose -- fly the free camera, or write the
    /// player/sword/enemy transforms and the follow camera. `alpha` is how
    /// far the render sits between the last two simulated poses, 0..1.
    pub fn lateUpdate(self: *Game, alpha: f32) void {
        const frame = self.buildFrame(self.frame_dt, self.ts.fixed_dt, alpha);

        frame.scene.evaluateAnimators(frame.assets);

        // How far the render sits between the last two simulated poses, 0..1.
        // Drawing the blend between them is what turns a position that only
        // changes 60 times a second into motion smooth at any refresh rate.
        const render_pos = self.player.renderPos(alpha);
        const render_yaw = self.player.renderYaw(alpha);
        const smoothed_pos = render_pos.sub(math.vec3(0, self.player.step_offset, 0));

        // -- presentation: reflect the interpolated pose --------------------
        if (self.free_look) {
            // The free camera is a debug tool, not gameplay -- move it on the
            // render clock so inspection stays smooth.
            frame.camera.move(
                frame.input.value(.move_x) * frame.tuning.fly_speed * frame.dt,
                frame.input.value(.move_y) * frame.tuning.fly_speed * frame.dt,
                frame.input.value(.move_z) * frame.tuning.fly_speed * frame.dt,
            );
        } else {
            // Draw the character at the interpolated pose, not the raw sim
            // state. (Scale was set once before the loop and never changes.)
            if (frame.scene.object(self.player.root)) |obj| {
                obj.transform.position = smoothed_pos;
                obj.transform.rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), render_yaw);
            }
            // Ride the sword on the hand bone (I11): every frame, not just
            // the fixed step, so it tracks the interpolated pose exactly
            // like the character's own root does.
            if (self.player.combat) |*combat| combat.lateUpdate(&self.player, frame);
            // The target's drawn position follows its knockback, interpolated
            // the same way the player's is (A6) -- smoother than drawing the
            // raw sim position, and otherwise unchanged. Its facing and scale
            // were set once and do not change, so only position is written.
            if (frame.scene.object(self.enemy.root)) |obj| obj.transform.position = self.enemy.renderPos(alpha);

            // The camera hangs behind wherever it is aimed, a fixed distance
            // from the character. It tracks the same smoothed position the
            // character is drawn at, so the two never disagree.
            const focus = smoothed_pos.add(math.vec3(0, frame.tuning.focus_height, 0));
            frame.camera.position = focus.sub(frame.camera.forward().scale(frame.tuning.follow_distance));
        }
    }

    /// Builds this frame's draw list, the HUD overlay, and the debug-collision
    /// lines, then submits them. The debug attack-hitbox is rebuilt from the
    /// same `attackHitboxOrigin` helper the hit test (`resolveCombat`) uses
    /// (I6), so what is drawn is what is tested.
    pub fn render(self: *Game, gpu_ctx: *gpu.Context, atlas: *gpu.GpuTexture) !void {
        const frame = self.buildFrame(self.frame_dt, self.ts.fixed_dt, self.ts.alpha());

        const aspect = @as(f32, @floatFromInt(gpu_ctx.swapchain.extent.width)) /
            @as(f32, @floatFromInt(gpu_ctx.swapchain.extent.height));

        const draw = try legend.buildDrawList(frame.scene, frame.assets, gpu_ctx, self.camera, aspect, &self.items);

        // -- debug overlay -------------------------------------------------
        const screen_w: f32 = @floatFromInt(gpu_ctx.swapchain.extent.width);
        const screen_h: f32 = @floatFromInt(gpu_ctx.swapchain.extent.height);

        var overlay_buf: [320]u8 = undefined;
        const overlay = std.fmt.bufPrint(&overlay_buf,
            \\FPS {d:.0}
            \\MODE {s}
            \\POS {d:.1} {d:.1} {d:.1}
            \\VY {d:.1} {s} SM {d:.2}
            \\CLIP {s} B {d:.2}
            \\HP {d:.0} ATK {s}
        , .{
            self.fps.fps,
            if (self.free_look) "FREE CAM" else "PLAY",
            self.player.pos.x(),
            self.player.pos.y(),
            self.player.pos.z(),
            self.player.vel.y(),
            if (self.player.grounded) "GROUND" else "AIR",
            self.player.step_offset,
            blk: {
                if (self.player.animator) |ah| {
                    if (frame.scene.animator(ah)) |a| {
                        if (a.current) |c| break :blk clips.clipName(frame.assets, self.player.skeleton, c);
                    }
                }
                break :blk "REST";
            },
            blk: {
                if (self.player.animator) |ah| {
                    if (frame.scene.animator(ah)) |a| break :blk a.blend;
                }
                break :blk @as(f32, 0);
            },
            self.enemy.health,
            blk: {
                if (self.player.combat) |c| {
                    break :blk if (c.attack_time != null) "SWING" else "-";
                }
                break :blk "-";
            },
        }) catch "";

        const text_count = if (frame.dbg.show_stats)
            text.layout(
                &self.text_items,
                atlas.set,
                screen_w,
                screen_h,
                8,
                8,
                2,
                text.yellow,
                overlay,
            )
        else
            0;

        const vp = self.camera.viewProjection(aspect);
        const line_vp = legend.LinePush{
            .vp0 = vp.column(0).v,
            .vp1 = vp.column(1).v,
            .vp2 = vp.column(2).v,
            .vp3 = vp.column(3).v,
        };

        frame.dbg.clear();
        if (frame.dbg.show_collision) {
            // The world's collision boxes, blue. Everything the character is
            // tested against -- walls, steps, the platform -- made visible, the
            // way UE's `show Collision` draws the static world. The floor (box 0)
            // is skipped: it coincides with the ground quad and only clutters.
            for (frame.world[1..]) |box| {
                frame.dbg.aabb(box, math.vec3(0.3, 0.5, 1.0));
            }
            // The target's hurt volume, always. Green: what a hit lands on.
            const hurtbox = collision.Capsule{
                .a = self.enemy.pos.add(math.vec3(0, frame.tuning.hurt_radius, 0)),
                .b = self.enemy.pos.add(math.vec3(0, frame.tuning.hurt_height - frame.tuning.hurt_radius, 0)),
                .radius = frame.tuning.hurt_radius,
            };
            frame.dbg.capsule(hurtbox, math.vec3(0.2, 1, 0.2));
            // The player's facing, cyan: an arrow from the chest forward.
            const facing_dir = math.vec3(std.math.sin(self.player.yaw), 0, std.math.cos(self.player.yaw));
            const chest = self.player.pos.add(math.vec3(0, 0.9, 0));
            frame.dbg.arrow(chest, chest.add(facing_dir.scale(1.5)), math.vec3(0, 0.8, 1));

            // The attack's hitbox, red, only while a swing is live. Rebuilt from
            // the same hand-bone origin the hit test uses (attackHitboxOrigin),
            // so what is drawn is what is tested (I6).
            if (self.player.combat) |*combat| {
                if (combat.attack_time != null) {
                    const attack = combat.attacks[combat.attack_current];
                    const facing = math.vec3(std.math.sin(self.player.yaw), 0, std.math.cos(self.player.yaw));
                    const origin = attackHitboxOrigin(&self.player, combat, frame);
                    const hitbox = collision.Capsule{
                        .a = origin,
                        .b = origin.add(facing.scale(attack.reach)),
                        .radius = attack.radius,
                    };
                    frame.dbg.capsule(hitbox, math.vec3(1, 0.2, 0.2));
                }
            }
        }

        try gpu_ctx.drawFrame(draw.items, draw.shadow_set, self.text_items[0..text_count], frame.dbg.lines(), line_vp);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const model_path: []const u8 = if (args.len >= 2) args[1] else "assets/gltf/kaykit/Characters/Knight.glb";

    const width: u32 = 960;
    const height: u32 = 640;

    var win = try legend.Window.init("LegendEngine - Skinned", width, height);
    defer win.deinit();

    var gpu_ctx = try gpu.Context.init(gpa, &win, width, height);
    defer gpu_ctx.deinit(&win);

    var assets = try Assets.init(gpa, &gpu_ctx);
    defer assets.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit();

    // Debug-draw lines go into a buffer this loop owns and reuses -- no
    // per-frame allocation, the same shape the draw list uses.
    var line_buf: [legend.max_line_vertices]legend.LineVertex = undefined;
    var dbg = legend.Debug.init(&line_buf);

    // The font atlas: white glyphs in the alpha channel, uploaded like any
    // other texture. One upload at startup, then it just sits there.
    const atlas_pixels = try font.buildAtlas(gpa);
    defer gpa.free(atlas_pixels);
    var atlas = try gpu_ctx.uploadTexture(atlas_pixels, font.atlas_size, font.atlas_size);
    defer atlas.deinit();

    // Everything gameplay: the player, the enemy, the stage, the tuning that
    // shapes them, and the loop-owned engine handles (camera/input/controller/
    // fps/ts) the lifecycle methods below drive. See `Game.start` for what
    // setup involves.
    var game = try Game.start(io, gpa, &assets, &scene, &dbg, model_path);
    // A one-time window side effect, not game state -- `Game.start` never
    // sees `win`, so this stays here, the same as the original single call.
    win.setMouseCaptured(true);
    game.last_ms = win.ticks();

    while (game.running(&win)) {
        const dt = game.beginFrame(&win);
        while (game.ts.step()) game.fixedUpdate(dt);
        game.lateUpdate(game.ts.alpha());
        try game.render(&gpu_ctx, &atlas);
    }

    gpu_ctx.waitIdle();
}

/// Bundle returned by `loadPlayer`: the character plus everything setup
/// resolved for it (clip lookups, attacks, the sword).
const PlayerLoad = struct {
    character: Character,
    clip_idle: ?usize,
    clip_walk: ?usize,
    clip_run: ?usize,
    attacks: [6]Attack,
    sword_root: ?legend.ObjectHandle,
    handslot_joint: ?usize,
};

/// Loads the player model, binds its clips, builds its attacks, gives it an
/// animator, and loads the sword that rides its hand bone.
fn loadPlayer(
    io: std.Io,
    gpa: std.mem.Allocator,
    assets: *Assets,
    scene: *Scene,
    model_path: []const u8,
    fallback: math.Vec3,
    model_scale: f32,
) !PlayerLoad {
    const model = try legend.load_gltf.load(io, gpa, assets, scene, fallback, model_path);
    // The player: an Object with a skeleton, driven by input. The engine has no
    // Player type -- a character is a Character (game code), and what moves it is
    // the loop below.
    var player = Character{
        .root = model.root,
        .skeleton = model.skeleton,
        // animator is filled in once it is created, below.
        .pos = math.vec3(0, 2, 0),
        .prev_pos = math.vec3(0, 2, 0),
    };

    // KayKit ships the body and its animations in separate files -- the body glb
    // carries no clips -- so pull the shared animation sets in and bind them to
    // the rig by name, the way a character and its animations are separate assets
    // in UE and Unity.
    if (player.skeleton) |sk| clips.loadKayKitClips(io, gpa, assets, sk);

    // Which clip means what, resolved once. A model may not have them -- the
    // engine has no idea what a walk is, and neither file is obliged to name
    // one -- so each is optional and the game falls back to what it has.
    var clip_idle: ?usize = null;
    var clip_walk: ?usize = null;
    var clip_run: ?usize = null;
    var attacks: [6]Attack = undefined;
    if (player.skeleton) |sk| {
        if (assets.skeleton(sk)) |skel| {
            clip_idle = skel.clipByName("Survey") orelse skel.clipByName("Idle_A");
            clip_walk = skel.clipByName("Walk") orelse skel.clipByName("Walking_A");
            clip_run = skel.clipByName("Run") orelse skel.clipByName("Running_A");
            attacks = loadAttacks(skel);
            for (skel.clips) |clip| {
                std.debug.print("  {s} ({d:.2}s)\n", .{ clip.name, clip.duration });
            }
        }
    }

    // The character's own playback. The rig is shared; this is where this
    // character is in its stride. The skinned mesh -- and so the skeleton -- sits on a child
    // of the model root, and the animator has to go on that same object, or the
    // draw would find a skinned mesh with no palette and tear it apart.
    if (player.skeleton) |sk| {
        if (assets.skeleton(sk)) |rig| {
            // One animator, shared by every mesh on this rig -- a KayKit body is
            // nine meshes and they must pose as one character, not nine.
            const handle = try scene.addAnimator(gpa, rig);
            _ = scene.setAnimatorForSkeleton(sk, handle);
            player.animator = handle;
        }
    }

    // The player's weapon: a separate model, moved each frame to ride the hand
    // bone. handslot.r is KayKit's socket joint at the right hand; the sword was
    // authored to sit right when parented there. Loaded once, followed forever.
    var sword_root: ?legend.ObjectHandle = null;
    var handslot_joint: ?usize = null;
    {
        const sword = legend.load_gltf.load(io, gpa, assets, scene, fallback, "assets/gltf/kaykit/Weapons/sword_1handed.gltf") catch |err| blk: {
            std.debug.print("no sword: {}\n", .{err});
            break :blk null;
        };
        if (sword) |s| {
            sword_root = s.root;
        }
        if (player.skeleton) |sk| {
            if (assets.skeleton(sk)) |skel| {
                handslot_joint = skel.jointForName("handslot.r");
                std.debug.print("handslot.r joint = {any}\n", .{handslot_joint});
            }
        }
    }

    // The model's scale is fixed, so set it once rather than every frame.
    if (scene.object(player.root)) |obj| {
        obj.transform.scale = math.vec3(model_scale, model_scale, model_scale);
    }

    return .{
        .character = player,
        .clip_idle = clip_idle,
        .clip_walk = clip_walk,
        .clip_run = clip_run,
        .attacks = attacks,
        .sword_root = sword_root,
        .handslot_joint = handslot_joint,
    };
}

/// The three base attacks and their combo finishers, resolved against a rig's
/// clips. Same KayKit clips already bound to the rig; only the hit windows,
/// reach, and damage are ours to set -- the same motion becomes a light quick
/// slice or a slow long stab by how the hitbox is placed on it.
fn loadAttacks(skel: anytype) [6]Attack {
    var attacks: [6]Attack = undefined;
    attacks[0] = .{ // Slice: the standard swing.
        .clip = skel.clipByName("Melee_1H_Attack_Slice_Diagonal"),
        .duration = 1.0,
        .window_start = 0.4,
        .window_end = 0.6,
        .reach = 1.0,
        .radius = 0.4,
        .damage = 25,
    };
    attacks[1] = .{ // Chop: slower, shorter, heavier
        .clip = skel.clipByName("Melee_1H_Attack_Chop"),
        .duration = 1.07,
        .window_start = 0.45,
        .window_end = 0.65,
        .reach = 0.9,
        .radius = 0.45,
        .damage = 35,
    };
    attacks[2] = .{ // Stab: slow, long reach, thin.
        .clip = skel.clipByName("Melee_1H_Attack_Stab"),
        .duration = 1.6,
        .window_start = 0.5,
        .window_end = 0.7,
        .reach = 1.4,
        .radius = 0.3,
        .damage = 20,
    };
    // Combo finishers: stronger versions that only appear as the last
    // link of a combo route. Same 1H clips, but ~1.5x the intro Slice's
    // damage and tuned reach -- the payoff for landing the chain.
    attacks[3] = .{ // Horizontal sweep finisher: wide.
        .clip = skel.clipByName("Melee_1H_Attack_Slice_Horizontal"),
        .duration = 1.37,
        .window_start = 0.45,
        .window_end = 0.7,
        .reach = 1.2,
        .radius = 0.55,
        .damage = 38,
    };
    attacks[4] = .{ // Heavy chop finisher.
        .clip = skel.clipByName("Melee_1H_Attack_Chop"),
        .duration = 1.07,
        .window_start = 0.45,
        .window_end = 0.65,
        .reach = 1.0,
        .radius = 0.5,
        .damage = 40,
    };
    attacks[5] = .{ // Heavy stab finisher: long.
        .clip = skel.clipByName("Melee_1H_Attack_Stab"),
        .duration = 1.6,
        .window_start = 0.5,
        .window_end = 0.7,
        .reach = 1.6,
        .radius = 0.35,
        .damage = 38,
    };
    return attacks;
}

/// Bundle returned by `loadEnemy`: the character plus its `Reactions`
/// component, the clip lookups (idle/hit/death) resolved once against its
/// own rig.
const EnemyLoad = struct {
    character: Character,
    reactions: Reactions,
};

/// Loads a second copy of the player's model to stand in as the enemy
/// target: its own object, skeleton, and animator, so it can hold a
/// different clip at a different moment than the player. It stands and loops
/// -- no movement or control, only its own clock, ticked in the sim loop.
fn loadEnemy(
    io: std.Io,
    gpa: std.mem.Allocator,
    assets: *Assets,
    scene: *Scene,
    model_path: []const u8,
    fallback: math.Vec3,
    model_scale: f32,
) !EnemyLoad {
    // The enemy: the same Character type as the player, so one update path
    // serves both. It has no controller yet -- it idles, flinches when struck,
    // and is shoved by knockback. (A brain that drives it is a later stage.)
    // root is filled once the enemy is loaded, below (root has no default, so a
    // placeholder handle is needed until then -- it is never read before that
    // assignment runs).
    var enemy = Character{
        .root = undefined,
        .pos = math.vec3(2.5, 0, 1.5),
        .prev_pos = math.vec3(2.5, 0, 1.5),
    };
    var reactions = Reactions{};

    // A second character (the enemy), to prove several skinned characters can be
    // drawn at once. Loaded again rather than sharing the first's objects: its own object to
    // place, its own skeleton, and above all its own animator, so it can hold a
    // different clip at a different moment than the player.
    const second = try legend.load_gltf.load(io, gpa, assets, scene, fallback, model_path);
    // Loaded with `try` above, so second.root is always a live object --
    // no need to guard the assignment itself.
    enemy.root = second.root;
    if (scene.object(second.root)) |obj| {
        obj.transform.position = enemy.pos;
        obj.transform.scale = math.vec3(model_scale, model_scale, model_scale);
        obj.transform.rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), -1.2);
    }
    if (second.skeleton) |sk| {
        // Its own load means its own clipless KayKit rig -- give it the same
        // animation sets, before the animator is built, so the animator sizes
        // its clip count to a rig that already has them.
        clips.loadKayKitClips(io, gpa, assets, sk);
        if (assets.skeleton(sk)) |rig| {
            const anim_handle = try scene.addAnimator(gpa, rig);
            _ = scene.setAnimatorForSkeleton(sk, anim_handle);
            if (scene.animator(anim_handle)) |anim| {
                if (rig.clipByName("Run")) |run| anim.play(run);
                reactions.clip_idle = rig.clipByName("Idle_A") orelse rig.clipByName("Survey");
                reactions.clip_hit = rig.clipByName("Hit_A");
                reactions.clip_death = rig.clipByName("Death_A");
                if (reactions.clip_hit) |h| reactions.clip_hit_dur = rig.clips[h].duration;
                if (reactions.clip_idle) |i| anim.play(i);
            }
            enemy.animator = anim_handle;
            enemy.skeleton = sk;
        }
    }

    return .{ .character = enemy, .reactions = reactions };
}
