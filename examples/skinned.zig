//! A character you can walk around, with a camera that follows.
//!
//! CesiumMan is rigged: its mesh carries per-vertex joints and weights, and the
//! file names a skeleton, so load_gltf routes it through the skinning pipeline
//! and buildDrawList poses it. What this example adds on top is the shape of a
//! game rather than a viewer -- input that means "walk", a camera that orbits
//! the character, and a second context (F1) that hands the same keys back to a
//! free-flying camera for looking at the scene.
//!
//!   zig build run-skinned
//!   zig build run-skinned -- path/to/model.glb

const std = @import("std");
const legend = @import("legend");

const math = legend.math;
const Camera = legend.Camera;
const gpu = legend.gpu;

const Assets = legend.Assets;
const Scene = legend.Scene;

const text = legend.text;
const font = legend.font;
const action = legend.action;

/// What this example can be asked to do. The engine knows none of these names --
/// they are declared here, and the map is built around them.
const Action = enum {
    move_x,
    move_y,
    move_z,
    look_x,
    look_y,
    toggle_mouse,
    toggle_camera,
    quit,
};

const Input = action.Map(Action);

/// Always active, underneath whatever else is pushed: the keys that mean the
/// same thing no matter what the game is doing.
const globals = Input.Context{
    .name = "globals",
    .bindings = &.{
        .{ .source = .{ .key = .escape }, .action = .quit },
        .{ .source = .{ .key = .tab }, .action = .toggle_mouse },
        .{ .source = .{ .key = .f1 }, .action = .toggle_camera },
    },
};

/// Playing: the keys walk the character. There is no up or down -- a character
/// on the ground does not ascend by pressing space.
const gameplay = Input.Context{
    .name = "gameplay",
    .bindings = &.{
        .{ .source = .{ .key = .d }, .action = .move_x, .scale = 1 },
        .{ .source = .{ .key = .a }, .action = .move_x, .scale = -1 },
        .{ .source = .{ .key = .w }, .action = .move_z, .scale = 1 },
        .{ .source = .{ .key = .s }, .action = .move_z, .scale = -1 },
        .{ .source = .mouse_x, .action = .look_x, .scale = 1 },
        .{ .source = .mouse_y, .action = .look_y, .scale = -1 },
    },
};

/// Inspecting the scene: the same keys, a different meaning. W flies the camera
/// rather than walking the character, and space and shift regain their up and
/// down. Swapped in for `gameplay` rather than stacked on top of it -- only one
/// of the two should ever be answering.
const free_camera = Input.Context{
    .name = "free camera",
    .bindings = &.{
        .{ .source = .{ .key = .d }, .action = .move_x, .scale = 1 },
        .{ .source = .{ .key = .a }, .action = .move_x, .scale = -1 },
        .{ .source = .{ .key = .space }, .action = .move_y, .scale = 1 },
        .{ .source = .{ .key = .lshift }, .action = .move_y, .scale = -1 },
        .{ .source = .{ .key = .w }, .action = .move_z, .scale = 1 },
        .{ .source = .{ .key = .s }, .action = .move_z, .scale = -1 },
        .{ .source = .mouse_x, .action = .look_x, .scale = 1 },
        // Screen y grows downward, and looking down should lower the pitch.
        .{ .source = .mouse_y, .action = .look_y, .scale = -1 },
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const model_path: []const u8 = if (args.len >= 2) args[1] else "assets/gltf/CesiumMan.glb";

    const width: u32 = 960;
    const height: u32 = 640;

    var win = try legend.Window.init("LegendEngine - Skinned", width, height);
    defer win.deinit();

    var ctx = try gpu.Context.init(gpa, &win, width, height);
    defer ctx.deinit(&win);

    var assets = try Assets.init(gpa, &ctx);
    defer assets.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit();

    // CesiumMan's texture is JPEG, which the engine doesn't decode; nodes with
    // no usable base-color texture fall back to this flat tint over white.
    const fallback = math.vec3(0.8, 0.8, 0.85);
    const model = try legend.load_gltf.load(io, gpa, &assets, &scene, fallback, model_path);
    const player = model.root;

    // The font atlas: white glyphs in the alpha channel, uploaded like any
    // other texture. One upload at startup, then it just sits there.
    const atlas_pixels = try font.buildAtlas(gpa);
    defer gpa.free(atlas_pixels);
    var atlas = try ctx.uploadTexture(atlas_pixels, font.atlas_size, font.atlas_size);
    defer atlas.deinit();

    // A ground plane to walk on and for the shadow to land on.
    {
        const s: f32 = 8;
        var ground_verts = [_]legend.Vertex{
            .{ .pos = math.vec3(-s, 0, -s), .uv = math.vec2(0, 0), .normal = math.vec3(0, 1, 0) },
            .{ .pos = math.vec3(-s, 0, s), .uv = math.vec2(0, 1), .normal = math.vec3(0, 1, 0) },
            .{ .pos = math.vec3(s, 0, s), .uv = math.vec2(1, 1), .normal = math.vec3(0, 1, 0) },
            .{ .pos = math.vec3(s, 0, -s), .uv = math.vec2(1, 0), .normal = math.vec3(0, 1, 0) },
        };
        // Wound so the top face is the front face under the pipeline's
        // BACK-cull + CLOCKWISE-front convention; the other order is culled and
        // the plane vanishes when viewed from above.
        var ground_indices = [_]u32{ 0, 2, 1, 0, 3, 2 };

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

    std.debug.print("loaded {s}\n", .{model_path});

    // -- state -------------------------------------------------------------
    // The character's own. The engine has no Player type: a character is an
    // Object with a skeleton, and what moves it is game code.
    var player_pos = math.vec3(0, 0, 0);
    var player_yaw: f32 = 0;
    const walk_speed: f32 = 1.6;
    // How fast the character turns toward where it is going, per second.
    const turn_rate: f32 = 10.0;

    // The follow camera orbits this far from the character, aimed at a point
    // this high on it -- the chest, not the feet, or the view sits on the floor.
    const follow_distance: f32 = 4.0;
    const focus_height: f32 = 1.0;

    // Facing +Z at yaw pi/2, so the camera starts behind a character that also
    // faces +Z. Its position is derived every frame while following, so this is
    // only the starting orbit.
    var camera = Camera{ .yaw = std.math.pi / 2.0 };
    win.setMouseCaptured(true);

    const fly_speed: f32 = 4.0;
    const mouse_sensitivity: f32 = 0.0025;

    var free_look = false;

    var input = Input.init();
    input.push(&globals);
    input.push(&gameplay);

    var items: [256]gpu.DrawItem = undefined;
    var text_items: [512]gpu.TextItem = undefined;

    var fps = legend.FpsCounter{};
    var title_buf: [160]u8 = undefined;
    var last_ms = win.ticks();
    var anim_time: f32 = 0;

    while (true) {
        const now_ms = win.ticks();
        const elapsed_ms = now_ms - last_ms;
        const dt = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
        last_ms = now_ms;

        if (fps.tick(elapsed_ms)) {
            const title = std.fmt.bufPrintZ(
                &title_buf,
                "LegendEngine - Skinned | {d:.1} fps",
                .{fps.fps},
            ) catch "LegendEngine - Skinned";
            win.setTitle(title);
        }

        const raw = win.poll();
        input.update(raw);

        if (raw.quit or input.pressed(.quit)) break;
        if (input.pressed(.toggle_mouse)) win.setMouseCaptured(!win.isMouseCaptured());
        if (input.pressed(.toggle_camera)) {
            free_look = !free_look;
            input.replaceTop(if (free_look) &free_camera else &gameplay);
        }

        // Looking turns the camera in both modes: orbiting the character while
        // playing, aiming the free camera while inspecting.
        camera.look(
            input.value(.look_x) * mouse_sensitivity,
            input.value(.look_y) * mouse_sensitivity,
        );

        if (free_look) {
            camera.move(
                input.value(.move_x) * fly_speed * dt,
                input.value(.move_y) * fly_speed * dt,
                input.value(.move_z) * fly_speed * dt,
            );
        } else {
            // The keys walk the character in the direction the camera faces.
            // This is what makes third-person controls feel right: "forward"
            // means "away from the viewer", not a fixed world axis.
            const mx = input.value(.move_x);
            const mz = input.value(.move_z);
            if (mx != 0 or mz != 0) {
                // The camera's forward, flattened onto the ground: a character
                // walks along the floor even when the view is angled down.
                const cf = camera.forward();
                const flat = math.vec3(cf.x(), 0, cf.z()).normalize();
                const dir = flat.scale(mz).add(camera.right().scale(mx)).normalize();

                player_pos = player_pos.add(dir.scale(walk_speed * dt));

                // Face where the movement is heading, but ease into it rather
                // than snapping -- a body turns, it does not teleport its facing.
                const target_yaw = std.math.atan2(dir.x(), dir.z());
                player_yaw = approachAngle(player_yaw, target_yaw, turn_rate, dt);
            }

            if (scene.object(player)) |obj| {
                obj.transform.position = player_pos;
                obj.transform.rotation = math.Quat.fromAxisAngle(math.vec3(0, 1, 0), player_yaw);
            }

            // The camera hangs behind wherever it is aimed, a fixed distance
            // from the character. Deriving the position from the orbit angles
            // each frame is the whole of the follow logic.
            const focus = player_pos.add(math.vec3(0, focus_height, 0));
            camera.position = focus.sub(camera.forward().scale(follow_distance));
        }

        const aspect = @as(f32, @floatFromInt(ctx.swapchain.extent.width)) /
            @as(f32, @floatFromInt(ctx.swapchain.extent.height));

        anim_time += dt;
        if (anim_time > 2.0) anim_time -= 2.0;
        const frame = try legend.buildDrawList(&scene, &assets, &ctx, camera, aspect, &items);

        // -- debug overlay -------------------------------------------------
        const screen_w: f32 = @floatFromInt(ctx.swapchain.extent.width);
        const screen_h: f32 = @floatFromInt(ctx.swapchain.extent.height);

        var overlay_buf: [256]u8 = undefined;
        const overlay = std.fmt.bufPrint(&overlay_buf,
            \\FPS {d:.0}
            \\MODE {s}
            \\POS {d:.1} {d:.1} {d:.1}
            \\CAM {d:.1} {d:.1} {d:.1}
        , .{
            fps.fps,
            if (free_look) "FREE CAM" else "PLAY",
            player_pos.x(),
            player_pos.y(),
            player_pos.z(),
            camera.position.x(),
            camera.position.y(),
            camera.position.z(),
        }) catch "";

        const text_count = text.layout(
            &text_items,
            atlas.set,
            screen_w,
            screen_h,
            8,
            8,
            2,
            text.yellow,
            overlay,
        );

        try ctx.drawFrame(frame.items, frame.shadow_set, text_items[0..text_count]);
    }

    ctx.waitIdle();
}

/// Turns `current` toward `target` at a rate, taking the short way round.
///
/// Angles wrap, so the naive difference can send a character the long way round
/// for a turn of a few degrees. Folding the difference into -pi..pi first is
/// what makes a turn from 179 to -179 degrees a two-degree step rather than a
/// 358-degree spin.
fn approachAngle(current: f32, target: f32, rate: f32, dt: f32) f32 {
    var diff = target - current;
    while (diff > std.math.pi) diff -= std.math.tau;
    while (diff < -std.math.pi) diff += std.math.tau;
    return current + diff * @min(1.0, rate * dt);
}
