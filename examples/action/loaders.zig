//! Loading the player and enemy models, binding their clips, and building the
//! player's attacks -- setup that runs once at startup, kept apart from the
//! per-frame lifecycle in `Game`.

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const Assets = legend.Assets;
const Scene = legend.Scene;

const clips = @import("clips.zig");
const Character = @import("Character.zig");
const Combat = @import("Combat.zig");
const Reactions = @import("Reactions.zig");

/// Bundle returned by `loadPlayer`: the character plus everything setup
/// resolved for it (clip lookups, attacks, the sword).
pub const PlayerLoad = struct {
    character: Character,
    clip_idle: ?usize,
    clip_walk: ?usize,
    clip_run: ?usize,
    attacks: [6]Combat.Attack,
    sword_root: ?legend.ObjectHandle,
    handslot_joint: ?usize,
};

/// Loads the player model, binds its clips, builds its attacks, gives it an
/// animator, and loads the sword that rides its hand bone.
pub fn loadPlayer(
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
    var attacks: [6]Combat.Attack = undefined;
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
pub fn loadAttacks(skel: anytype) [6]Combat.Attack {
    var attacks: [6]Combat.Attack = undefined;
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
pub const EnemyLoad = struct {
    character: Character,
    reactions: Reactions,
};

/// Loads a second copy of the player's model to stand in as the enemy
/// target: its own object, skeleton, and animator, so it can hold a
/// different clip at a different moment than the player. It stands and loops
/// -- no movement or control, only its own clock, ticked in the sim loop.
pub fn loadEnemy(
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
