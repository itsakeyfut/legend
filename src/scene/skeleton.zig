//! Turning a glTF skin into the joint matrices a skinned mesh needs.
//!
//! gltf.zig read the skin as neutral data: which nodes are joints, and each
//! joint's inverse bind matrix. This file does the rest -- walk the node
//! hierarchy to each joint's world transform, then combine it with the inverse
//! bind matrix into the "skinning matrix" the vertex shader multiplies vertices
//! by.
//!
//! The skinning matrix for joint j is  world(j) * inverseBind(j).  In the bind
//! pose the two are inverses, so the product is (near) identity and the vertex
//! does not move -- which is exactly the check S-2 leans on: build this, render
//! it static, and a correct pipeline shows the model standing in its bind pose.

const std = @import("std");
const math = @import("../math/math.zig");
const gltf = @import("../render/gltf.zig");

const Mat4 = math.Mat4;

/// One joint's place in the skeleton: its local transform, and its parent among
/// the joints (or null if it is a root joint). Built from the glTF node tree.
pub const Joint = struct {
    local: Mat4,
    /// Index into the skeleton's joint array, or null for a root.
    parent: ?usize,
};

/// A skeleton ready to pose: the joints in skin order, their inverse binds, and
/// scratch space for the matrices handed to the GPU. Owns its allocations.
pub const Skeleton = struct {
    joints: []Joint,
    inverse_binds: []Mat4,
    /// The skinning matrices, recomputed each pose. One per joint.
    skinning: []Mat4,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Skeleton) void {
        self.allocator.free(self.joints);
        self.allocator.free(self.inverse_binds);
        self.allocator.free(self.skinning);
        self.* = undefined;
    }

    /// Recomputes every joint's skinning matrix for the current local transforms.
    /// world(j) is accumulated down the parent chain; skinning is world * invBind.
    pub fn pose(self: *Skeleton) void {
        // First pass: each joint's world matrix. Joints are stored parents-first
        // (glTF orders them so a parent precedes its children within the skin),
        // so a single forward pass can read its parent's already-computed world.
        var world = self.allocator.alloc(Mat4, self.joints.len) catch return;
        defer self.allocator.free(world);

        for (self.joints, 0..) |joint, j| {
            if (joint.parent) |p| {
                world[j] = world[p].mul(joint.local);
            } else {
                world[j] = joint.local;
            }
        }

        // Second pass: skinning = world * inverseBind.
        for (0..self.joints.len) |j| {
            self.skinning[j] = world[j].mul(self.inverse_binds[j]);
        }
    }
};

/// Builds a Skeleton from a glTF skin and the file's node hierarchy. The skin
/// names joints by node index; this resolves each to its local transform and its
/// parent *within the skin*, so posing needs only the joint array.
pub fn build(
    allocator: std.mem.Allocator,
    skin: gltf.Skin,
    scene: gltf.Scene,
) !Skeleton {
    const n = skin.joints.len;

    // Map node index -> joint index, so parent lookups can be expressed in joint
    // space. A node that is not a joint maps to nothing.
    // (Small n, so a linear search per node would do; the map is clearer.)
    var node_to_joint = try allocator.alloc(?usize, scene.nodes.len);
    defer allocator.free(node_to_joint);
    for (node_to_joint) |*e| e.* = null;
    for (skin.joints, 0..) |node_idx, j| {
        if (node_idx < scene.nodes.len) node_to_joint[node_idx] = j;
    }

    const joints = try allocator.alloc(Joint, n);
    errdefer allocator.free(joints);

    for (skin.joints, 0..) |node_idx, j| {
        const node = scene.nodes[node_idx];
        // A joint's parent among the joints: find which node lists it as a child.
        // glTF stores children on the parent, so this searches for the node whose
        // children include node_idx, then maps that to a joint (if it is one).
        var parent: ?usize = null;
        for (scene.nodes, 0..) |candidate, ci| {
            for (candidate.children) |child| {
                if (child == node_idx) {
                    parent = node_to_joint[ci];
                    break;
                }
            }
            if (parent != null) break;
        }
        joints[j] = .{ .local = node.transform.matrix(), .parent = parent };
    }

    const inverse_binds = try allocator.alloc(Mat4, n);
    errdefer allocator.free(inverse_binds);
    @memcpy(inverse_binds, skin.inverse_binds);

    const skinning = try allocator.alloc(Mat4, n);
    errdefer allocator.free(skinning);
    // Pose once so the matrices are valid even before the first explicit pose().
    var skel = Skeleton{
        .joints = joints,
        .inverse_binds = inverse_binds,
        .skinning = skinning,
        .allocator = allocator,
    };
    skel.pose();
    return skel;
}

test "skeleton bind pose yields near-identity skinning" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const file = std.Io.Dir.cwd().openFile(io, "assets/gltf/CesiumMan.glb", .{}) catch |err| {
        std.debug.print("skipping skeleton test: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const bytes = try a.alloc(u8, size);
    defer a.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    const glb = try gltf.parseGlb(bytes);
    var gscene = try gltf.parseScene(a, glb);
    defer gscene.deinit();
    var skin = try gltf.parseSkin(a, glb, 0);
    defer skin.deinit();

    var skel = try build(a, skin, gscene);
    defer skel.deinit();

    // Bind pose: world(j) * inverseBind(j) should be identity for every joint,
    // because the joint's current world transform *is* the bind pose the inverse
    // bind was made from. If this holds, the skinning maths is correct and a
    // static render will show the bind pose undistorted.
    for (skel.skinning) |m| {
        inline for (0..4) |r| {
            inline for (0..4) |c| {
                const expected: f32 = if (r == c) 1 else 0;
                try std.testing.expectApproxEqAbs(expected, m.m[r][c], 1e-3);
            }
        }
    }
}
