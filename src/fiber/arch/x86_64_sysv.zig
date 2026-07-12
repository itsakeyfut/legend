pub const Context = extern struct { rsp: usize = 0 };

fn fiberSwapNaked() callconv(.naked) void {
    asm volatile (
        \\  pushq %%rbp
        \\  pushq %%rbx
        \\  pushq %%r12
        \\  pushq %%r13
        \\  pushq %%r14
        \\  pushq %%r15
        \\  movq %%rsp, (%%rdi)
        \\  movq (%%rsi), %%rsp
        \\  popq %%r15
        \\  popq %%r14
        \\  popq %%r13
        \\  popq %%r12
        \\  popq %%rbx
        \\  popq %%rbp
        \\  ret
    );
}

pub fn fiberSwap(from: *Context, to: *Context) callconv(.c) void {
    const f: *const fn (*Context, *Context) callconv(.c) void = @ptrCast(&fiberSwapNaked);
    f(from, to);
}

pub fn initStack(
    stack: []u8,
    entry: *const fn () callconv(.c) void,
    trap: *const fn () callconv(.c) void,
) usize {
    const top = @intFromPtr(stack.ptr) + stack.len;
    var sp = top & ~@as(usize, 0xF); // 16-byte aligned

    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = @intFromPtr(trap);

    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = @intFromPtr(entry);

    // 6 callee-saved GP slots (r15, r14, r13, r12, rbx, rbp)
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        sp -= @sizeOf(usize);
        @as(*usize, @ptrFromInt(sp)).* = 0;
    }

    return sp;
}
