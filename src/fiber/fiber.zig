const std = @import("std");
const context = @import("arch/context.zig");
const Context = context.Context;

pub const State = enum { ready, running, suspended, done };

threadlocal var current: ?*Fiber = null;
threadlocal var root_context: Context = .{};

pub const Fiber = struct {
    context: Context = .{},
    stack: []u8,
    entry: *const fn (*Fiber) void,
    state: State = .ready,
    caller: *Context = undefined,
    allocator: std.mem.Allocator,

    const default_stack_size = 64 * 1024; // 64 KiB

    pub fn create(allocator: std.mem.Allocator, entry: *const fn (*Fiber) void) !*Fiber {
        const self = try allocator.create(Fiber);
        errdefer allocator.destroy(self);

        const stack = try allocator.alloc(u8, default_stack_size);
        errdefer allocator.free(stack);

        self.* = .{
            .stack = stack,
            .entry = entry,
            .allocator = allocator,
        };
        self.setupStack();
        return self;
    }

    pub fn destroy(self: *Fiber) void {
        const allocator = self.allocator;
        allocator.free(self.stack);
        allocator.destroy(self);
    }

    pub fn setupStack(self: *Fiber) void {
        self.context.rsp = context.initStack(self.stack, &trampoline, &trampolineTrap);
    }

    pub fn resumeFiber(self: *Fiber) void {
        std.debug.assert(self.state == .ready or self.state == .suspended);

        const caller = if (current) |c| &c.context else &root_context;
        const prev = current;

        self.caller = caller;
        current = self;
        self.state = .running;

        context.swap(caller, &self.context);

        current = prev;
    }

    pub fn yield() void {
        const self = current orelse @panic("yield() called outside of a fiber");
        self.state = .suspended;
        context.swap(&self.context, self.caller);
    }
};

fn trampoline() callconv(.c) void {
    const self = current.?;
    self.entry(self);
    self.state = .done;
    context.swap(&self.context, self.caller);
    unreachable;
}

fn trampolineTrap() callconv(.c) void {
    @panic("fiber trampoline returned unexpectedly");
}

test "fiber runs, yields, and completes" {
    const allocator = std.testing.allocator;

    const S = struct {
        var ticks: usize = 0;
        fn work(_: *Fiber) void {
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                ticks += 1;
                Fiber.yield();
            }
        }
    };
    S.ticks = 0;

    const f = try Fiber.create(allocator, &S.work);
    defer f.destroy();

    var resumes: usize = 0;
    while (f.state != .done) {
        f.resumeFiber();
        resumes += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), S.ticks);
    try std.testing.expectEqual(State.done, f.state);
}

test "xmm6 is preserved across fiber switches" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const S = struct {
        var ok: bool = false;
        fn work(_: *Fiber) void {
            const sentinel: f64 = 1234.5;
            asm volatile ("movsd %[v], %%xmm6"
                :
                : [v] "x" (sentinel),
                : .{ .xmm6 = true });
            Fiber.yield();
            var got: f64 = 0;
            asm volatile ("movsd %%xmm6, %[o]"
                : [o] "=x" (got),
            );
            ok = (got == 1234.5);
        }
    };
    S.ok = false;

    const f = try Fiber.create(allocator, &S.work);
    defer f.destroy();

    while (f.state != .done) {
        // Clobber xmm6 in the caller context between resumes.
        const noise: f64 = 9999.0;
        asm volatile ("movsd %[v], %%xmm6"
            :
            : [v] "x" (noise),
            : .{ .xmm6 = true });
        f.resumeFiber();
    }

    try std.testing.expect(S.ok);
}

test "mxcsr is preserved across fiber switches" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const M = struct {
        fn get() u32 {
            var v: u32 = 0;
            // "m"/"=m" memory constraints mis-lower on this Zig 0.16 /
            // x86_64-windows toolchain (the address gets re-spilled instead
            // of dereferenced). Pass the address explicitly in a register
            // and dereference it in the asm string instead.
            asm volatile ("stmxcsr (%[o])"
                :
                : [o] "r" (&v),
                : .{ .memory = true });
            return v;
        }
        fn set(v: u32) void {
            var local = v;
            asm volatile ("ldmxcsr (%[i])"
                :
                : [i] "r" (&local),
                : .{ .memory = true });
        }
    };

    const S = struct {
        var ok: bool = false;
        var saved_default: u32 = 0;
        fn work(_: *Fiber) void {
            // Round-toward-zero = rounding-control bits (13-14) set.
            const rc_toward_zero: u32 = (M.get() & ~@as(u32, 0x6000)) | 0x6000;
            M.set(rc_toward_zero);
            Fiber.yield();
            ok = (M.get() & 0x6000) == 0x6000;
            M.set(saved_default); // restore for the test runner
        }
    };
    S.ok = false;
    S.saved_default = M.get();

    const f = try Fiber.create(allocator, &S.work);
    defer f.destroy();

    while (f.state != .done) {
        M.set(S.saved_default & ~@as(u32, 0x6000)); // round-to-nearest in caller
        f.resumeFiber();
    }
    M.set(S.saved_default);

    try std.testing.expect(S.ok);
}
