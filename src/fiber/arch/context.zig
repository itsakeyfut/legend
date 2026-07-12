const builtin = @import("builtin");

const impl = switch (builtin.cpu.arch) {
    .x86_64 => switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => @import("x86_64_sysv.zig"),
        .macos => @compileError("macOS is not supported yet"),
        .windows => @import("x86_64_win.zig"),
        else => @compileError("Unsupported OS"),
    },
    else => @compileError("Unsupported architecture"),
};

pub const Context = impl.Context;
pub const swap = impl.fiberSwap;
pub const initStack = impl.initStack;
