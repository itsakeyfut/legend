pub const Context = extern struct { rsp: usize = 0 };

fn fiberSwapNaked() callconv(.naked) void {
    // Win64: from = %rcx, to = %rdx
    asm volatile (
        \\  pushq %%rbx
        \\  pushq %%rbp
        \\  pushq %%rdi
        \\  pushq %%rsi
        \\  pushq %%r12
        \\  pushq %%r13
        \\  pushq %%r14
        \\  pushq %%r15
        \\  // MXCSR (+0) and x87 control word (+8) in a 16-byte slot
        \\  subq $16, %%rsp
        \\  stmxcsr 0(%%rsp)
        \\  fnstcw 8(%%rsp)
        \\  // XMM6-XMM15 (160 bytes)
        \\  subq $160, %%rsp
        \\  movups %%xmm6,    0(%%rsp)
        \\  movups %%xmm7,   16(%%rsp)
        \\  movups %%xmm8,   32(%%rsp)
        \\  movups %%xmm9,   48(%%rsp)
        \\  movups %%xmm10,  64(%%rsp)
        \\  movups %%xmm11,  80(%%rsp)
        \\  movups %%xmm12,  96(%%rsp)
        \\  movups %%xmm13, 112(%%rsp)
        \\  movups %%xmm14, 128(%%rsp)
        \\  movups %%xmm15, 144(%%rsp)
        \\  // TIB stack bounds: StackBase, StackLimit, DeallocationStack
        \\  movq %%gs:0x08, %%rax
        \\  pushq %%rax
        \\  movq %%gs:0x10, %%rax
        \\  pushq %%rax
        \\  movq %%gs:0x1478, %%rax
        \\  pushq %%rax
        \\  // switch stacks
        \\  movq %%rsp, (%%rcx)
        \\  movq (%%rdx), %%rsp
        \\  // restore TIB (reverse order)
        \\  popq %%rax
        \\  movq %%rax, %%gs:0x1478
        \\  popq %%rax
        \\  movq %%rax, %%gs:0x10
        \\  popq %%rax
        \\  movq %%rax, %%gs:0x08
        \\  // restore XMM
        \\  movups    0(%%rsp), %%xmm6
        \\  movups   16(%%rsp), %%xmm7
        \\  movups   32(%%rsp), %%xmm8
        \\  movups   48(%%rsp), %%xmm9
        \\  movups   64(%%rsp), %%xmm10
        \\  movups   80(%%rsp), %%xmm11
        \\  movups   96(%%rsp), %%xmm12
        \\  movups  112(%%rsp), %%xmm13
        \\  movups  128(%%rsp), %%xmm14
        \\  movups  144(%%rsp), %%xmm15
        \\  addq $160, %%rsp
        \\  // restore MXCSR + x87 control word
        \\  ldmxcsr 0(%%rsp)
        \\  fldcw 8(%%rsp)
        \\  addq $16, %%rsp
        \\  popq %%r15
        \\  popq %%r14
        \\  popq %%r13
        \\  popq %%r12
        \\  popq %%rsi
        \\  popq %%rdi
        \\  popq %%rbp
        \\  popq %%rbx
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
    const base = @intFromPtr(stack.ptr);
    const top = base + stack.len;
    var sp = top & ~@as(usize, 0xF); // 16-byte aligned

    // Return addresses: trap (outer) then entry (fiberSwap `ret` target).
    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = @intFromPtr(trap);
    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = @intFromPtr(entry);

    // 8 callee-saved GP slots (rbx, rbp, rdi, rsi, r12-r15), all zero.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        sp -= @sizeOf(usize);
        @as(*usize, @ptrFromInt(sp)).* = 0;
    }

    // MXCSR (+0) / x87 control word (+8) 16-byte slot with defaults.
    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = 0x0000037F; // x87 control word (slot+8)
    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = 0x00001F80; // MXCSR (slot+0)

    // XMM6-XMM15 save area: 160 bytes = 20 usize slots, all zero.
    i = 0;
    while (i < 20) : (i += 1) {
        sp -= @sizeOf(usize);
        @as(*usize, @ptrFromInt(sp)).* = 0;
    }

    // TIB stack bounds, mirroring push order: StackBase, StackLimit, DeallocationStack.
    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = top; // StackBase (high)
    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = base; // StackLimit (low)
    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = base; // DeallocationStack (low)

    return sp;
}
