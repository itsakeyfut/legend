//! LegendEngine
//!
//! Layering (each level may only depend on the ones above it):
//!   math      : linear algebra, no dependencies
//!   image     : pixel buffers, QOI / PPM
//!   render    : mesh, camera, transforms, OBJ loading
//!   scene     : meshes + objects in generational slot maps
//!   platform  : window, input, the single C import (SDL3 + Vulkan)
//!   gpu       : Vulkan. The real renderer.
//!   collision : capsule/AABB queries for a kinematic character controller
//!
//! `fiber` (stackful coroutines, the substrate for a future job system) lives in
//! its own repository now and is re-exported here as a dependency.

pub const math = @import("math/math.zig");
pub const image = @import("image/root.zig");
pub const fiber = @import("fiber");
pub const gpu = @import("gpu/root.zig");

// -- render -------------------------------------------------------------------------------
const mesh_mod = @import("render/mesh.zig");
pub const Mesh = mesh_mod.Mesh;
pub const Vertex = mesh_mod.Vertex;
pub const Transform = mesh_mod.Transform;

pub const obj = @import("render/obj.zig");
pub const Camera = @import("render/camera.zig").Camera;

pub const gltf = @import("render/gltf.zig");
pub const font = @import("render/font.zig");
pub const text = @import("render/text.zig");

// -- scene -------------------------------------------------------------------------------
const assets_mod = @import("scene/assets.zig");
pub const Assets = assets_mod.Assets;
pub const MeshHandle = assets_mod.MeshHandle;
pub const TextureHandle = assets_mod.TextureHandle;

const scene_mod = @import("scene/scene.zig");
pub const Scene = scene_mod.Scene;
pub const Object = scene_mod.Object;
pub const Light = scene_mod.Light;
pub const Material = scene_mod.Material;
pub const MaterialHandle = scene_mod.MaterialHandle;
pub const ObjectHandle = scene_mod.ObjectHandle;

pub const load_gltf = @import("scene/load_gltf.zig");

const render_mod = @import("scene/render.zig");
pub const Frame = render_mod.Frame;
pub const buildDrawList = render_mod.buildDrawList;

pub const skeleton = @import("scene/skeleton.zig");

// -- platform -------------------------------------------------------------------------------
const window_mod = @import("platform/window.zig");
pub const Window = window_mod.Window;
pub const Key = window_mod.Key;
pub const RawInput = window_mod.Raw;

pub const FpsCounter = @import("platform/fps.zig").FpsCounter;
pub const action = @import("platform/action.zig");
pub const FixedTimestep = @import("platform/timestep.zig").FixedTimestep;

// -- collision ------------------------------------------------------------------------------
pub const collision = @import("collision/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = math;
    _ = image;
    _ = obj;
    _ = mesh_mod;
    _ = @import("render/camera.zig");
    _ = @import("render/gltf.zig");
    _ = @import("render/font.zig");
    _ = @import("render/text.zig");
    _ = scene_mod;
    _ = window_mod;
    _ = @import("platform/fps.zig");
    _ = @import("platform/action.zig");
    _ = @import("platform/timestep.zig");
    _ = gpu;
    _ = @import("scene/render.zig");
    _ = @import("scene/load_gltf.zig");
    _ = @import("scene/skeleton.zig");
    _ = @import("collision/root.zig");
}
