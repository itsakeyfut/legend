//! The static collision world, the capsule that collides against it, and the
//! drawable geometry standing in for the collision boxes.

const std = @import("std");
const legend = @import("legend");
const math = legend.math;
const Assets = legend.Assets;
const Scene = legend.Scene;
const collision = legend.collision;

/// The world the character collides against. The first box is the floor, whose
/// top face is the y = 0 the ground quad is drawn at; the rest are obstacles.
///
/// The staircase rises 0.35 m a tread -- past the capsule's radius, so it is
/// only climbable because the controller steps up, and within its step height,
/// so it is climbable at all. The platform beyond is 1.2 m and still wants a
/// jump. Each stair overlaps the one before it in z rather than meeting it
/// exactly: two faces in the same plane would fight over which is drawn.
pub const world = [_]collision.Aabb{
    .{ .min = math.vec3(-8, -1, -8), .max = math.vec3(8, 0, 8) }, // floor
    .{ .min = math.vec3(3, 0, -4), .max = math.vec3(3.5, 2, 4) }, // long wall
    .{ .min = math.vec3(-3, 0, 1.00), .max = math.vec3(-1, 0.35, 1.60) }, // stair
    .{ .min = math.vec3(-3, 0, 1.55), .max = math.vec3(-1, 0.70, 2.15) }, // stair
    .{ .min = math.vec3(-3, 0, 2.10), .max = math.vec3(-1, 1.05, 2.70) }, // stair
    .{ .min = math.vec3(-3, 0, -3), .max = math.vec3(-1, 1.2, -1) }, // tall platform
    .{ .min = math.vec3(1, 0, -2.2), .max = math.vec3(1.6, 2.5, -1.6) }, // pillar
};

/// The capsule the player collides as, and what it is allowed to walk on.
/// Fixed for the run, so a value copy is enough -- nothing ever mutates it.
pub const controller: collision.Controller = .{ .radius = 0.3, .height = 1.7, .step_height = 0.4 };

/// The ground plane the character walks on, and a drawable box matching each
/// collision box. The floor is skipped: the ground quad already stands in
/// for its top face, and drawing both would have two surfaces fighting over
/// the same plane.
pub fn buildStage(gpa: std.mem.Allocator, assets: *Assets, scene: *Scene) !void {
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
}

const BoxMesh = struct {
    verts: [24]legend.Vertex,
    indices: [36]u32,
};

/// A drawable box matching a collision box: six faces, each with its own four
/// vertices so every face can carry its own normal. Wound counter-clockwise
/// seen from outside, the direction the pipeline keeps.
pub fn boxMesh(box: collision.Aabb) BoxMesh {
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
