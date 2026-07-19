//! Turning physical input into what the game means.
//!
//! Game code should never ask whether W is down. It asks whether "move forward"
//! is active, and something else decides that W means forward -- because the
//! same key means different things at different moments. While playing, W walks
//! the character; while inspecting the scene, W flies the camera. One physical
//! key, two meanings, chosen by which context is on top.
//!
//! This is the shape Unreal's Enhanced Input (mapping contexts) and Unity's
//! Input System (action maps) both take. What differs here is where the actions
//! live: they are an enum the game declares, handed to this file as a type
//! parameter. State is then a fixed array indexed by @intFromEnum -- no asset to
//! load, no string to look up, and a misspelt action is a compile error rather
//! than an action that silently never fires.

const std = @import("std");

const window = @import("window.zig");
const Key = window.Key;
const Raw = window.Raw;

/// Where an action's value comes from.
pub const Source = union(enum) {
    /// A key contributes its scale while held.
    key: Key,
    /// Mouse motion this frame, in pixels. Already a delta -- never scale it by
    /// frame time.
    mouse_x,
    mouse_y,
};

/// The most contexts that may be stacked at once. Four is generous: gameplay,
/// a menu over it, a debug overlay over that, and the always-on globals
/// underneath.
pub const max_contexts = 4;

/// Builds an action map for the actions a game declares.
///
///     const Action = enum { move_x, move_y, look_x, look_y, jump };
///     var input = legend.action.Map(Action).init();
pub fn Map(comptime Action: type) type {
    const info = @typeInfo(Action);
    if (info != .@"enum") @compileError("Action must be an enum");
    const count = info.@"enum".fields.len;

    return struct {
        const Self = @This();

        /// One physical source feeding one action, scaled. A key bound at -1 and
        /// another at +1 make an axis: hold both and they cancel, which is what
        /// pressing left and right together should do.
        pub const Binding = struct {
            source: Source,
            action: Action,
            scale: f32 = 1,
        };

        /// A named set of bindings. Contexts are pushed and popped; the topmost
        /// one that binds a given source is the one that gets it, so a menu can
        /// take W without the gameplay context also seeing it.
        pub const Context = struct {
            name: []const u8,
            bindings: []const Binding,
        };

        /// This frame's value per action, and last frame's, so edges can be
        /// derived rather than tracked separately.
        values: [count]f32 = .{0} ** count,
        previous: [count]f32 = .{0} ** count,

        stack: [max_contexts]*const Context = undefined,
        depth: usize = 0,

        pub fn init() Self {
            return .{};
        }

        /// Puts a context on top. Later pushes win over earlier ones.
        pub fn push(self: *Self, ctx: *const Context) void {
            if (self.depth >= max_contexts) return;
            self.stack[self.depth] = ctx;
            self.depth += 1;
        }

        pub fn pop(self: *Self) void {
            if (self.depth > 0) self.depth -= 1;
        }

        /// Replaces the topmost context, keeping whatever is underneath. This is
        /// how a mode switch works: swap gameplay for free-camera, leave the
        /// globals in place.
        pub fn replaceTop(self: *Self, ctx: *const Context) void {
            if (self.depth == 0) {
                self.push(ctx);
                return;
            }
            self.stack[self.depth - 1] = ctx;
        }

        /// Recomputes every action from this frame's physical state.
        ///
        /// Sources are resolved from the top of the stack down, and the first
        /// context that binds a source consumes it -- a key claimed by a menu
        /// never reaches the gameplay beneath.
        pub fn update(self: *Self, raw: Raw) void {
            self.previous = self.values;
            self.values = .{0} ** count;

            var claimed_keys = [_]bool{false} ** window.key_count;
            var claimed_mouse_x = false;
            var claimed_mouse_y = false;

            var i = self.depth;
            while (i > 0) {
                i -= 1;
                const ctx = self.stack[i];
                for (ctx.bindings) |binding| {
                    const slot = @intFromEnum(binding.action);
                    switch (binding.source) {
                        .key => |key| {
                            const k = @intFromEnum(key);
                            if (claimed_keys[k]) continue;
                            if (raw.down(key)) self.values[slot] += binding.scale;
                        },
                        .mouse_x => {
                            if (claimed_mouse_x) continue;
                            self.values[slot] += raw.mouse_dx * binding.scale;
                        },
                        .mouse_y => {
                            if (claimed_mouse_y) continue;
                            self.values[slot] += raw.mouse_dy * binding.scale;
                        },
                    }
                }
                // Claiming happens after the whole context, so two bindings
                // within one context can both feed the same source.
                for (ctx.bindings) |binding| {
                    switch (binding.source) {
                        .key => |key| claimed_keys[@intFromEnum(key)] = true,
                        .mouse_x => claimed_mouse_x = true,
                        .mouse_y => claimed_mouse_y = true,
                    }
                }
            }
        }

        /// The action's value: 0 or 1 for a button, -1..1 for a two-key axis,
        /// pixels for mouse motion.
        pub fn value(self: Self, action: Action) f32 {
            return self.values[@intFromEnum(action)];
        }

        /// True while the action is active at all.
        pub fn held(self: Self, action: Action) bool {
            return self.values[@intFromEnum(action)] != 0;
        }

        /// True only on the frame the action became active.
        pub fn pressed(self: Self, action: Action) bool {
            const i = @intFromEnum(action);
            return self.values[i] != 0 and self.previous[i] == 0;
        }

        /// True only on the frame the action stopped being active.
        pub fn released(self: Self, action: Action) bool {
            const i = @intFromEnum(action);
            return self.values[i] == 0 and self.previous[i] != 0;
        }
    };
}

// -- tests -------------------------------------------------------------------

const TestAction = enum { move_x, move_y, jump, look_x };
const TestMap = Map(TestAction);

fn rawWith(keys: []const Key) Raw {
    var raw = Raw{};
    for (keys) |k| raw.keys[@intFromEnum(k)] = true;
    return raw;
}

test "two keys on one action make an axis" {
    const ctx = TestMap.Context{
        .name = "test",
        .bindings = &.{
            .{ .source = .{ .key = .d }, .action = .move_x, .scale = 1 },
            .{ .source = .{ .key = .a }, .action = .move_x, .scale = -1 },
        },
    };

    var map = TestMap.init();
    map.push(&ctx);

    map.update(rawWith(&.{.d}));
    try std.testing.expectEqual(@as(f32, 1), map.value(.move_x));

    map.update(rawWith(&.{.a}));
    try std.testing.expectEqual(@as(f32, -1), map.value(.move_x));

    // Both at once cancel, which is what holding left and right should do.
    map.update(rawWith(&.{ .a, .d }));
    try std.testing.expectEqual(@as(f32, 0), map.value(.move_x));
}

test "edges come from the change between frames" {
    const ctx = TestMap.Context{
        .name = "test",
        .bindings = &.{.{ .source = .{ .key = .space }, .action = .jump }},
    };

    var map = TestMap.init();
    map.push(&ctx);

    map.update(rawWith(&.{}));
    try std.testing.expect(!map.pressed(.jump));

    map.update(rawWith(&.{.space}));
    try std.testing.expect(map.pressed(.jump));
    try std.testing.expect(map.held(.jump));

    // Held down: no longer a press, still held.
    map.update(rawWith(&.{.space}));
    try std.testing.expect(!map.pressed(.jump));
    try std.testing.expect(map.held(.jump));

    map.update(rawWith(&.{}));
    try std.testing.expect(map.released(.jump));
    try std.testing.expect(!map.held(.jump));
}

test "the topmost context claims a key from the ones below" {
    const gameplay = TestMap.Context{
        .name = "gameplay",
        .bindings = &.{.{ .source = .{ .key = .w }, .action = .move_y }},
    };
    const menu = TestMap.Context{
        .name = "menu",
        .bindings = &.{.{ .source = .{ .key = .w }, .action = .jump }},
    };

    var map = TestMap.init();
    map.push(&gameplay);
    map.update(rawWith(&.{.w}));
    try std.testing.expectEqual(@as(f32, 1), map.value(.move_y));
    try std.testing.expectEqual(@as(f32, 0), map.value(.jump));

    // With the menu on top, W means jump and gameplay never sees it.
    map.push(&menu);
    map.update(rawWith(&.{.w}));
    try std.testing.expectEqual(@as(f32, 0), map.value(.move_y));
    try std.testing.expectEqual(@as(f32, 1), map.value(.jump));

    // Popping hands it back.
    map.pop();
    map.update(rawWith(&.{.w}));
    try std.testing.expectEqual(@as(f32, 1), map.value(.move_y));
}

test "mouse motion feeds an action unscaled by anything but its binding" {
    const ctx = TestMap.Context{
        .name = "test",
        .bindings = &.{.{ .source = .mouse_x, .action = .look_x, .scale = 0.5 }},
    };

    var map = TestMap.init();
    map.push(&ctx);

    var raw = Raw{};
    raw.mouse_dx = 10;
    map.update(raw);
    try std.testing.expectEqual(@as(f32, 5), map.value(.look_x));
}
