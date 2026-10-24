// SPDX-License-Identifier: MIT
const std = @import("std");

/// Must match `RT_SYNC_PREFIX` in `runtime/sync.c`.
const sync_prefix = "mimalloc_rt";

// `libc_noise` lists libc declarations reached through `zig/translate.h`.
// Zig 0.16 citations (not rechecked on 0.17):
// `assert.h`: generic-glibc:95,100,107,115; generic-musl:19; generic-freebsd:81; generic-netbsd:101-104; generic-openbsd:70-71; any-darwin-any/_assert.h:63; any-windows-any/assert.h:24-25.
// `stddef.h`: any-windows-any:18,20,21,24,26; generic-openbsd:78-79.
const libc_noise =
    \\__assert,__assert13,__assert2,__assert_fail,__assert_perror_fail,__assert_rtn,
    \\__assert_single_arg,__diagassert,__diagassert13,_assert,_errno,_get_errno,
    \\_set_errno,_wassert,__threadhandle,__threadid,__max_align_ld,__max_align_ll,
    \\
;

// Every provider entry point is required except unsupported declarations below.
const provider_optional = "";

// Two v3.5.3 declarations lack definitions; the size aliases require MI_MALLOC_OVERRIDE.
// `src/alloc-override.c:13,328-336` gates both aliases behind allocator interposition.
const provider_excluded = "mi_collect_reduce,mi_stats_merge,mi_malloc_size,mi_malloc_usable_size";

/// Creates the loader core for a statically linked build.
/// Runtime mode imports its single core through the generated dispatch.
pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("runtime/loader.zig"),
        .target = target,
        .optimize = optimize,
        // The Unix loader uses libc; lazy analysis drops it from linked builds.
        .link_libc = true,
    });
}

/// Creates the runtime-loaded `c` module from the selected target's translation.
/// Do not also link the native archive; dispatch calls go through this module.
pub fn createModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    const core = createCoreModule(b, target, optimize);

    const library = b.createModule(.{
        .root_source_file = b.path("runtime/library.zig"),
        .target = target,
        .optimize = optimize,
    });
    library.addImport("rt", core);

    return createDispatchModule(b, translate, target, optimize, core, library);
}

const GeneratedSources = struct {
    native: std.Build.LazyPath,
    dispatch: std.Build.LazyPath,
};

fn createDispatchModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    core: *std.Build.Module,
    library: *std.Build.Module,
) *std.Build.Module {
    const sources = generateDispatch(b, translate, target);

    const dispatch = b.createModule(.{
        .root_source_file = sources.dispatch,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatch.addImport("rt", core);
    dispatch.addImport("library", library);
    // Use the patched translation so nested aliases resolve through dispatch wrappers.
    const native = b.createModule(.{
        .root_source_file = sources.native,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native.addImport("c_routed", dispatch);
    dispatch.addImport("c_native", native);
    dispatch.addCSourceFiles(.{
        .files = &.{"runtime/sync.c"},
        .flags = &.{b.fmt("-DRT_SYNC_PREFIX={s}", .{sync_prefix})},
        .language = .c,
    });
    return dispatch;
}

fn generateDispatch(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
) GeneratedSources {
    const generator = b.addExecutable(.{
        .name = b.fmt("mimalloc-runtime-generate-{s}", .{
            target.result.zigTriple(b.allocator) catch @panic("unspellable target"),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/generate.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });

    const run = b.addRunArtifact(generator);
    run.addArg("--library");
    run.addArg("mimalloc");
    run.addArg("--translate");
    run.addFileArg2(translate.getOutput(), .{});
    if (libc_noise.len != 0) {
        run.addArg("--noise");
        run.addArg(libc_noise);
    }
    if (provider_optional.len != 0) {
        run.addArg("--optional");
        run.addArg(provider_optional);
    }
    if (provider_excluded.len != 0) {
        run.addArg("--exclude");
        run.addArg(provider_excluded);
    }
    run.addArg("--native-output");
    const native_source = run.addOutputFileArg2("native.zig", .{});
    run.addArg("--output");
    const dispatch_source = run.addOutputFileArg2("dispatch.zig", .{});
    return .{ .native = native_source, .dispatch = dispatch_source };
}
