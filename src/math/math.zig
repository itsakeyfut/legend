//! Linear-algebra primitives: generic fixed-size vectors and a 4x4 matrix with
//! the usual 3D transforms and a Vulkan-convention perspective projection.

const std = @import("std");

/// Returns a fixed-size vector type of `dim` components of scalar type `T`.
pub fn Vec(comptime dim: usize, comptime T: type) type {
    return struct {
        const Self = @This();
        pub const dimension = dim;
        pub const Scalar = T;

        v: [dim]T,

        /// Vector with every component set to `s`.
        pub fn splat(s: T) Self {
            var r: Self = undefined;
            inline for (0..dim) |i| r.v[i] = s;
            return r;
        }

        /// Component-wise sum.
        pub fn add(a: Self, b: Self) Self {
            var r: Self = undefined;
            inline for (0..dim) |i| r.v[i] = a.v[i] + b.v[i];
            return r;
        }

        /// Component-wise difference.
        pub fn sub(a: Self, b: Self) Self {
            var r: Self = undefined;
            inline for (0..dim) |i| r.v[i] = a.v[i] - b.v[i];
            return r;
        }

        /// Component-wise (Hadamard) product.
        pub fn mul(a: Self, b: Self) Self {
            var r: Self = undefined;
            inline for (0..dim) |i| r.v[i] = a.v[i] * b.v[i];
            return r;
        }

        /// Multiplies every component by scalar `s`.
        pub fn scale(a: Self, s: T) Self {
            var r: Self = undefined;
            inline for (0..dim) |i| r.v[i] = a.v[i] * s;
            return r;
        }

        /// Negates every component.
        pub fn neg(a: Self) Self {
            var r: Self = undefined;
            inline for (0..dim) |i| r.v[i] = -a.v[i];
            return r;
        }

        /// Dot product.
        pub fn dot(a: Self, b: Self) T {
            var acc: T = 0;
            inline for (0..dim) |i| acc += a.v[i] * b.v[i];
            return acc;
        }

        /// Squared magnitude (cheaper than `length`, avoids the sqrt).
        pub fn lengthSq(a: Self) T {
            return a.dot(a);
        }

        /// Euclidean magnitude.
        pub fn length(a: Self) T {
            return @sqrt(a.dot(a));
        }

        /// Unit vector in the same direction. Undefined for a zero vector.
        pub fn normalize(a: Self) Self {
            return a.scale(1.0 / a.length());
        }

        /// Linear interpolation from `a` to `b` by factor `t` in [0, 1].
        pub fn lerp(a: Self, b: Self, t: T) Self {
            var r: Self = undefined;
            inline for (0..dim) |i| r.v[i] = a.v[i] + (b.v[i] - a.v[i]) * t;
            return r;
        }

        /// Cross product; only defined for 3D vectors.
        pub fn cross(a: Self, b: Self) Self {
            comptime {
                if (dim != 3) @compileError("cross is only defined for 3D vectors");
            }
            return .{ .v = .{
                a.v[1] * b.v[2] - a.v[2] * b.v[1],
                a.v[2] * b.v[0] - a.v[0] * b.v[2],
                a.v[0] * b.v[1] - a.v[1] * b.v[0],
            } };
        }

        /// First component.
        pub fn x(a: Self) T {
            comptime {
                if (dim < 1) @compileError("no x component");
            }
            return a.v[0];
        }
        /// Second component.
        pub fn y(a: Self) T {
            comptime {
                if (dim < 2) @compileError("no y component");
            }
            return a.v[1];
        }
        /// Third component.
        pub fn z(a: Self) T {
            comptime {
                if (dim < 3) @compileError("no z component");
            }
            return a.v[2];
        }
        /// Fourth component.
        pub fn w(a: Self) T {
            comptime {
                if (dim < 4) @compileError("no w component");
            }
            return a.v[3];
        }

        /// The first three components as a 3D vector.
        pub fn xyz(a: Self) Vec(3, T) {
            comptime {
                if (dim < 3) @compileError("need at least 3 components");
            }
            return .{ .v = .{ a.v[0], a.v[1], a.v[2] } };
        }

        /// Extends a 3D vector to 4D with the given `w_` component.
        pub fn toVec4(a: Self, w_: T) Vec(4, T) {
            comptime {
                if (dim != 3) @compileError("toVec4 expectes a 3D vector");
            }
            return .{ .v = .{ a.v[0], a.v[1], a.v[2], w_ } };
        }
    };
}

/// 2-component single-precision vector.
pub const Vec2 = Vec(2, f32);
/// 3-component single-precision vector.
pub const Vec3 = Vec(3, f32);
/// 4-component single-precision vector.
pub const Vec4 = Vec(4, f32);

/// Constructs a `Vec2`.
pub fn vec2(x_: f32, y_: f32) Vec2 {
    return .{ .v = .{ x_, y_ } };
}
/// Constructs a `Vec3`.
pub fn vec3(x_: f32, y_: f32, z_: f32) Vec3 {
    return .{ .v = .{ x_, y_, z_ } };
}
/// Constructs a `Vec4`.
pub fn vec4(x_: f32, y_: f32, z_: f32, w_: f32) Vec4 {
    return .{ .v = .{ x_, y_, z_, w_ } };
}

/// Converts degrees to radians.
pub fn radians(deg: f32) f32 {
    return deg * std.math.pi / 180.0;
}

/// Row-major 4x4 single-precision matrix for 3D affine and projective transforms.
pub const Mat4 = struct {
    m: [4][4]f32,

    /// Identity matrix.
    pub fn identity() Mat4 {
        var r: Mat4 = .{ .m = [_][4]f32{[_]f32{0} ** 4} ** 4 };
        inline for (0..4) |i| r.m[i][i] = 1;
        return r;
    }

    /// Matrix product `a * b`.
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        inline for (0..4) |i| {
            inline for (0..4) |j| {
                var s: f32 = 0;
                inline for (0..4) |k| s += a.m[i][k] * b.m[k][j];
                r.m[i][j] = s;
            }
        }
        return r;
    }

    /// Transforms a column vector: `a * vc`.
    pub fn mulVec4(a: Mat4, vc: Vec4) Vec4 {
        var r: Vec4 = undefined;
        inline for (0..4) |i| {
            var s: f32 = 0;
            inline for (0..4) |j| s += a.m[i][j] * vc.v[j];
            r.v[i] = s;
        }
        return r;
    }

    /// Translation matrix by `t`.
    pub fn translation(t: Vec3) Mat4 {
        var r = identity();
        r.m[0][3] = t.x();
        r.m[1][3] = t.y();
        r.m[2][3] = t.z();
        return r;
    }

    /// Non-uniform scaling matrix by per-axis factors `s`.
    pub fn scaling(s: Vec3) Mat4 {
        var r = identity();
        r.m[0][0] = s.x();
        r.m[1][1] = s.y();
        r.m[2][2] = s.z();
        return r;
    }

    /// Rotation matrix about the X axis by `angle` radians.
    pub fn rotationX(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        var r = identity();
        r.m[1][1] = c;
        r.m[1][2] = -s;
        r.m[2][1] = s;
        r.m[2][2] = c;
        return r;
    }

    /// Rotation matrix about the Y axis by `angle` radians.
    pub fn rotationY(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        var r = identity();
        r.m[0][0] = c;
        r.m[0][2] = s;
        r.m[2][0] = -s;
        r.m[2][2] = c;
        return r;
    }

    /// Rotation matrix about the Z axis by `angle` radians.
    pub fn rotationZ(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        var r = identity();
        r.m[0][0] = c;
        r.m[0][1] = -s;
        r.m[1][0] = s;
        r.m[1][1] = c;
        return r;
    }

    /// Perspective projection for Vulkan's clip space: the NDC Y axis points
    /// down, and the depth range is [0, 1]. Both differ from OpenGL, and both
    /// produce a silently blank screen if got wrong.
    ///
    /// `fovy` is the vertical field of view in radians, `aspect` the width/height
    /// ratio, `near`/`far` the clip planes.
    pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fovy * 0.5);
        var r: Mat4 = .{ .m = [_][4]f32{[_]f32{0} ** 4} ** 4 };
        r.m[0][0] = f / aspect;
        r.m[1][1] = -f; // Y down
        r.m[2][2] = far / (near - far);
        r.m[2][3] = (far * near) / (near - far);
        r.m[3][2] = -1;
        return r;
    }

    /// The `j`-th column. Shaders are handed matrices as columns rather than as
    /// a float4x4, so that neither side has to guess how the other stores one.
    pub fn column(a: Mat4, j: usize) Vec4 {
        return .{ .v = .{ a.m[0][j], a.m[1][j], a.m[2][j], a.m[3][j] } };
    }

    /// View matrix placing the camera at `eye` looking toward `center`,
    /// with `up` as the approximate up direction.
    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const fwd = center.sub(eye).normalize();
        const right = fwd.cross(up).normalize();
        const upn = right.cross(fwd);
        var r = identity();
        r.m[0][0] = right.x();
        r.m[0][1] = right.y();
        r.m[0][2] = right.z();
        r.m[0][3] = -right.dot(eye);
        r.m[1][0] = upn.x();
        r.m[1][1] = upn.y();
        r.m[1][2] = upn.z();
        r.m[1][3] = -upn.dot(eye);
        r.m[2][0] = -fwd.x();
        r.m[2][1] = -fwd.y();
        r.m[2][2] = -fwd.z();
        r.m[2][3] = fwd.dot(eye);
        return r;
    }

    /// Inverse-transpose of the upper-left 3x3, for transforming normals.
    ///
    /// A normal is not a direction you can push through the model matrix: under
    /// non-uniform scale the surface tilts one way and its normal must tilt the
    /// *other* way to stay perpendicular. The inverse-transpose does that.
    /// (For a pure rotation it equals the rotation itself, so this is a no-op
    /// in the common case.)
    pub fn normalMatrix(a: Mat4) Mat4 {
        const m = a.m;
        const a00 = m[0][0];
        const a01 = m[0][1];
        const a02 = m[0][2];
        const a10 = m[1][0];
        const a11 = m[1][1];
        const a12 = m[1][2];
        const a20 = m[2][0];
        const a21 = m[2][1];
        const a22 = m[2][2];

        // Cofactor matrix C. Since inverse = adj/det = C^T/det, the
        // inverse-transpose is simply C/det.
        const c00 = a11 * a22 - a12 * a21;
        const c01 = a12 * a20 - a10 * a22;
        const c02 = a10 * a21 - a11 * a20;

        const det = a00 * c00 + a01 * c01 + a02 * c02;
        if (det == 0) return identity(); // degenerate; nothing sensible to do
        const inv_det = 1.0 / det;

        const c10 = a02 * a21 - a01 * a22;
        const c11 = a00 * a22 - a02 * a20;
        const c12 = a01 * a20 - a00 * a21;
        const c20 = a01 * a12 - a02 * a11;
        const c21 = a02 * a10 - a00 * a12;
        const c22 = a00 * a11 - a01 * a10;

        var r = identity();
        r.m[0][0] = c00 * inv_det;
        r.m[0][1] = c01 * inv_det;
        r.m[0][2] = c02 * inv_det;
        r.m[1][0] = c10 * inv_det;
        r.m[1][1] = c11 * inv_det;
        r.m[1][2] = c12 * inv_det;
        r.m[2][0] = c20 * inv_det;
        r.m[2][1] = c21 * inv_det;
        r.m[2][2] = c22 * inv_det;
        return r;
    }
};

test "vec 3 dot / add" {
    const a = vec3(1, 2, 3);
    const b = vec3(4, 5, 6);
    try std.testing.expectApproxEqAbs(@as(f32, 32), a.dot(b), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5), a.add(b).x(), 1e-6);
}

test "vec3 cross (x cross y = z)" {
    const zc = vec3(1, 0, 0).cross(vec3(0, 1, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 1), zc.z(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), zc.x(), 1e-6);
}

test "normalize has unit length" {
    const n = vec3(3, 4, 0).normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 1), n.length(), 1e-6);
}

test "mat4 identity leaves vec unchanged" {
    const r = Mat4.identity().mulVec4(vec4(1, 2, 3, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.x(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3), r.z(), 1e-6);
}

test "mat4 translation moves a point" {
    const t = Mat4.translation(vec3(5, -3, 2)).mulVec4(vec4(0, 0, 0, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 5), t.x(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -3), t.y(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2), t.z(), 1e-6);
}

test "normalMatrix of a pure rotation is the rotation itself" {
    const rot = Mat4.rotationY(radians(37));
    const nm = rot.normalMatrix();
    inline for (0..3) |i| {
        inline for (0..3) |j| {
            try std.testing.expectApproxEqAbs(rot.m[i][j], nm.m[i][j], 1e-5);
        }
    }
}

test "normalMatrix keeps normals perpendicular under non-uniform scale" {
    // Squash Y by half. A 45-degree surface normal must tilt to stay
    // perpendicular to the squashed surface.
    const model = Mat4.scaling(vec3(1, 0.5, 1));
    const nm = model.normalMatrix();

    // A surface tangent in the XY plane, and the normal perpendicular to it.
    const tangent = vec3(1, 1, 0);
    const normal = vec3(1, -1, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tangent.dot(normal), 1e-6);

    // Tangents go through the model matrix; normals through its inverse-transpose.
    const t2 = model.mulVec4(tangent.toVec4(0)).xyz();
    const n2 = nm.mulVec4(normal.toVec4(0)).xyz();
    try std.testing.expectApproxEqAbs(@as(f32, 0), t2.dot(n2), 1e-5);
}

test "perspective maps near to z=0 and far to z=1" {
    const p = Mat4.perspective(radians(60), 1.0, 1.0, 100.0);

    const at_near = p.mulVec4(vec4(0, 0, -1, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 0), at_near.z() / at_near.w(), 1e-5);

    const at_far = p.mulVec4(vec4(0, 0, -100, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 1), at_far.z() / at_far.w(), 1e-5);
}

test "perspective flips Y" {
    const p = Mat4.perspective(radians(60), 1.0, 1.0, 100.0);
    const above = p.mulVec4(vec4(0, 1, -2, 1));
    try std.testing.expect(above.y() / above.w() < 0);
}

test "column extracts a column" {
    const t = Mat4.translation(vec3(5, 6, 7));
    const last = t.column(3);
    try std.testing.expectApproxEqAbs(@as(f32, 5), last.x(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 7), last.z(), 1e-6);
}
