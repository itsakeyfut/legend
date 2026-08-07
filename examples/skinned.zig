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
    step_offset: f32 = 0,

    // Combat: what a hit lands on / takes off.
    health: f32 = 100,

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
        return lerpAngle(self.prev_yaw, self.yaw, alpha);
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
        const duration = clipDuration(assets, self.skeleton, c);
        time.* += step;
        if (duration > 0) {
            while (time.* > duration) time.* -= duration;
        }
    }
};

const Input = action.Map(Action);

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

/// The world the character collides against. The first box is the floor, whose
/// top face is the y = 0 the ground quad is drawn at; the rest are obstacles.
///
/// The staircase rises 0.35 m a tread -- past the capsule's radius, so it is
/// only climbable because the controller steps up, and within its step height,
/// so it is climbable at all. The platform beyond is 1.2 m and still wants a
/// jump. Each stair overlaps the one before it in z rather than meeting it
/// exactly: two faces in the same plane would fight over which is drawn.
const world = [_]collision.Aabb{
    .{ .min = math.vec3(-8, -1, -8), .max = math.vec3(8, 0, 8) }, // floor
    .{ .min = math.vec3(3, 0, -4), .max = math.vec3(3.5, 2, 4) }, // long wall
    .{ .min = math.vec3(-3, 0, 1.00), .max = math.vec3(-1, 0.35, 1.60) }, // stair
    .{ .min = math.vec3(-3, 0, 1.55), .max = math.vec3(-1, 0.70, 2.15) }, // stair
    .{ .min = math.vec3(-3, 0, 2.10), .max = math.vec3(-1, 1.05, 2.70) }, // stair
    .{ .min = math.vec3(-3, 0, -3), .max = math.vec3(-1, 1.2, -1) }, // tall platform
    .{ .min = math.vec3(1, 0, -2.2), .max = math.vec3(1.6, 2.5, -1.6) }, // pillar
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

    var ctx = try gpu.Context.init(gpa, &win, width, height);
    defer ctx.deinit(&win);

    var assets = try Assets.init(gpa, &ctx);
    defer assets.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit();

    // Debug-draw lines go into a buffer this loop owns and reuses -- no
    // per-frame allocation, the same shape the draw list uses.
    var line_buf: [legend.max_line_vertices]legend.LineVertex = undefined;
    var dbg = legend.Debug.init(&line_buf);

    // CesiumMan's texture is JPEG, which the engine doesn't decode; nodes with
    // no usable base-color texture fall back to this flat tint over white.
    const fallback = math.vec3(0.8, 0.8, 0.85);
    const model = try legend.load_gltf.load(io, gpa, &assets, &scene, fallback, model_path);
    const player = model.root;
    const player_skeleton = model.skeleton;

    // KayKit ships the body and its animations in separate files -- the body glb
    // carries no clips -- so pull the shared animation sets in and bind them to
    // the rig by name, the way a character and its animations are separate assets
    // in UE and Unity.
    if (player_skeleton) |sk| loadKayKitClips(io, gpa, &assets, sk);

    // Which clip means what, resolved once. A model may not have them -- the
    // engine has no idea what a walk is, and neither file is obliged to name
    // one -- so each is optional and the game falls back to what it has.
    var clip_idle: ?usize = null;
    var clip_walk: ?usize = null;
    var clip_run: ?usize = null;
    var attacks: [6]Attack = undefined;
    if (player_skeleton) |sk| {
        if (assets.skeleton(sk)) |skel| {
            clip_idle = skel.clipByName("Survey") orelse skel.clipByName("Idle_A");
            clip_walk = skel.clipByName("Walk") orelse skel.clipByName("Walking_A");
            clip_run = skel.clipByName("Run") orelse skel.clipByName("Running_A");
            // Three 1H attacks, differing in speed, reach, and bite. Same KayKit
            // clips already bound to the rig; only the hit windows, reach, and
            // damage are ours to set -- the same motion becomes a light quick
            // slice or a slow long stab by how the hitbox is placed on it.
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
            for (skel.clips) |clip| {
                std.debug.print("  {s} ({d:.2}s)\n", .{ clip.name, clip.duration });
            }
        }
    }

    // The character's own playback. The rig is shared; this is where this fox is
    // in its stride. The skinned mesh -- and so the skeleton -- sits on a child
    // of the model root, and the animator has to go on that same object, or the
    // draw would find a skinned mesh with no palette and tear it apart.
    var player_animator: ?legend.AnimatorHandle = null;
    if (player_skeleton) |sk| {
        if (assets.skeleton(sk)) |rig| {
            // One animator, shared by every mesh on this rig -- a KayKit body is
            // nine meshes and they must pose as one character, not nine.
            const handle = try scene.addAnimator(gpa, rig);
            _ = scene.setAnimatorForSkeleton(sk, handle);
            player_animator = handle;
        }
    }

    // The player's weapon: a separate model, moved each frame to ride the hand
    // bone. handslot.r is KayKit's socket joint at the right hand; the sword was
    // authored to sit right when parented there. Loaded once, followed forever.
    var sword_root: ?legend.ObjectHandle = null;
    var handslot_joint: ?usize = null;
    {
        const sword = legend.load_gltf.load(io, gpa, &assets, &scene, fallback, "assets/gltf/kaykit/Weapons/sword_1handed.gltf") catch |err| blk: {
            std.debug.print("no sword: {}\n", .{err});
            break :blk null;
        };
        if (sword) |s| {
            sword_root = s.root;
        }
        if (player_skeleton) |sk| {
            if (assets.skeleton(sk)) |skel| {
                handslot_joint = skel.jointForName("handslot.r");
                std.debug.print("handslot.r joint = {any}\n", .{handslot_joint});
            }
        }
    }

    // The font atlas: white glyphs in the alpha channel, uploaded like any
    // other texture. One upload at startup, then it just sits there.
    const atlas_pixels = try font.buildAtlas(gpa);
    defer gpa.free(atlas_pixels);
    var atlas = try ctx.uploadTexture(atlas_pixels, font.atlas_size, font.atlas_size);
    defer atlas.deinit();

    // A ground plane to walk on and for the shadow to land on. It is drawn at
    // the same height as the top of the floor box the character stands on.
    {
        const s: f32 = 8;
        var ground_verts = [_]legend.Vertex{
            .{ .pos = math.vec3(-s, 0, -s), .uv = math.vec2(0, 0), .normal = math.vec3(0, 1, 0) },
            .{ .pos = math.vec3(-s, 0, s), .uv = math.vec2(0, 1), .normal = math.vec3(0, 1, 0) },
            .{ .pos = math.vec3(s, 0, s), .uv = math.vec2(1, 1), .normal = math.vec3(0, 1, 0) },
            .{ .pos = math.vec3(s, 0, -s), .uv = math.vec2(1, 0), .normal = math.vec3(0, 1, 0) },
        };
        // Counter-clockwise seen from above, so the top face is the front face
        // the pipeline keeps -- the same natural winding glTF models use.
        var ground_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

        const ground_mesh = legend.Mesh{
            .vertices = &ground_verts,
            .indices = &ground_indices,
            .allocator = gpa,
        };
        const ground_handle = try assets.addMesh(gpa, ground_mesh);
        const ground_mat = try scene.addMaterial(.{
            .texture = assets.white,
            .tint = math.vec3(0.55, 0.55, 0.6),
        });
        _ = try scene.addObject(ground_handle, ground_mat, .{});
    }

    // Something to see for each collision box. The floor is skipped: the ground
    // quad already stands in for its top face, and drawing both would have two
    // surfaces fighting over the same plane.
    {
        const box_mat = try scene.addMaterial(.{
            .texture = assets.white,
            .tint = math.vec3(0.45, 0.5, 0.6),
        });
        for (world[1..]) |box| {
            var bm = boxMesh(box);
            const handle = try assets.addMesh(gpa, .{
                .vertices = &bm.verts,
                .indices = &bm.indices,
                .allocator = gpa,
            });
            _ = try scene.addObject(handle, box_mat, .{});
        }
    }

    std.debug.print("loaded {s}\n", .{model_path});

    // -- state -------------------------------------------------------------
    // The character's own. The engine has no Player type: a character is an
    // Object with a skeleton, and what moves it is game code.
    var player_pos = math.vec3(0, 2, 0);
    var player_yaw: f32 = 0;
    // Velocity carries the vertical motion between steps -- what makes a jump
    // rise and slow rather than teleport. The horizontal part is rewritten from
    // input each step; only y accumulates.
    var player_vel = math.vec3(0, 0, 0);
    var grounded = false;
    // The attack's own clock: null when idle, else seconds since the swing began,
    // advanced each sim step and cleared when the swing is over. The hit window is
    // a span within it. With no attack clip on the fox yet, this stands in for one
    // -- when a humanoid with a swing arrives, this reads the clip's time instead.
    var attack_time: ?f32 = null;
    var attack_current: usize = 0;
    // Set false while a swing is live, true once it has dealt its damage, so the
    // multi-frame hit window still only lands once. (Reset each new swing.)
    var attack_spent = false;
    var attack_queued = false;

    // The combo: which link of the fixed chain the next mouse-left swing plays,
    // and whether one was buffered during the current swing's window. Left-click
    // during the window advances the chain (Slice -> Chop -> Stab); miss the
    // window and it resets to the first link.
    var combo_step: usize = 0;
    var combo_queued = false;
    // The combo routes: all share the Slice -> Chop intro, then branch on the
    // 3rd input into a different finisher. Add a route here and it just works.
    // finish_input picks the route at the branch (the 3rd press).
    const ComboRoute = struct { finish: usize, chain: [3]usize };
    const combo_routes = [_]ComboRoute{
        .{ .finish = 0, .chain = .{ 0, 1, 3 } }, // left-left-LEFT: sweep
        .{ .finish = 1, .chain = .{ 0, 1, 4 } }, // left-left-Q:    heavy chop
        .{ .finish = 2, .chain = .{ 0, 1, 5 } }, // left-left-E:    heavy stab
    };
    // Which finisher input was buffered at the branch (0=left,1=Q,2=E), and the
    // route chosen once we branch. Until the branch, all routes share the intro.
    var combo_finish: usize = 0;
    var combo_route: usize = 0;

    // How far below its true position the character is currently drawn.
    //
    // A step-up moves the capsule a whole ledge's height in one step, which
    // reads as a jolt however smoothly the rest is interpolated. Rather than
    // slow the capsule down -- it must be on top of the step to stand there --
    // the rise is subtracted from what is drawn and paid back over the next few
    // frames. What the game simulates is unchanged; only the view lags.
    var step_offset: f32 = 0;
    // The pose one fixed step ago. The simulation advances player_pos/player_yaw
    // in whole fixed steps; the render draws the blend between this previous
    // pose and the current one, which is what stays smooth when the screen
    // refreshes faster than the simulation ticks.
    var player_prev_pos = player_pos;
    var player_prev_yaw = player_yaw;
    const walk_speed: f32 = 1.6;
    // Running covers ground faster, and its clip is built for that faster pace.
    // Two numbers rather than a multiplier: the clip decides its own speed, and
    // the character's is a separate choice that happens to suit it.
    const run_speed: f32 = 3.0;
    const run_clip_speed: f32 = 3.0;
    // Fox is authored ~155 units long, so it needs shrinking hard; KayKit is near
    // life-size and needs almost none. A model's file says nothing about the unit
    // it was built in, so the game picks -- keyed off the path until asset
    // metadata carries a scale.
    const model_scale: f32 = if (std.mem.indexOf(u8, model_path, "kaykit") != null) 0.5 else 0.012;
    // How fast the character turns toward where it is going, per second.
    const turn_rate: f32 = 10.0;

    // How fast the drawn position catches up after a step-up, per second. Lower
    // is smoother but sinks the character further into the step it climbed;
    // higher snaps back sooner and lets more of the jolt through.
    const step_smooth_rate: f32 = 12.0;
    // The hit's aftermath. A short freeze on both sides, then the target slides
    // back along the blow and settles. Damping is per second: how quickly the
    // knockback bleeds off, so the slide is a shove, not a launch across the map.
    const hitstop_duration: f32 = 0.08;
    const knockback_speed: f32 = 6.0;
    const knockback_damping: f32 = 8.0;
    // The target's hurt volume: an upright capsule wrapping its body. Separate from
    // any collision shape on purpose -- what a hit lands on is its own concern, and
    // will want per-part tuning (head, torso) later.
    const hurt_radius: f32 = 0.5;
    const hurt_height: f32 = 1.2;
    // The capsule the character collides as, and what it is allowed to walk on.
    // Collision shape and drawn model are separate: the capsule is what the game
    // feels, and it is sized by hand rather than fitted to whatever file loaded.
    const controller = collision.Controller{
        .radius = 0.3,
        .height = 1.7,
        .step_height = 0.4,
    };

    // Gravity is exaggerated well past 9.8: real gravity makes a jump float, and
    // a character that hangs in the air reads as weightless rather than real.
    const gravity: f32 = -25.0;
    // The height a jump should reach, converted to the speed that reaches it:
    // v = sqrt(2 * g * h). Tuning the height is what a designer wants to do; the
    // speed is derived from it.
    const jump_height: f32 = 1.2;
    const jump_speed: f32 = @sqrt(2.0 * -gravity * jump_height);
    // Walk off the edge and the fall is endless, so put the character back.
    const respawn_below: f32 = -20.0;

    // The follow camera orbits this far from the character, aimed at a point
    // this high on it -- the chest, not the feet, or the view sits on the floor.
    const follow_distance: f32 = 3.0;
    const focus_height: f32 = 0.6;

    // Facing +Z at yaw pi/2, so the camera starts behind a character that also
    // faces +Z. Its position is derived every frame while following, so this is
    // only the starting orbit.
    var camera = Camera{ .yaw = std.math.pi / 2.0 };
    win.setMouseCaptured(true);

    const fly_speed: f32 = 4.0;
    const mouse_sensitivity: f32 = 0.0025;

    var free_look = false;

    var input = Input.init();
    input.push(&globals);
    input.push(&gameplay);

    var items: [256]gpu.DrawItem = undefined;
    var text_items: [512]gpu.TextItem = undefined;

    var fps = legend.FpsCounter{};
    var title_buf: [160]u8 = undefined;
    var last_ms = win.ticks();
    // Runs the simulation in equal 1/60 s steps, decoupled from the render rate.
    var ts = legend.FixedTimestep{};
    // A jump pressed between simulation steps must not be lost, so the press is
    // latched here and spent by the first step that can act on it. Held rather
    // than dropped when airborne, so a press just before landing still jumps.
    var jump_queued = false;
    // How fast the walk fades in and out, per second. A tenth of a second or so
    // is the usual range for a locomotion transition -- long enough not to snap,
    // short enough that the character does not feel to be wading.
    const blend_rate: f32 = 8.0;
    // The speed the walk clip is built for -- how fast the character would
    // travel if the clip played at rate 1 without the feet slipping.
    //
    // The clip animates a walk in place, so it does not say how far a stride
    // carries anyone; this is measured by eye. Too high and the legs shuffle
    // while the ground rushes past, too low and they windmill.
    const clip_speed: f32 = 1.6;

    // The model's scale is fixed, so set it once rather than every frame.
    if (scene.object(player)) |obj| {
        obj.transform.scale = math.vec3(model_scale, model_scale, model_scale);
    }

    // The second fox doubles as a target: where it stands, how fast it is being
    // knocked, its object so the knockback can be drawn, and health to take off.
    // Kept out here so combat below can read and move them.
    var second_pos = math.vec3(2.5, 0, 1.5);
    var second_vel = math.vec3(0, 0, 0);
    var second_root: ?legend.ObjectHandle = null;
    var second_health: f32 = 100;
    // The target's reactions. It idles until hit, plays a flinch when struck,
    // and falls when its health runs out -- after which it neither reacts nor is
    // shoved again. A clip's own length says when a flinch is over.
    const TargetState = enum { idle, flinch, dead };
    var second_state: TargetState = .idle;
    // How long the current flinch has left to play, in seconds. Counts down.
    var second_flinch_time: f32 = 0;
    var clip_target_idle: ?usize = null;
    var clip_target_hit: ?usize = null;
    var clip_target_death: ?usize = null;
    var clip_target_hit_dur: f32 = 0;
    // How long, in seconds, both sides freeze on a hit -- the pause that gives a
    // blow its weight. Counts down; while it runs, clocks and the swing hold.
    var hitstop: f32 = 0;
    // A second fox, to prove several skinned characters can be drawn at once.
    // Loaded again rather than sharing the first's objects: its own object to
    // place, its own skeleton, and above all its own animator, so it can hold a
    // different clip at a different moment than the player. It stands and loops
    // -- no movement or control, only its own clock, ticked in the sim loop.
    var second_animator: ?legend.AnimatorHandle = null;
    var second_skeleton: ?legend.SkeletonHandle = null;
    {
        const second = try legend.load_gltf.load(io, gpa, &assets, &scene, fallback, model_path);
        if (scene.object(second.root)) |obj| {
            obj.transform.position = second_pos;
            obj.transform.scale = math.vec3(model_scale, model_scale, model_scale);
            obj.transform.rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), -1.2);
            second_root = second.root;
        }
        if (second.skeleton) |sk| {
            // Its own load means its own clipless KayKit rig -- give it the same
            // animation sets, before the animator is built, so the animator sizes
            // its clip count to a rig that already has them.
            loadKayKitClips(io, gpa, &assets, sk);
            if (assets.skeleton(sk)) |rig| {
                const anim_handle = try scene.addAnimator(gpa, rig);
                _ = scene.setAnimatorForSkeleton(sk, anim_handle);
                if (scene.animator(anim_handle)) |anim| {
                    if (rig.clipByName("Run")) |run| anim.play(run);
                    clip_target_idle = rig.clipByName("Idle_A") orelse rig.clipByName("Survey");
                    clip_target_hit = rig.clipByName("Hit_A");
                    clip_target_death = rig.clipByName("Death_A");
                    if (clip_target_hit) |h| clip_target_hit_dur = rig.clips[h].duration;
                    if (clip_target_idle) |i| anim.play(i);
                }
                second_animator = anim_handle;
                second_skeleton = sk;
            }
        }
    }

    while (true) {
        // -- render clock: once per frame, on real elapsed time ------------
        const now_ms = win.ticks();
        const elapsed_ms = now_ms - last_ms;
        const frame_dt = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
        last_ms = now_ms;

        if (fps.tick(elapsed_ms)) {
            const title = std.fmt.bufPrintZ(
                &title_buf,
                "LegendEngine - Skinned | {d:.1} fps",
                .{fps.fps},
            ) catch "LegendEngine - Skinned";
            win.setTitle(title);
        }

        const raw = win.poll();
        input.update(raw);

        if (raw.quit or input.pressed(.quit)) break;
        if (input.pressed(.toggle_mouse)) win.setMouseCaptured(!win.isMouseCaptured());
        if (input.pressed(.toggle_camera)) {
            free_look = !free_look;
            input.replaceTop(if (free_look) &free_camera else &gameplay);
        }
        // A press is an event on the render clock; the simulation reads the latch.
        if (input.pressed(.jump)) jump_queued = true;
        // Attack inputs. Out of combat each starts its own attack; during a combo
        // the press is buffered as the branch choice (which finisher).
        if (input.pressed(.attack_slice)) {
            if (attack_time == null) {
                combo_step = 0;
                combo_route = 0; // default route until a branch input says otherwise
                attack_current = combo_routes[0].chain[0];
                attack_queued = true;
            } else {
                combo_queued = true;
                combo_finish = 0; // left = route with finish 0
            }
        }
        if (input.pressed(.attack_chop)) {
            if (attack_time == null) {
                attack_queued = true;
                attack_current = 1; // single Chop out of combat
            } else {
                combo_queued = true;
                combo_finish = 1; // Q = route with finish 1
            }
        }
        if (input.pressed(.attack_stab)) {
            if (attack_time == null) {
                attack_queued = true;
                attack_current = 2; // single Stab out of combat
            } else {
                combo_queued = true;
                combo_finish = 2; // E = route with finish 2
            }
        }

        if (input.pressed(.toggle_collision)) dbg.show_collision = !dbg.show_collision;
        if (input.pressed(.toggle_stats)) dbg.show_stats = !dbg.show_stats;

        // Looking turns the camera in both modes: orbiting the character while
        // playing, aiming the free camera while inspecting. Presentation, so it
        // runs on the render clock -- as responsive as the screen refreshes.
        camera.look(
            input.value(.look_x) * mouse_sensitivity,
            input.value(.look_y) * mouse_sensitivity,
        );

        // -- simulation: zero or more equal fixed steps --------------------
        // Input was polled once above; every step this frame reads that same
        // snapshot. Movement, gravity and the animation clock advance here so
        // they behave the same at any frame rate.
        ts.addFrame(frame_dt);
        while (ts.step()) {
            // Carry the current pose back one step before advancing it, so the
            // render below can interpolate from where the character was to where
            // it now is. Done every step and in either mode, so the previous
            // pose is always exactly one step behind the current one.
            player_prev_pos = player_pos;
            player_prev_yaw = player_yaw;

            if (!free_look) {
                const mx = input.value(.move_x);
                const mz = input.value(.move_z);
                const moving = mx != 0 or mz != 0;
                const running = moving and input.held(.sprint);

                const speed = if (running) run_speed else walk_speed;
                const before = player_pos;

                // Horizontal velocity is set outright from input rather than
                // accumulated: a character walks at the speed asked for and
                // stops when the key is let go, which is control, not physics.
                var horizontal = math.vec3(0, 0, 0);
                if (moving) {
                    const cf = camera.forward();
                    const flat = math.vec3(cf.x(), 0, cf.z()).normalize();
                    const dir = flat.scale(mz).add(camera.right().scale(mx)).normalize();
                    horizontal = dir.scale(speed);

                    const target_yaw = std.math.atan2(dir.x(), dir.z());
                    player_yaw = approachAngle(player_yaw, target_yaw, turn_rate, ts.fixed_dt);
                }

                // Standing on something cancels the fall that put the character
                // there; without this, gravity would build a downward speed all
                // the while it stands, and the first step off a ledge would drop
                // it like a stone.
                var vy = player_vel.y();
                if (grounded and vy < 0) vy = 0;
                if (grounded and jump_queued) {
                    vy = jump_speed;
                    jump_queued = false;
                    grounded = false;
                }
                vy += gravity * ts.fixed_dt;

                player_vel = math.vec3(horizontal.x(), vy, horizontal.z());

                // One move, then pushed back out of whatever it entered.
                const result = collision.moveAndSlide(
                    controller,
                    player_pos,
                    player_vel.scale(ts.fixed_dt),
                    grounded,
                    &world,
                );
                player_pos = result.pos;
                grounded = result.grounded;
                // Take on the step's rise as a debt against what is drawn, never
                // more than one step's worth, and pay it down every step.
                step_offset = @min(step_offset + result.stepped, controller.step_height);
                step_offset -= step_offset * @min(1.0, step_smooth_rate * ts.fixed_dt);
                // Landing, or hitting a ceiling, ends the vertical motion: the
                // push-out has already removed the distance, and keeping the
                // speed would only fight the surface next step.
                if (result.grounded and player_vel.y() < 0) {
                    player_vel = math.vec3(player_vel.x(), 0, player_vel.z());
                }

                if (player_pos.y() < respawn_below) {
                    player_pos = math.vec3(0, 2, 0);
                    player_vel = math.vec3(0, 0, 0);
                    // A teleport is not motion: start the interpolation over, or
                    // the render would smear the character across the gap.
                    player_prev_pos = player_pos;
                    step_offset = 0;
                }

                // Only the ground covered counts toward the walk cycle. Falling
                // is distance too, and counting it would run the legs in mid-air.
                const moved = player_pos.sub(before);
                const travelled = math.vec3(moved.x(), 0, moved.z()).length();

                // The clip's clock advances while the character moves; its own
                // length decides when it loops. Standing still holds the bind
                // pose, which is not an idle animation -- it is the absence of
                // one, and the honest placeholder until there is a second clip
                // to switch to. The pose these times imply is evaluated once a
                // frame, after the loop -- here the simulation only sets clocks.
                if (player_animator) |ah| {
                    if (scene.animator(ah)) |anim| {
                        // Attack overrides locomotion: while a swing is playing,
                        // the swing is what shows. Then running, walking, idle --
                        // the ordinary locomotion underneath.
                        if (attack_time != null and attacks[attack_current].clip != null) {
                            anim.play(attacks[attack_current].clip.?);
                        } else if (running and clip_run != null) {
                            anim.play(clip_run.?);
                        } else if (moving) {
                            if (clip_walk) |w| anim.play(w);
                        } else if (clip_idle) |i| {
                            anim.play(i);
                        } else {
                            anim.stop();
                        }

                        anim.advanceBlend(ts.fixed_dt, blend_rate);

                        // Each clip is built for its own pace, so the ground
                        // covered is divided by the speed that clip assumes --
                        // not by one shared number. Get this wrong and the run
                        // skates while the walk is fine, or the reverse.
                        if (anim.current) |c| {
                            const duration = clipDuration(&assets, player_skeleton, c);
                            const pace = if (running) run_clip_speed else clip_speed;
                            const step = if (moving and pace > 0)
                                travelled / pace
                            else
                                ts.fixed_dt;
                            anim.current_time += step;
                            if (duration > 0) {
                                while (anim.current_time > duration) anim.current_time -= duration;
                            }
                        }

                        if (anim.previous) |p| {
                            const duration = clipDuration(&assets, player_skeleton, p);
                            anim.previous_time += ts.fixed_dt;
                            if (duration > 0) {
                                while (anim.previous_time > duration) anim.previous_time -= duration;
                            }
                        }
                    }
                }

                // -- combat -------------------------------------------------
                // Start a swing if one is queued and none is running.
                if (attack_queued) {
                    attack_queued = false;
                    if (attack_time == null) {
                        attack_time = 0;
                        attack_spent = false;
                    }
                }

                // Advance the swing, and end it when the motion is over.
                if (attack_time) |*t| {
                    const attack = attacks[attack_current];
                    if (hitstop <= 0) t.* += ts.fixed_dt;

                    // Inside the hit window, and not yet connected this swing:
                    // put the hitbox ahead of the player and test the target's
                    // hurtbox. A swing lands at most once -- attack_spent is what
                    // keeps the multi-frame window from hitting every frame.
                    const live = t.* >= attack.window_start and t.* <= attack.window_end;
                    if (live and !attack_spent) {
                        const facing = math.vec3(std.math.sin(player_yaw), 0, std.math.cos(player_yaw));
                        // The hitbox rides the sword hand: take the hand bone's
                        // world position -- the same bone the sword is parented to
                        // -- so the swing lands where the blade is, not at a fixed
                        // point on the chest. Built from player_pos (the sim-space
                        // position), not the smoothed render pos, because this test
                        // runs in the fixed step. If the bone is unavailable it
                        // falls back to the chest. Orientation is still the facing
                        // for now; the blade's own tilt is the next step.
                        var origin = player_pos.add(math.vec3(0, 0.6, 0));
                        if (handslot_joint) |hj| {
                            if (player_animator) |ah| {
                                if (scene.animator(ah)) |anim| {
                                    const char_model = (legend.Transform{
                                        .position = player_pos,
                                        .rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), player_yaw),
                                        .scale = math.vec3(model_scale, model_scale, model_scale),
                                    }).matrix();
                                    const bone_world = char_model.mul(anim.world[hj]);
                                    origin = legend.Transform.decompose(bone_world).position;
                                }
                            }
                        }

                        const hitbox = collision.Capsule{
                            .a = origin,
                            .b = origin.add(facing.scale(attack.reach)),
                            .radius = attack.radius,
                        };

                        const hurtbox = collision.Capsule{
                            .a = second_pos.add(math.vec3(0, hurt_radius, 0)),
                            .b = second_pos.add(math.vec3(0, hurt_height - hurt_radius, 0)),
                            .radius = hurt_radius,
                        };
                        if (collision.capsuleVsCapsule(hitbox, hurtbox)) {
                            second_health = @max(0, second_health - attack.damage);
                            attack_spent = true;
                            hitstop = hitstop_duration;
                            second_vel = facing.scale(knockback_speed);
                            // Health gone -> fall and stay down; otherwise flinch,
                            // for as long as the flinch clip runs.
                            if (second_health <= 0) {
                                second_state = .dead;
                            } else {
                                second_state = .flinch;
                                second_flinch_time = clip_target_hit_dur;
                            }
                        }
                    }

                    // The combo window: the back half of the swing. A left-click
                    // buffered here chains into the next link when the swing ends.
                    const combo_window = t.* >= attack.duration * 0.5;
                    if (!combo_window) combo_queued = false; // too early: not a chain

                    if (t.* >= attack.duration) {
                        // Swing over. If a link was buffered in the window and the
                        // chain has further to go, start the next link; otherwise
                        // the combo ends and the next left-click starts fresh.
                        if (combo_queued and combo_step + 1 < 3) {
                            // Advance the chain. On the branch step (into link 2,
                            // the finisher), the buffered input picks the route.
                            combo_step += 1;
                            if (combo_step == 2) combo_route = combo_finish;
                            attack_current = combo_routes[combo_route].chain[combo_step];
                            attack_time = 0;
                            attack_spent = false;
                            combo_queued = false;
                        } else {
                            attack_time = null;
                            combo_step = 0;
                            combo_route = 0;
                            combo_queued = false;
                        }
                    }
                }
            }

            // The second fox has no game state driving it -- it just loops its
            // clip in place. Advancing its clock here, on the same fixed step,
            // is all that separates a frozen pose from a running one, and proves
            // two animators tick on independent clocks (the player's driven by
            // distance travelled, this one by time).
            if (second_animator) |ah| {
                if (scene.animator(ah)) |anim| {
                    // Death outranks flinch outranks idle -- the same priority
                    // shape the player's attack-over-locomotion uses. A flinch
                    // runs its clip out, then falls back to idle.
                    switch (second_state) {
                        .dead => {
                            if (clip_target_death) |d| anim.play(d);
                        },
                        .flinch => {
                            if (clip_target_hit) |h| anim.play(h);
                            if (hitstop <= 0) {
                                second_flinch_time -= ts.fixed_dt;
                                if (second_flinch_time <= 0) second_state = .idle;
                            }
                        },
                        .idle => {
                            if (clip_target_idle) |i| anim.play(i);
                        },
                    }

                    anim.advanceBlend(ts.fixed_dt, blend_rate);
                    if (anim.current) |c| {
                        const duration = clipDuration(&assets, second_skeleton, c);
                        // Death holds on its last frame; everything else loops.
                        // The freeze pauses the clock the same as it does the player.
                        if (hitstop <= 0 and second_state != .dead) {
                            anim.current_time += ts.fixed_dt;
                            if (duration > 0) {
                                while (anim.current_time > duration) anim.current_time -= duration;
                            }
                        } else if (second_state == .dead) {
                            // Advance once the end, then hold -- a corpse does
                            // not loop back to standing.
                            if (duration > 0 and anim.current_time < duration) {
                                anim.current_time = @min(anim.current_time + ts.fixed_dt, duration);
                            }
                        }
                    }
                }
            }
            // Count the freeze down. While it runs, nothing above advanced;
            // now the target is let go and the knockback plays out.
            if (hitstop > 0) {
                hitstop = @max(0, hitstop - ts.fixed_dt);
            } else if (second_root != null and second_state != .dead) {
                // Slide the target along its velocity, then bleed the
                // velocity off. moveAndSlide means a wall or a stair stops
                // it, the same as it stops the player.
                const result = collision.moveAndSlide(
                    controller,
                    second_pos,
                    second_vel.scale(ts.fixed_dt),
                    true,
                    &world,
                );
                second_pos = result.pos;
                const decay = @max(0.0, 1.0 - knockback_damping * ts.fixed_dt);
                second_vel = second_vel.scale(decay);
            }
        }

        // The update phase: bring every animated character's pose up to date
        // once, after the simulation has finished advancing their clocks. This
        // is where posing lives now -- not in the draw, and not per sim step.
        scene.evaluateAnimators(&assets);

        // How far the render sits between the last two simulated poses, 0..1.
        // Drawing the blend between them is what turns a position that only
        // changes 60 times a second into motion smooth at any refresh rate.
        const alpha = ts.alpha();
        const render_pos = player_prev_pos.lerp(player_pos, alpha);
        const render_yaw = lerpAngle(player_prev_yaw, player_yaw, alpha);
        const smoothed_pos = render_pos.sub(math.vec3(0, step_offset, 0));

        // -- presentation: reflect the interpolated pose and draw ----------
        if (free_look) {
            // The free camera is a debug tool, not gameplay -- move it on the
            // render clock so inspection stays smooth.
            camera.move(
                input.value(.move_x) * fly_speed * frame_dt,
                input.value(.move_y) * fly_speed * frame_dt,
                input.value(.move_z) * fly_speed * frame_dt,
            );
        } else {
            // Draw the character at the interpolated pose, not the raw sim
            // state. (Scale was set once before the loop and never changes.)
            if (scene.object(player)) |obj| {
                obj.transform.position = smoothed_pos;
                obj.transform.rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), render_yaw);
            }
            // Ride the sword on the hand bone. The bone's world matrix is in the
            // character's model space, so composing the character's own model
            // matrix onto it puts the sword where the hand is in the world. The
            // result is decomposed back to a Transform because that is what an
            // Object carries.
            if (sword_root) |sroot| {
                if (handslot_joint) |hj| {
                    if (player_animator) |ah| {
                        if (scene.animator(ah)) |anim| {
                            const char_model = (legend.Transform{
                                .position = smoothed_pos,
                                .rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), render_yaw),
                                .scale = math.vec3(model_scale, model_scale, model_scale),
                            }).matrix();
                            const bone_world = anim.world[hj];
                            const sword_world = char_model.mul(bone_world);
                            if (scene.object(sroot)) |sobj| {
                                sobj.transform = legend.Transform.decompose(sword_world);
                            }
                        }
                    }
                }
            }
            // The target's drawn position follows its knockback. Its facing and
            // scale were set once and do not change, so only position is written.
            if (second_root) |root| {
                if (scene.object(root)) |obj| obj.transform.position = second_pos;
            }

            // The camera hangs behind wherever it is aimed, a fixed distance
            // from the character. It tracks the same smoothed position the
            // character is drawn at, so the two never disagree.
            const focus = smoothed_pos.add(math.vec3(0, focus_height, 0));
            camera.position = focus.sub(camera.forward().scale(follow_distance));
        }

        const aspect = @as(f32, @floatFromInt(ctx.swapchain.extent.width)) /
            @as(f32, @floatFromInt(ctx.swapchain.extent.height));

        const frame = try legend.buildDrawList(&scene, &assets, &ctx, camera, aspect, &items);

        // -- debug overlay -------------------------------------------------
        const screen_w: f32 = @floatFromInt(ctx.swapchain.extent.width);
        const screen_h: f32 = @floatFromInt(ctx.swapchain.extent.height);

        var overlay_buf: [320]u8 = undefined;
        const overlay = std.fmt.bufPrint(&overlay_buf,
            \\FPS {d:.0}
            \\MODE {s}
            \\POS {d:.1} {d:.1} {d:.1}
            \\VY {d:.1} {s} SM {d:.2}
            \\CLIP {s} B {d:.2}
            \\HP {d:.0} ATK {s}
        , .{
            fps.fps,
            if (free_look) "FREE CAM" else "PLAY",
            player_pos.x(),
            player_pos.y(),
            player_pos.z(),
            player_vel.y(),
            if (grounded) "GROUND" else "AIR",
            step_offset,
            blk: {
                if (player_animator) |ah| {
                    if (scene.animator(ah)) |a| {
                        if (a.current) |c| break :blk clipName(&assets, player_skeleton, c);
                    }
                }
                break :blk "REST";
            },
            blk: {
                if (player_animator) |ah| {
                    if (scene.animator(ah)) |a| break :blk a.blend;
                }
                break :blk @as(f32, 0);
            },
            second_health,
            if (attack_time != null) "SWING" else "-",
        }) catch "";

        const text_count = if (dbg.show_stats)
            text.layout(
                &text_items,
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

        const vp = camera.viewProjection(aspect);
        const line_vp = legend.LinePush{
            .vp0 = vp.column(0).v,
            .vp1 = vp.column(1).v,
            .vp2 = vp.column(2).v,
            .vp3 = vp.column(3).v,
        };

        dbg.clear();
        if (dbg.show_collision) {
            // The world's collision boxes, blue. Everything the character is
            // tested against -- walls, steps, the platform -- made visible, the
            // way UE's `show Collision` draws the static world. The floor (box 0)
            // is skipped: it coincides with the ground quad and only clutters.
            for (world[1..]) |box| {
                dbg.aabb(box, math.vec3(0.3, 0.5, 1.0));
            }
            // The target's hurt volume, always. Green: what a hit lands on.
            const hurtbox = collision.Capsule{
                .a = second_pos.add(math.vec3(0, hurt_radius, 0)),
                .b = second_pos.add(math.vec3(0, hurt_height - hurt_radius, 0)),
                .radius = hurt_radius,
            };
            dbg.capsule(hurtbox, math.vec3(0.2, 1, 0.2));
            // The player's facing, cyan: an arrow from the chest forward.
            const facing_dir = math.vec3(std.math.sin(player_yaw), 0, std.math.cos(player_yaw));
            const chest = player_pos.add(math.vec3(0, 0.9, 0));
            dbg.arrow(chest, chest.add(facing_dir.scale(1.5)), math.vec3(0, 0.8, 1));

            // The attack's hitbox, red, only while a swing is live. Rebuilt from
            // the same hand-bone position the hit test uses, so what is drawn is
            // what is tested.
            if (attack_time != null) {
                const attack = attacks[attack_current];
                const facing = math.vec3(std.math.sin(player_yaw), 0, std.math.cos(player_yaw));
                var origin = player_pos.add(math.vec3(0, 0.6, 0));
                if (handslot_joint) |hj| {
                    if (player_animator) |ah| {
                        if (scene.animator(ah)) |anim| {
                            const char_model = (legend.Transform{
                                .position = player_pos,
                                .rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), player_yaw),
                                .scale = math.vec3(model_scale, model_scale, model_scale),
                            }).matrix();
                            origin = legend.Transform.decompose(char_model.mul(anim.world[hj])).position;
                        }
                    }
                }
                const hitbox = collision.Capsule{
                    .a = origin,
                    .b = origin.add(facing.scale(attack.reach)),
                    .radius = attack.radius,
                };
                dbg.capsule(hitbox, math.vec3(1, 0.2, 0.2));
            }
        }

        try ctx.drawFrame(frame.items, frame.shadow_set, text_items[0..text_count], dbg.lines(), line_vp);
    }

    ctx.waitIdle();
}

/// Turns `current` toward `target` at a rate, taking the short way round.
///
/// Angles wrap, so the naive difference can send a character the long way round
/// for a turn of a few degrees. Folding the difference into -pi..pi first is
/// what makes a turn from 179 to -179 degrees a two-degree step rather than a
/// 358-degree spin.
fn approachAngle(current: f32, target: f32, rate: f32, dt: f32) f32 {
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
fn lerpAngle(a: f32, b: f32, t: f32) f32 {
    var diff = b - a;
    while (diff > std.math.pi) diff -= std.math.tau;
    while (diff < -std.math.pi) diff += std.math.tau;
    return a + diff * t;
}

/// Binds KayKit's shared animation sets to a skeleton by name.
///
/// A KayKit body carries no clips of its own; the animations ship separately,
/// one glb per category, all authored against the same Rig_Medium. Bind them all
/// so any clip -- locomotion, combat, a gesture -- is a clipByName away, the way
/// one rig holds every animation in UE or Unity. Every loaded character needs its
/// own copy, so this runs once per skeleton (the player's, the target's, ...). A
/// rig that already carries clips of its own (Fox, CesiumMan) is left untouched.
fn loadKayKitClips(io: std.Io, gpa: std.mem.Allocator, assets: *Assets, sk: legend.SkeletonHandle) void {
    const rig = assets.skeleton(sk) orelse return;
    if (rig.clips.len != 0) return;

    // Listed rather than globbed: the example is meant to read, and a stray file
    // in the folder should not change what loads.
    const anim_sets = [_][]const u8{
        "assets/gltf/kaykit/Animations/Rig_Medium_General.glb",
        "assets/gltf/kaykit/Animations/Rig_Medium_MovementBasic.glb",
        "assets/gltf/kaykit/Animations/Rig_Medium_MovementAdvanced.glb",
        "assets/gltf/kaykit/Animations/Rig_Medium_CombatMelee.glb",
        "assets/gltf/kaykit/Animations/Rig_Medium_CombatRanged.glb",
        "assets/gltf/kaykit/Animations/Rig_Medium_Simulation.glb",
        "assets/gltf/kaykit/Animations/Rig_Medium_Special.glb",
        "assets/gltf/kaykit/Animations/Rig_Medium_Tools.glb",
    };
    for (anim_sets) |set_path| {
        legend.load_gltf.loadClipsInto(io, gpa, assets, sk, set_path) catch |err| {
            std.debug.print("skipped {s}: {}\n", .{ set_path, err });
        };
    }
}

/// A clip's length, looked up on the rig. Clips belong to the skeleton, times
/// to the animator, so reading one to advance the other needs both.
fn clipDuration(assets: *Assets, skel: ?legend.SkeletonHandle, clip: usize) f32 {
    const sk = skel orelse return 0;
    const rig = assets.skeleton(sk) orelse return 0;
    if (clip >= rig.clips.len) return 0;
    return rig.clips[clip].duration;
}

/// A clip's name, for the overlay.
fn clipName(assets: *Assets, skel: ?legend.SkeletonHandle, clip: usize) []const u8 {
    const sk = skel orelse return "REST";
    const rig = assets.skeleton(sk) orelse return "REST";
    if (clip >= rig.clips.len) return "REST";
    return rig.clips[clip].name;
}

const BoxMesh = struct {
    verts: [24]legend.Vertex,
    indices: [36]u32,
};

/// A drawable box matching a collision box: six faces, each with its own four
/// vertices so every face can carry its own normal. Wound counter-clockwise
/// seen from outside, the direction the pipeline keeps.
fn boxMesh(box: collision.Aabb) BoxMesh {
    const x0 = box.min.x();
    const y0 = box.min.y();
    const z0 = box.min.z();
    const x1 = box.max.x();
    const y1 = box.max.y();
    const z1 = box.max.z();

    const nx_pos = math.vec3(1, 0, 0);
    const nx_neg = math.vec3(-1, 0, 0);
    const ny_pos = math.vec3(0, 1, 0);
    const ny_neg = math.vec3(0, -1, 0);
    const nz_pos = math.vec3(0, 0, 1);
    const nz_neg = math.vec3(0, 0, -1);

    var m: BoxMesh = undefined;
    m.verts = [24]legend.Vertex{
        // +X
        .{ .pos = math.vec3(x1, y0, z1), .uv = math.vec2(0, 0), .normal = nx_pos },
        .{ .pos = math.vec3(x1, y0, z0), .uv = math.vec2(1, 0), .normal = nx_pos },
        .{ .pos = math.vec3(x1, y1, z0), .uv = math.vec2(1, 1), .normal = nx_pos },
        .{ .pos = math.vec3(x1, y1, z1), .uv = math.vec2(0, 1), .normal = nx_pos },
        // -X
        .{ .pos = math.vec3(x0, y0, z0), .uv = math.vec2(0, 0), .normal = nx_neg },
        .{ .pos = math.vec3(x0, y0, z1), .uv = math.vec2(1, 0), .normal = nx_neg },
        .{ .pos = math.vec3(x0, y1, z1), .uv = math.vec2(1, 1), .normal = nx_neg },
        .{ .pos = math.vec3(x0, y1, z0), .uv = math.vec2(0, 1), .normal = nx_neg },
        // +Y
        .{ .pos = math.vec3(x0, y1, z0), .uv = math.vec2(0, 0), .normal = ny_pos },
        .{ .pos = math.vec3(x0, y1, z1), .uv = math.vec2(0, 1), .normal = ny_pos },
        .{ .pos = math.vec3(x1, y1, z1), .uv = math.vec2(1, 1), .normal = ny_pos },
        .{ .pos = math.vec3(x1, y1, z0), .uv = math.vec2(1, 0), .normal = ny_pos },
        // -Y
        .{ .pos = math.vec3(x0, y0, z0), .uv = math.vec2(0, 0), .normal = ny_neg },
        .{ .pos = math.vec3(x1, y0, z0), .uv = math.vec2(1, 0), .normal = ny_neg },
        .{ .pos = math.vec3(x1, y0, z1), .uv = math.vec2(1, 1), .normal = ny_neg },
        .{ .pos = math.vec3(x0, y0, z1), .uv = math.vec2(0, 1), .normal = ny_neg },
        // +Z
        .{ .pos = math.vec3(x0, y0, z1), .uv = math.vec2(0, 0), .normal = nz_pos },
        .{ .pos = math.vec3(x1, y0, z1), .uv = math.vec2(1, 0), .normal = nz_pos },
        .{ .pos = math.vec3(x1, y1, z1), .uv = math.vec2(1, 1), .normal = nz_pos },
        .{ .pos = math.vec3(x0, y1, z1), .uv = math.vec2(0, 1), .normal = nz_pos },
        // -Z
        .{ .pos = math.vec3(x1, y0, z0), .uv = math.vec2(0, 0), .normal = nz_neg },
        .{ .pos = math.vec3(x0, y0, z0), .uv = math.vec2(1, 0), .normal = nz_neg },
        .{ .pos = math.vec3(x0, y1, z0), .uv = math.vec2(1, 1), .normal = nz_neg },
        .{ .pos = math.vec3(x1, y1, z0), .uv = math.vec2(0, 1), .normal = nz_neg },
    };

    var face: u32 = 0;
    while (face < 6) : (face += 1) {
        const v = face * 4;
        const i = face * 6;
        m.indices[i + 0] = v + 0;
        m.indices[i + 1] = v + 1;
        m.indices[i + 2] = v + 2;
        m.indices[i + 3] = v + 0;
        m.indices[i + 4] = v + 2;
        m.indices[i + 5] = v + 3;
    }

    return m;
}
