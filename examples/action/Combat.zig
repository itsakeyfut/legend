//! The player's melee: the base attacks and their combo finishers (shared
//! data resolved once by `loadAttacks`), the weapon socket the sword rides,
//! and the swing/combo state machine. `fixedUpdate` starts a queued swing,
//! advances its clock (held during hitstop, I3), and carries a buffered
//! chain input across the swing boundary into the next link -- everything
//! except the hit test itself, which needs a target and so lives on `Game`
//! as `resolveCombat`, called right after this every step. `lateUpdate`
//! rides the sword on the hand bone.

const legend = @import("legend");
const math = legend.math;

const Character = @import("Character.zig");
const Frame = @import("Frame.zig");

/// One melee attack as data: which clip plays, how long it runs, the window
/// within it the hitbox is live, and the shape and bite of that hitbox. Making
/// an attack a value rather than a pile of constants is what lets the player
/// carry several and pick between them -- and later chain them into combos.
pub const Attack = struct {
    clip: ?usize,
    duration: f32,
    window_start: f32,
    window_end: f32,
    reach: f32,
    radius: f32,
    damage: f32,
};

/// One route through the combo: the three attacks (by index into
/// `Combat.attacks`) its links play, and which finisher input picks it.
pub const ComboRoute = struct { finish: usize, chain: [3]usize };

/// The combo routes: all share the Slice -> Chop intro, then branch on the
/// 3rd input into a different finisher. Add a route here and it just works.
/// finish picks the route at the branch (the 3rd press).
pub const combo_routes = [_]ComboRoute{
    .{ .finish = 0, .chain = .{ 0, 1, 3 } }, // left-left-LEFT: sweep
    .{ .finish = 1, .chain = .{ 0, 1, 4 } }, // left-left-Q:    heavy chop
    .{ .finish = 2, .chain = .{ 0, 1, 5 } }, // left-left-E:    heavy stab
};

const Self = @This();

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
pub fn fixedUpdate(self: *Self, char: *Character, frame: Frame, hitstop: f32) void {
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
pub fn lateUpdate(self: *Self, char: *Character, frame: Frame) void {
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

/// The point the current swing's hitbox extends from: the sword hand's
/// world position, if the rig names one and it's loaded and posed --
/// otherwise a fallback point on the chest. Shared by the hit test
/// (`Game.resolveCombat`) and the debug-draw hitbox (`Game.render`), so what
/// is drawn is what is tested (I6). Built from `char.pos`, the sim-space
/// position, not the smoothed render pos -- the hit test runs in the fixed
/// step, and the debug draw is deliberately kept consistent with it rather
/// than the interpolated one.
pub fn attackHitboxOrigin(char: *const Character, combat: *const Self, frame: Frame) math.Vec3 {
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
