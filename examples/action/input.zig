//! What this example can be asked to do, and the input contexts that map
//! keys/mouse to it. The engine knows none of these names -- they are
//! declared here, and the map is built around them.

const legend = @import("legend");
const action = legend.action;

/// What this example can be asked to do. The engine knows none of these names --
/// they are declared here, and the map is built around them.
pub const Action = enum {
    move_x,
    move_y,
    move_z,
    look_x,
    look_y,
    toggle_mouse,
    toggle_camera,
    sprint,
    jump,
    quit,
    attack_slice,
    attack_chop,
    attack_stab,
    toggle_collision,
    toggle_stats,
};

pub const Input = action.Map(Action);

/// Always active, underneath whatever else is pushed: the keys that mean the
/// same thing no matter what the game is doing.
pub const globals = Input.Context{
    .name = "globals",
    .bindings = &.{
        .{ .source = .{ .key = .escape }, .action = .quit },
        .{ .source = .{ .key = .tab }, .action = .toggle_mouse },
        .{ .source = .{ .key = .f1 }, .action = .toggle_camera },
    },
};

/// Playing: the keys walk the character. Space is a jump, not an ascent -- the
/// character leaves the ground under its own speed and gravity brings it back.
pub const gameplay = Input.Context{
    .name = "gameplay",
    .bindings = &.{
        .{ .source = .{ .key = .d }, .action = .move_x, .scale = 1 },
        .{ .source = .{ .key = .a }, .action = .move_x, .scale = -1 },
        .{ .source = .{ .key = .w }, .action = .move_z, .scale = 1 },
        .{ .source = .{ .key = .s }, .action = .move_z, .scale = -1 },
        .{ .source = .{ .mouse_button = .right }, .action = .sprint },
        .{ .source = .{ .key = .space }, .action = .jump },
        .{ .source = .{ .mouse_button = .left }, .action = .attack_slice },
        .{ .source = .{ .key = .q }, .action = .attack_chop },
        .{ .source = .{ .key = .e }, .action = .attack_stab },
        .{ .source = .mouse_x, .action = .look_x, .scale = 1 },
        .{ .source = .mouse_y, .action = .look_y, .scale = -1 },
        .{ .source = .{ .key = .f2 }, .action = .toggle_collision },
        .{ .source = .{ .key = .f3 }, .action = .toggle_stats },
    },
};

/// Inspecting the scene: the same keys, a different meaning. W flies the camera
/// rather than walking the character, and space and shift regain their up and
/// down. Swapped in for `gameplay` rather than stacked on top of it -- only one
/// of the two should ever be answering.
pub const free_camera = Input.Context{
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
