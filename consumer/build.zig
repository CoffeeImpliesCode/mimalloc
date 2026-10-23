// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Which delivery of libmimalloc to check. Forwarded to the dependency; " ++
            "it decides the artifact, never anything in this package.",
    ) orelse .static;
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Check the dependency's runtime-loading dispatch instead of a linked " ++
            "one. Forwarded to the dependency. A program built this way has to " ++
            "name a provider with an explicit load() before any native call, " ++
            "which is src/main.zig's business and not this file's.",
    ) orelse false;

    const dep = b.dependency("mimalloc", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime = runtime_loaded,
    });

    // Import only the dependency module; it carries the facade and compiled library.

    // Shared build-graph system options reach the dependency's `systemIntegrationOption`.

    // Keep the consumer's libc requirements in the dependency module.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("mimalloc", dep.module("mimalloc"));

    const exe = b.addExecutable(.{
        .name = "mimalloc-consumer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.has_side_effects = true;
    // Forward provider arguments to the runtime-loaded program.
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Build and run the consumer program");
    run_step.dependOn(&run_exe.step);
}
