//! LegendEngine build. One library module ('legend') covering every subsystem,
//! plus example executables. The only external Zig dependency is `slotmap`;
//! SDL3 is built from source via castholm/SDL, so nothing needs to be
//! installed system-wide.
//!
//! Steps:
//!   zig build run-mesh     -- the Vulkan mesh example
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

    // The engine itself: math, image, fiber, render, scene, platform, gpu.
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
    const shaders = [_][]const u8{ "mesh", "skinned", "shadow", "shadow_skinned", "text" };
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
        .{ .name = "mesh", .step = "run-mesh", .description = "Run the Vulkan mesh example" },
        .{ .name = "gltf", .step = "run-gltf", .description = "Run the glTF loading example" },
        .{ .name = "skinned", .step = "run-skinned", .description = "Run the skinned mesh example" },
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

    // -- tests ---------------------------------------------------------------
    const lib_tests = b.addTest(.{ .root_module = legend_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // -- fmt -----------------------------------------------------------------
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "examples", "build.zig" },
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
///
/// `-matrix-layout-row-major` makes the shader read matrices row-major, matching
/// the engine's row-major Mat4. Without it, Slang defaults to column-major and
/// silently transposes any float4x4 read from a buffer -- invisible at identity,
/// but it turns a posed bone matrix into its transpose (see gpu/skinning.zig).
/// The push-constant MVP dodges this by passing explicit columns, so this flag
/// matters only for real float4x4 buffers like the bone block.
fn compileShader(b: *std.Build, sdk: []const u8, name: []const u8) std.Build.LazyPath {
    const slangc = b.pathJoin(&.{ sdk, "Bin", "slangc" });

    const run = b.addSystemCommand(&.{slangc});
    run.addFileArg(b.path(b.fmt("shaders/{s}.slang", .{name})));
    run.addArg("-matrix-layout-row-major");
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
