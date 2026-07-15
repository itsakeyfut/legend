//! A free-look perspective camera.
//!
//! Orientation is stored as yaw/pitch (radians) rather than a matrix, so the
//! camera can be driven directly by input without accumulating drift.

const std = @import("std");
const math = @import("../math/math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const world_up = math.vec3(0, 1, 0);

pub const Camera = struct {
    position: Vec3 = math.vec3(0, 1.5, 9),
    /// Rotation about the world Y axis. -pi/2 faces down -Z.
    yaw: f32 = -std.math.pi / 2.0,
    /// Rotation up (+) / down (-).
    pitch: f32 = 0,
    fov: f32 = math.radians(60),
    near: f32 = 0.1,
    far: f32 = 100.0,

    /// Pitch is clamped short of straight up/down; at exactly +/-90 degrees the
    /// forward vector becomes parallel to world up and `right` would be zero.
    pub const max_pitch: f32 = math.radians(89);

    pub fn forward(self: Camera) Vec3 {
        const cp = @cos(self.pitch);
        return math.vec3(
            cp * @cos(self.yaw),
            @sin(self.pitch),
            cp * @sin(self.yaw),
        ).normalize();
    }

    pub fn right(self: Camera) Vec3 {
        return self.forward().cross(world_up).normalize();
    }

    pub fn up(self: Camera) Vec3 {
        return self.right().cross(self.forward()).normalize();
    }

    pub fn view(self: Camera) Mat4 {
        return Mat4.lookAt(self.position, self.position.add(self.forward()), world_up);
    }

    /// The view-projection for Vulkan's clip space. Kept separate from the
    /// OpenGL-convention one rather than replacing it, so the software renderer
    /// keeps working while the two coexist.
    pub fn viewProjection(self: Camera, aspect: f32) Mat4 {
        return Mat4.perspective(self.fov, aspect, self.near, self.far).mul(self.view());
    }

    /// Moves relative to the camera: `dz` forward, `dx` right, `dy` along world up.
    pub fn move(self: *Camera, dx: f32, dy: f32, dz: f32) void {
        self.position = self.position
            .add(self.forward().scale(dz))
            .add(self.right().scale(dx))
            .add(world_up.scale(dy));
    }

    /// Turns the camera. Pitch is clamped so it can never flip over.
    pub fn look(self: *Camera, dyaw: f32, dpitch: f32) void {
        self.yaw += dyaw;
        self.pitch = std.math.clamp(self.pitch + dpitch, -max_pitch, max_pitch);
    }
};

test "default camera looks down -Z" {
    const cam = Camera{};
    const f = cam.forward();
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.x(), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.y(), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1), f.z(), 1e-5);
}

test "right is +X when looking down -Z" {
    const r = (Camera{}).right();
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.x(), 1e-5);
}

test "pitch is clamped" {
    var cam = Camera{};
    cam.look(0, math.radians(200));
    try std.testing.expect(cam.pitch <= Camera.max_pitch);
}
