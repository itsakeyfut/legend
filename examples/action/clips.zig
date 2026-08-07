//! KayKit animation-set loading and clip lookups by index.

const std = @import("std");
const legend = @import("legend");
const Assets = legend.Assets;

/// Binds KayKit's shared animation sets to a skeleton by name.
///
/// A KayKit body carries no clips of its own; the animations ship separately,
/// one glb per category, all authored against the same Rig_Medium. Bind them all
/// so any clip -- locomotion, combat, a gesture -- is a clipByName away, the way
/// one rig holds every animation in UE or Unity. Every loaded character needs its
/// own copy, so this runs once per skeleton (the player's, the target's, ...). A
/// rig that already carries clips of its own (Fox, CesiumMan) is left untouched.
pub fn loadKayKitClips(io: std.Io, gpa: std.mem.Allocator, assets: *Assets, sk: legend.SkeletonHandle) void {
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
pub fn clipDuration(assets: *Assets, skel: ?legend.SkeletonHandle, clip: usize) f32 {
    const sk = skel orelse return 0;
    const rig = assets.skeleton(sk) orelse return 0;
    if (clip >= rig.clips.len) return 0;
    return rig.clips[clip].duration;
}

/// A clip's name, for the overlay.
pub fn clipName(assets: *Assets, skel: ?legend.SkeletonHandle, clip: usize) []const u8 {
    const sk = skel orelse return "REST";
    const rig = assets.skeleton(sk) orelse return "REST";
    if (clip >= rig.clips.len) return "REST";
    return rig.clips[clip].name;
}
