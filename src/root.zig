//! LegendEngine
//!
//! Layering (each level may only depend on the ones above it):
//!   math     : linear algebra, no dependencies
//!   image    : pixel buffers, QOI / PPM
//!   fiber    : stackful coroutines (substrate for a future job systen)
//!   render   : framebuffer, rasterizer, mesh, camera, clipping
//!   scene    : meshes + objects in generational slot maps
//!   platform : window, input (SDL3)

pub const math = @import("math/math.zig");
pub const image = @import("image/root.zig");
pub const fiber = @import("fiber/root.zig");
pub const gpu = @import("gpu/root.zig");

// -- render -------------------------------------------------------------------------------
const framebuffer = @import("render/framebuffer.zig");
pub const Framebuffer = framebuffer.Framebuffer;
pub const Color = framebuffer.Color;
pub const rgb = framebuffer.rgb;

pub const draw = @import("render/draw.zig");
pub const clip = @import("render/clip.zig");
pub const obj = @import("render/obj.zig");

const mesh_mod = @import("render/mesh.zig");
pub const Mesh = mesh_mod.Mesh;
pub const Vertex = mesh_mod.Vertex;
pub const Transform = mesh_mod.Transform;

pub const Camera = @import("render/camera.zig").Camera;

// -- scene -------------------------------------------------------------------------------
const scene_mod = @import("scene/scene.zig");
pub const Scene = scene_mod.Scene;
pub const Object = scene_mod.Object;
pub const Light = scene_mod.Light;
pub const Material = scene_mod.Material;
pub const Texture = scene_mod.Texture;
pub const MeshHandle = scene_mod.MeshHandle;
pub const MaterialHandle = scene_mod.MaterialHandle;
pub const ObjectHandle = scene_mod.ObjectHandle;

// -- platform -------------------------------------------------------------------------------
const window_mod = @import("platform/window.zig");
pub const Window = window_mod.Window;
pub const Input = window_mod.Input;

pub const FpsCounter = @import("platform/fps.zig").FpsCounter;

test {
    @import("std").testing.refAllDecls(@This());
    _ = math;
    _ = image;
    _ = fiber;
    _ = framebuffer;
    _ = draw;
    _ = clip;
    _ = obj;
    _ = mesh_mod;
    _ = @import("render/camera.zig");
    _ = scene_mod;
    _ = window_mod;
    _ = @import("platform/fps.zig");
    _ = gpu;
}
