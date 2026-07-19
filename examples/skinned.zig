//! Skinned mesh, loaded through the ordinary asset path.
//!
//! CesiumMan is rigged: its mesh carries per-vertex joints and weights, and the
//! file names a skeleton. load_gltf detects the skin, uploads the mesh through
//! the skinning pipeline, builds the skeleton, and binds it to the object --
//! exactly as Duck flows through the static path. buildDrawList then poses the
//! skeleton and routes the object to the skinning shader. At bind pose the
//! skinning matrices are identity, so a correct pipeline shows CesiumMan
//! standing undistorted, upright, with no by-hand correction: the file's own
//! Z-up root node is folded into its world matrix like any other transform.
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
    },
};

/// Flying the camera around to look at the scene. Later this sits alongside a
/// gameplay context that binds the same keys to moving the character.
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
    try legend.load_gltf.load(io, gpa, &assets, &scene, fallback, model_path);

    // The font atlas: white glyphs in the alpha channel, uploaded like any
    // other texture. One upload at startup, then it just sits there.
    const atlas_pixels = try font.buildAtlas(gpa);
    defer gpa.free(atlas_pixels);
    var atlas = try ctx.uploadTexture(atlas_pixels, font.atlas_size, font.atlas_size);
    defer atlas.deinit();

    // A ground plane for the shadow to land on. Without something under the
    // model there is nothing for the light to be blocked from.
    {
        const s: f32 = 4;
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

    // -- loop -------------------------------------------------------------
    // CesiumMan is ~1.6 units tall; sit the camera close.
    var camera = Camera{ .position = math.vec3(0, 1, 3) };
    win.setMouseCaptured(true);

    const move_speed: f32 = 2.0;
    const mouse_sensitivity: f32 = 0.0025;

    var items: [256]gpu.DrawItem = undefined;

    var fps = legend.FpsCounter{};
    var title_buf: [160]u8 = undefined;
    var last_ms = win.ticks();
    var anim_time: f32 = 0;
    var text_items: [512]gpu.TextItem = undefined;
    var input = Input.init();
    input.push(&globals);
    input.push(&free_camera);

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

        camera.move(
            input.value(.move_x) * move_speed * dt,
            input.value(.move_y) * move_speed * dt,
            input.value(.move_z) * move_speed * dt,
        );
        camera.look(
            input.value(.look_x) * mouse_sensitivity,
            input.value(.look_y) * mouse_sensitivity,
        );

        const aspect = @as(f32, @floatFromInt(ctx.swapchain.extent.width)) /
            @as(f32, @floatFromInt(ctx.swapchain.extent.height));

        anim_time += dt;
        if (anim_time > 2.0) anim_time -= 2.0;
        const frame = try legend.buildDrawList(&scene, &assets, &ctx, camera, aspect, anim_time, &items);

        // -- debug overlay -------------------------------------------------
        const screen_w: f32 = @floatFromInt(ctx.swapchain.extent.width);
        const screen_h: f32 = @floatFromInt(ctx.swapchain.extent.height);

        var overlay_buf: [256]u8 = undefined;
        const overlay = std.fmt.bufPrint(&overlay_buf,
            \\FPS {d:.0}
            \\POS {d:.1} {d:.1} {d:.1}
            \\T {d:.2}
        , .{
            fps.fps,
            camera.position.x(),
            camera.position.y(),
            camera.position.z(),
            anim_time,
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
