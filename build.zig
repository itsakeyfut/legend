//! LegendEngine build. One library module ('legend') covering every subsystem,
//! plus example executables. The only external Zig dependency is `slotmap`;
//! SDL3 is built from source via castholm/SDL, so nothing needs to be
//! installed systen-wide.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Generational slot map: entity / resource handles
    const slotmap_dep = b.dependency("slotmap", .{ .target = target, .optimize = optimize });
    const slotmap_mod = slotmap_dep.module("slotmap");

    // SDL3, built from source and exposed as a linkable artifact.
    const sdl_dep = b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const sdl_lib = sdl_dep.artifact("SDL3");

    // The engine itsef: math, image, fiber, render, scene, platform.
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

    // -- examples -------------------------------------------------------------------------------
    const cubes = b.addExecutable(.{
        .name = "cubes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/cubes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "legend", .module = legend_mod },
            },
        }),
    });
    b.installArtifact(cubes);

    const run_cubes = b.addRunArtifact(cubes);
    run_cubes.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cubes.addArgs(args);
    const run_step = b.step("run", "Run the cubes example");
    run_step.dependOn(&run_cubes.step);

    // -- tests -------------------------------------------------------------------------------
    const lib_tests = b.addTest(.{ .root_module = legend_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
