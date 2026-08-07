//! Everything that persists across frames: the player and the enemy, the
//! tuning that shapes them, and what setup produced for each -- clip lookups,
//! the sword's attach point, the enemy's own reaction state. The loop reads
//! this instead of closing over a couple dozen locals.

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const Camera = legend.Camera;
const gpu = legend.gpu;

const Assets = legend.Assets;
const Scene = legend.Scene;

const text = legend.text;
const collision = legend.collision;

const mathx = @import("mathx.zig");
const clips = @import("clips.zig");
const Tuning = @import("Tuning.zig");
const Frame = @import("Frame.zig");
const stage = @import("stage.zig");
const Character = @import("Character.zig");
const Locomotion = @import("Locomotion.zig");
const Combat = @import("Combat.zig");
const Reactions = @import("Reactions.zig");
const loaders = @import("loaders.zig");
const input_ns = @import("input.zig");

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
input: input_ns.Input,

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

const Game = @This();

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

    const player_load = try loaders.loadPlayer(io, gpa, assets, scene, model_path, fallback, tuning.model_scale);
    try stage.buildStage(gpa, assets, scene);
    const enemy_load = try loaders.loadEnemy(io, gpa, assets, scene, model_path, fallback, tuning.model_scale);

    std.debug.print("loaded {s}\n", .{model_path});

    // Which keys mean what. Playing starts on `gameplay`; F1 swaps it
    // for `free_camera` (see the toggle_camera handling in beginFrame).
    var input = input_ns.Input.init();
    input.push(&input_ns.globals);
    input.push(&input_ns.gameplay);

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
        self.input.replaceTop(if (self.free_look) &input_ns.free_camera else &input_ns.gameplay);
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
                combat.attack_current = Combat.combo_routes[0].chain[0];
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
    const origin = Combat.attackHitboxOrigin(attacker, combat, frame);
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
                const origin = Combat.attackHitboxOrigin(&self.player, combat, frame);
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
