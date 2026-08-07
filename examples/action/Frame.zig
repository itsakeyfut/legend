//! The per-call environment handed to each lifecycle method, so components and
//! systems read shared engine state without each capturing a dozen locals --
//! the role Unity's Time/Physics/Input globals play. hitstop lives on Game,
//! not here (it is written by combat, a Game concern).

const legend = @import("legend");
const Scene = legend.Scene;
const Assets = legend.Assets;
const Camera = legend.Camera;
const collision = legend.collision;

const input_ns = @import("input.zig");
const Tuning = @import("Tuning.zig");

scene: *Scene,
assets: *Assets,
input: *input_ns.Input,
camera: *Camera,
world: []const collision.Aabb,
controller: collision.Controller,
dbg: *legend.Debug,
dt: f32 = 0,
fixed_dt: f32 = 0,
alpha: f32 = 0,
tuning: *const Tuning,
