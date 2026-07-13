//! LegendEngine build. One library module ('legend') covering every subsystem,
//! plus example executables. The only external Zig dependency is `slotmap`;
//! SDL3 is built from source via castholm/SDL, so nothing needs to be
//! installed system-wide.
//!
//! Steps:
//!   zig build run-cubes    -- the cubes example
//!   zig build run-model    -- the OBJ model example
//!   zig build run-scene    -- the multi-model scene example
//!   zig build run-triangle -- the Vulkan triangle example
//!   zig build bench-model  -- the model benchmark, ReleaseFast, no frame cap
//!   zig build test         -- unit tests
//!   zig build fmt          -- check formatting
//!   zig build docs         -- generate documentation into zig-out/docs

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Generational slot map: entity / resource handles.
    const slotmap_dep = b.dependency("slotmap", .{ .target = target, .optimize = optimize });
    const slotmap_mod = slotmap_dep.module("slotmap");

    // SDL3, built from source and exposed as a linkable artifact.
    const sdl_dep = b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const sdl_lib = sdl_dep.artifact("SDL3");

    // Vulkan SDK: supplies vulkan.h and the loader import library. The installer
    // sets VULKAN_SDK; -Dvulkan-sdk=<path> overrides it.
    const vulkan_sdk = blk: {
        if (b.option([]const u8, "vulkan-sdk", "Path to the Vulkan SDK")) |p| break :blk p;
        break :blk b.graph.environ_map.get("VULKAN_SDK") orelse std.debug.panic(
            "Vulkan SDK not found: set the VULKAN_SDK environment variable, " ++
                "or pass -Dvulkan-sdk=<path>",
            .{},
        );
    };

    // The engine itself: math, image, fiber, render, scene, platform.
    const legend_mod = b.addModule("legend", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // required by @cImport in platform/window.zig
        .imports = &.{
            .{ .name = "slotmap", .module = slotmap_mod },
        },
    });
    legend_mod.linkLibrary(sdl_lib);
    linkVulkan(b, legend_mod, vulkan_sdk, target);

    // Shaders are compiled to SPIR-V at build time and embedded in the binary:
    // no runtime file loading, and a broken shader fails the build rather than
    // the frame. Add a name here and it is picked up everywhere.
    const shaders = [_][]const u8{"triangle"};
    for (shaders) |name| {
        legend_mod.addAnonymousImport(
            b.fmt("{s}_spv", .{name}),
            .{ .root_source_file = compileShader(b, vulkan_sdk, name) },
        );
    }

    // -- examples ------------------------------------------------------------
    const Example = struct {
        name: []const u8,
        step: []const u8,
        description: []const u8,
    };
    const examples = [_]Example{
        .{ .name = "cubes", .step = "run-cubes", .description = "Run the cubes example" },
        .{ .name = "model", .step = "run-model", .description = "Run the OBJ model example" },
        .{ .name = "scene", .step = "run-scene", .description = "Run the multi-model scene example" },
        .{ .name = "triangle", .step = "run-triangle", .description = "Run the Vulkan triangle example" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "legend", .module = legend_mod },
                },
            }),
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);

        const step = b.step(example.step, example.description);
        step.dependOn(&run.step);
    }

    // -- bench ---------------------------------------------------------------
    // Everything in the bench chain must agree on the optimize level: linking a
    // Debug-built SDL into a ReleaseFast exe leaves UBSan hooks unresolved.
    const bench_sdl_dep = b.dependency("sdl", .{ .target = target, .optimize = .ReleaseFast });
    const bench_sdl_lib = bench_sdl_dep.artifact("SDL3");

    const bench_slotmap_dep = b.dependency("slotmap", .{ .target = target, .optimize = .ReleaseFast });
    const bench_slotmap_mod = bench_slotmap_dep.module("slotmap");

    const bench_engine = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "slotmap", .module = bench_slotmap_mod },
        },
    });

    bench_engine.linkLibrary(bench_sdl_lib);
    linkVulkan(b, bench_engine, vulkan_sdk, target);
    for (shaders) |name| {
        bench_engine.addAnonymousImport(
            b.fmt("{s}_spv", .{name}),
            .{ .root_source_file = compileShader(b, vulkan_sdk, name) },
        );
    }

    // Benches live in benches/, are always ReleaseFast, and run uncapped so the
    // frame limiter does not put a ceiling on the numbers we measure.
    const Bench = struct { name: []const u8 };
    const benches = [_]Bench{
        .{ .name = "model" },
    };

    for (benches) |bench| {
        const bench_exe = b.addExecutable(.{
            .name = b.fmt("bench-{s}", .{bench.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("benches/{s}.zig", .{bench.name})),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "legend", .module = bench_engine },
                },
            }),
        });

        const run_bench = b.addRunArtifact(bench_exe);
        run_bench.addArgs(&.{ "assets/torus.obj", "--uncapped" });
        if (b.args) |args| run_bench.addArgs(args);

        const bench_step = b.step(
            b.fmt("bench-{s}", .{bench.name}),
            b.fmt("Run the {s} benchmark uncapped (always ReleaseFast)", .{bench.name}),
        );
        bench_step.dependOn(&run_bench.step);
    }

    // -- tests ---------------------------------------------------------------
    const lib_tests = b.addTest(.{ .root_module = legend_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // -- fmt -----------------------------------------------------------------
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "examples", "benches", "build.zig" },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt.step);

    // -- docs ----------------------------------------------------------------
    const docs = b.addInstallDirectory(.{
        .source_dir = lib_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation into zig-out/docs");
    docs_step.dependOn(&docs.step);
}

/// Points a module at the Vulkan SDK's headers and loader.
fn linkVulkan(
    b: *std.Build,
    mod: *std.Build.Module,
    sdk: []const u8,
    target: std.Build.ResolvedTarget,
) void {
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Include" }) });
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Lib" }) });
    // The loader is vulkan-1 on Windows and plain vulkan everywhere else.
    const name = if (target.result.os.tag == .windows) "vulkan-1" else "vulkan";
    mod.linkSystemLibrary(name, .{});
}

/// Compiles a Slang shader to SPIR-V. slangc ships with the Vulkan SDK, so
/// there is nothing extra to install. Both entry points go into one module; the
/// pipeline picks them apart by name.
fn compileShader(b: *std.Build, sdk: []const u8, name: []const u8) std.Build.LazyPath {
    const slangc = b.pathJoin(&.{ sdk, "Bin", "slangc" });

    const run = b.addSystemCommand(&.{slangc});
    run.addFileArg(b.path(b.fmt("shaders/{s}.slang", .{name})));
    run.addArgs(&.{
        "-target",  "spirv",
        "-profile", "spirv_1_5",
        "-entry",   "vertexMain",
        "-stage",   "vertex",
        "-entry",   "fragmentMain",
        "-stage",   "fragment",
        "-o",
    });
    return run.addOutputFileArg(b.fmt("{s}.spv", .{name}));
}
