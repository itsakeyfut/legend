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

const gpu = legend.gpu;
const Assets = legend.Assets;
const Scene = legend.Scene;
const font = legend.font;

const Game = @import("Game.zig");

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
