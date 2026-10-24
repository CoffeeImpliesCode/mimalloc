// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Build graph for the mimalloc SDK.
//! Builds upstream's C core and exposes a Zig facade with optional runtime loading.
const std = @import("std");

const graph = @import("runtime/graph.zig");

const manifest = @import("build.zig.zon");

const manifest_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon .version is not a semantic version");

const lib_name = "mimalloc";

const facade_source = "zig/root.zig";

const translate_header = "zig/translate.h";

const test_source = "tests.zig";

const example_source = "smoke.zig";

const source_dir = "src";

const header_dir = "include";

const upstream_version: std.SemanticVersion = .{ .major = 3, .minor = 5, .patch = 3 };

const version_number: u32 =
    upstream_version.major * 10_000 + upstream_version.minor * 100 + upstream_version.patch;

const abi_major: u32 = upstream_version.major;

/// Upstream's compiled core source list.
const core_sources = [_][]const u8{
    "src/alloc.c",
    "src/alloc-aligned.c",
    "src/alloc-posix.c",
    "src/arena.c",
    "src/bitmap.c",
    "src/heap.c",
    "src/init.c",
    "src/libc.c",
    "src/options.c",
    "src/os.c",
    "src/page.c",
    "src/page-map.c",
    "src/prim/prim.c",
    "src/prim/prim-tls.c",
    "src/random.c",
    "src/sample-guarded.c",
    "src/sample-profile.c",
    "src/stats.c",
    "src/subproc.c",
    "src/theap.c",
    "src/threadlocal.c",
};

/// The four headers installed by upstream.
const public_headers = [_][]const u8{
    "include/mimalloc.h",
    "include/mimalloc-override.h",
    "include/mimalloc-new-delete.h",
    "include/mimalloc-stats.h",
};

/// Licence records installed with the artifact.
const licence_records = [_][]const u8{
    "LICENSE",
    "NOTICE.md",
    "FORK-LICENSE.md",
};

/// GNU C11 supports upstream's atomics and GNU extensions (`include/mimalloc/atomic.h:53-55`, `src/prim/prim.c:31-44`).
const c_flags = [_][]const u8{"-std=gnu11"};

/// Source of declarations and library.
const Library = enum {
    /// Compile this repository's sources.
    bundled,
    /// Use an installed library through pkg-config.
    system,
};

/// Baseline targets compiled by `check`.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

/// Targets refused at configure time.
const refused_check_targets = [_]std.Target.Query{};

/// Windows only: disable redirection because this package does not build the redirect DLL.
/// Upstream selects that path with `MI_WIN_NOREDIRECT` (`src/prim/windows/prim.c:1165-1198`, `CMakeLists.txt:1060`).
const Platform = struct {
    os_tag: std.Target.Os.Tag,

    fn forTarget(target: std.Build.ResolvedTarget) Platform {
        return .{ .os_tag = target.result.os.tag };
    }

    fn macros(self: Platform) []const [2][]const u8 {
        return switch (self.os_tag) {
            .windows => &.{.{ "MI_WIN_NOREDIRECT", "1" }},
            // WASI's PAGE_SIZE is a linker expression, not a preprocessor integer.
            .wasi => &.{
                .{ "MI_ARENA_SLICE_SHIFT", "(13 + MI_SIZE_SHIFT)" },
                .{ "_WASI_EMULATED_PROCESS_CLOCKS", "1" },
            },
            else => &.{},
        };
    }

    /// Shared builds enable upstream's shared-library export paths.
    fn sharedMacros(linkage: std.lang.LinkMode) []const [2][]const u8 {
        return switch (linkage) {
            .static => &.{},
            .dynamic => &.{
                .{ "MI_SHARED_LIB", "1" },
                .{ "MI_SHARED_LIB_EXPORT", "1" },
            },
        };
    }

    /// `MI_SHARED_LIB` marks dynamic consumers as DLL imports on Windows.
    fn sharedConsumerMacros(linkage: std.lang.LinkMode) []const [2][]const u8 {
        return switch (linkage) {
            .static => &.{},
            .dynamic => &.{.{ "MI_SHARED_LIB", "1" }},
        };
    }

    fn kind(self: Platform) []const u8 {
        return switch (self.os_tag) {
            .windows => "windows/COFF",
            .macos => "mach-o",
            .wasi => "wasm32-wasi",
            .linux => "elf",
            else => @tagName(self.os_tag),
        };
    }
};

const Graph = struct {
    c_lib: ?*std.Build.Step.Compile,
    module: *std.Build.Module,
    platform: Platform,
};

/// Windows uses PE/COFF loading; other shared targets need a dynamic linker.
fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// Refuse dynamic delivery when the target has no dynamic linker; never substitute static.
fn deliveredLinkage(target: std.Build.ResolvedTarget, requested: std.lang.LinkMode) std.lang.LinkMode {
    if (requested == .dynamic and !targetHasDynamicLinker(target)) {
        std.debug.panic(
            "mimalloc: -Dlinkage=dynamic was asked for on " ++
                "{s}, whose platform has no dynamic linker. This package does not " ++
                "substitute a static archive for a shared object. Build this target " ++
                "with the default static linkage, or choose a target that has a " ++
                "dynamic linker.",
            .{@tagName(target.result.os.tag)},
        );
    }
    return requested;
}

fn artifactName(b: *std.Build, target: std.Build.ResolvedTarget, public: bool) []const u8 {
    if (public) return lib_name;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}", .{ lib_name, triple });
}

/// Configure the artifact, translated header, and facade for one target.
/// Runtime dispatch and artifact linkage are independent choices.
fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    library: Library,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
    public: bool,
) Graph {
    const platform = Platform.forTarget(target);
    const name = artifactName(b, target, public);

    const c_lib: ?*std.Build.Step.Compile = if (library == .bundled)
        add_c_library(b, target, optimize, linkage, platform, name)
    else
        null;

    // Use the same delivery decision for translation and compilation.
    const delivered = deliveredLinkage(target, linkage);

    const no_macros: []const [2][]const u8 = &.{};
    const translate_macros = if (library == .bundled) platform.macros() else no_macros;
    const translate_shared: []const [2][]const u8 = if (library == .bundled)
        Platform.sharedConsumerMacros(delivered)
    else
        no_macros;
    const translate_include: ?std.Build.LazyPath =
        if (library == .bundled) b.path(header_dir) else null;

    const translate = b.addTranslateC(.{
        // Bundled mode selects this package's header; system mode uses the installed header.
        .root_source_file = b.path(translate_header),
        .target = target,
        .optimize = optimize,
        // The translated header requires the target's libc headers.
        .link_libc = true,
    });
    if (translate_include) |dir| translate.addIncludePath(dir);
    for (translate_macros) |macro| translate.defineCMacro(macro[0], macro[1]);
    for (translate_shared) |macro| translate.defineCMacro(macro[0], macro[1]);

    // System mode links the installed library and translates its matching header.
    if (library == .system) {
        translate.linkSystemLibrary(lib_name, .{ .preferred_link_mode = linkage });
    }

    const module = if (public)
        b.addModule(lib_name, .{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        })
    else
        b.createModule(.{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

    if (runtime_loaded) {
        // Runtime dispatch imports the provider table without linking the artifact.
        module.addImport("c", graph.createModule(b, translate, target, optimize));
    } else {
        // Keep the translation as a facade import, not a separately registered module.
        module.addImport("c", translate.createModule());
        module.addImport("rt", graph.createCoreModule(b, target, optimize));
        if (c_lib) |lib| module.linkLibrary(lib);
    }

    // Give the bundled consumer module the same source and header include roots.
    if (library == .bundled) {
        module.addIncludePath(b.path(source_dir));
        module.addIncludePath(b.path(header_dir));
    }

    return .{ .c_lib = c_lib, .module = module, .platform = platform };
}

/// Compile the core for one target; linkage selects its delivery requirements.
fn add_c_library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    requested: std.lang.LinkMode,
    platform: Platform,
    name: []const u8,
) *std.Build.Step.Compile {
    const linkage = deliveredLinkage(target, requested);
    const c_lib = b.addLibrary(.{
        .name = name,
        .linkage = linkage,
        // Shared artifacts use upstream's version and soname; static archives are unversioned.
        .version = if (linkage == .dynamic) upstream_version else null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Shared objects require position-independent code.
            .pic = if (linkage == .dynamic) true else null,
        }),
    });
    const c_mod = c_lib.root_module;

    c_mod.addIncludePath(b.path(source_dir));
    c_mod.addIncludePath(b.path(header_dir));

    // Apply target-specific macros to the compiled core.
    for (platform.macros()) |macro| c_mod.addCMacro(macro[0], macro[1]);

    // Never define MI_MALLOC_OVERRIDE; this artifact exports the mi_* API.
    for (Platform.sharedMacros(linkage)) |macro| c_mod.addCMacro(macro[0], macro[1]);

    c_mod.addCSourceFiles(.{ .files = &core_sources, .flags = &c_flags });

    // ELF uses a version script and COFF a generated export list.
    // Mach-O has no export-list mechanism in this build.
    if (linkage == .dynamic and target.result.ofmt == .elf) {
        c_lib.setVersionScript(b.addWriteFiles().add("mimalloc.map",
            \\MIMALLOC_3 {
            \\  global:
            \\    mi_*;
            \\  local:
            \\    *;
            \\};
            \\
        ));
    } else if (linkage == .dynamic and target.result.ofmt == .coff) {
        const joined = std.mem.join(b.allocator, "\n", &public_entry_points) catch @panic("OOM");
        c_lib.win32_module_definition = b.addWriteFiles().add(
            "mimalloc.def",
            b.fmt("EXPORTS\n{s}\n", .{joined}),
        );
    }

    return c_lib;
}

/// COFF exports public-header functions that have definitions.
const public_entry_points = [_][]const u8{
    "mi__expand",
    "mi_aligned_alloc",
    "mi_aligned_offset_recalloc",
    "mi_aligned_recalloc",
    "mi_any_heap_contains",
    "mi_arena_area",
    "mi_arena_contains",
    "mi_arena_max_object_size",
    "mi_arena_min_alignment",
    "mi_arena_min_size",
    "mi_arenas_print",
    "mi_calloc",
    "mi_calloc_aligned",
    "mi_calloc_aligned_at",
    "mi_check_owned",
    "mi_collect",
    "mi_cfree",
    "mi_debug_show_arenas",
    "mi_dupenv_s",
    "mi_expand",
    "mi_free",
    "mi_free_aligned",
    "mi_free_size",
    "mi_free_size_aligned",
    "mi_free_small",
    "mi_free_small_nonnull",
    "mi_good_size",
    "mi_heap_alloc_new",
    "mi_heap_alloc_new_n",
    "mi_heap_calloc",
    "mi_heap_calloc_aligned",
    "mi_heap_calloc_aligned_at",
    "mi_heap_collect",
    "mi_heap_contains",
    "mi_heap_delete",
    "mi_heap_destroy",
    "mi_heap_main",
    "mi_heap_malloc",
    "mi_heap_malloc_aligned",
    "mi_heap_malloc_aligned_at",
    "mi_heap_malloc_small",
    "mi_heap_mallocn",
    "mi_heap_new",
    "mi_heap_new_in_arena",
    "mi_heap_of",
    "mi_heap_realpath",
    "mi_heap_realloc",
    "mi_heap_realloc_aligned",
    "mi_heap_realloc_aligned_at",
    "mi_heap_reallocf",
    "mi_heap_reallocn",
    "mi_heap_recalloc",
    "mi_heap_recalloc_aligned",
    "mi_heap_recalloc_aligned_at",
    "mi_heap_rezalloc",
    "mi_heap_rezalloc_aligned",
    "mi_heap_rezalloc_aligned_at",
    "mi_heap_set_numa_affinity",
    "mi_heap_stats_get",
    "mi_heap_stats_get_json",
    "mi_heap_stats_merge_to_subproc",
    "mi_heap_stats_print_out",
    "mi_heap_strdup",
    "mi_heap_strndup",
    "mi_heap_theap",
    "mi_heap_visit_abandoned_blocks",
    "mi_heap_visit_blocks",
    "mi_heap_zalloc",
    "mi_heap_zalloc_aligned",
    "mi_heap_zalloc_aligned_at",
    "mi_heap_zalloc_small",
    "mi_is_in_heap_region",
    "mi_is_redirected",
    "mi_manage_memory",
    "mi_manage_os_memory",
    "mi_manage_os_memory_ex",
    "mi_malloc",
    "mi_malloc_aligned",
    "mi_malloc_aligned_at",
    "mi_malloc_good_size",
    "mi_malloc_small",
    "mi_mallocn",
    "mi_mbsdup",
    "mi_memalign",
    "mi_new",
    "mi_new_aligned",
    "mi_new_aligned_nothrow",
    "mi_new_n",
    "mi_new_nothrow",
    "mi_new_realloc",
    "mi_new_reallocn",
    "mi_option_disable",
    "mi_option_enable",
    "mi_option_get",
    "mi_option_get_clamp",
    "mi_option_get_size",
    "mi_option_is_enabled",
    "mi_option_set",
    "mi_option_set_default",
    "mi_option_set_enabled",
    "mi_option_set_enabled_default",
    "mi_options_print",
    "mi_options_print_out",
    "mi_posix_memalign",
    "mi_process_done",
    "mi_process_info",
    "mi_process_info_print",
    "mi_process_info_print_out",
    "mi_process_init",
    "mi_pvalloc",
    "mi_realloc",
    "mi_realloc_aligned",
    "mi_realloc_aligned_at",
    "mi_reallocarr",
    "mi_reallocarray",
    "mi_reallocf",
    "mi_reallocn",
    "mi_realpath",
    "mi_recalloc",
    "mi_recalloc_aligned",
    "mi_recalloc_aligned_at",
    "mi_register_deferred_free",
    "mi_register_error",
    "mi_register_output",
    "mi_reserve_huge_os_pages",
    "mi_reserve_huge_os_pages_at",
    "mi_reserve_huge_os_pages_at_ex",
    "mi_reserve_huge_os_pages_interleave",
    "mi_reserve_os_memory",
    "mi_reserve_os_memory_ex",
    "mi_rezalloc",
    "mi_rezalloc_aligned",
    "mi_rezalloc_aligned_at",
    "mi_stats_get",
    "mi_stats_get_bin_size",
    "mi_stats_get_json",
    "mi_stats_print",
    "mi_stats_print_out",
    "mi_stats_reset",
    "mi_strdup",
    "mi_strndup",
    "mi_subproc_add_current_thread",
    "mi_subproc_current",
    "mi_subproc_destroy",
    "mi_subproc_main",
    "mi_subproc_new",
    "mi_subproc_stats_get",
    "mi_subproc_stats_get_exclusive",
    "mi_subproc_stats_get_json",
    "mi_subproc_stats_print_out",
    "mi_subproc_visit_heaps",
    "mi_theap_alloc_new",
    "mi_theap_alloc_new_n",
    "mi_theap_alloc_new_nothrow",
    "mi_theap_calloc",
    "mi_theap_collect",
    "mi_theap_get_default",
    "mi_theap_guarded_set_sample_rate",
    "mi_theap_guarded_set_size_bound",
    "mi_theap_malloc",
    "mi_theap_malloc_aligned",
    "mi_theap_malloc_small",
    "mi_theap_realloc",
    "mi_theap_rezalloc",
    "mi_theap_set_default",
    "mi_theap_visit_blocks",
    "mi_theap_wmalloc_small",
    "mi_theap_wzalloc_small",
    "mi_theap_zalloc",
    "mi_theap_zalloc_aligned",
    "mi_theap_zalloc_small",
    "mi_thread_done",
    "mi_thread_init",
    "mi_thread_set_in_threadpool",
    "mi_thread_stats_print_out",
    "mi_ucalloc",
    "mi_ufree",
    "mi_umalloc",
    "mi_umalloc_aligned",
    "mi_umalloc_small",
    "mi_unsafe_heap_page_is_under_utilized",
    "mi_urealloc",
    "mi_usable_size",
    "mi_uzalloc_aligned",
    "mi_uzalloc_small",
    "mi_valloc",
    "mi_version",
    "mi_wcsdup",
    "mi_wdupenv_s",
    "mi_wmalloc_small",
    "mi_wzalloc_small",
    "mi_zalloc",
    "mi_zalloc_aligned",
    "mi_zalloc_aligned_at",
    "mi_zalloc_small",
};

/// Compile the facade, tests, example, and C core for one target.
fn add_target_check(
    b: *std.Build,
    step: *std.Build.Step,
    cross_target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    library: Library,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
) void {
    // Include the target triple in cross-build step names.
    const triple = cross_target.result.zigTriple(b.allocator) catch @panic("unspellable target");

    const cross = addGraph(b, cross_target, optimize, library, linkage, runtime_loaded, false);

    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addTest(.{
        .name = b.fmt("{s}-tests-{s}", .{ lib_name, triple }),
        .root_module = test_mod,
    }).step);

    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addExecutable(.{
        .name = b.fmt("{s}-smoke-{s}", .{ lib_name, triple }),
        .root_module = example_mod,
    }).step);

    // Include the bundled artifact in the target check.
    if (cross.c_lib) |c_lib| step.dependOn(&c_lib.step);
}

/// Build the separate consumer with this graph's resolved options.
/// Build and run the consumer only when its target is host-native.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    library: Library,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
) *std.Build.Step.Run {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    // Preserve the selected target CPU in the nested build.
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // Use the Zig executable that invoked this build.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // Preserve linkage in the nested build.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    // Preserve the runtime-loading mode.
    run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));
    // Preserve the system-library choice resolved by the parent graph.
    run.addArg(if (library == .system) b.fmt("-fsys={s}", .{lib_name}) else b.fmt("-fno-sys={s}", .{lib_name}));
    // Keep job count and summary explicit in the nested build.
    run.addArg("-j8");
    run.addArg("--summary");
    run.addArg("all");
    run.addArg("--cache-dir");
    run.addDirectoryArg2(
        std.Build.LazyPath.cache_root.path(b, "consumer"),
        .{ .make_absolute = true },
    );
    // Zig 0.17 accepts these locations through the environment, not build flags.
    for ([_][]const u8{ "ZIG_GLOBAL_CACHE_DIR", "ZIG_LIB_DIR" }) |key| {
        if (b.graph.environ_map.get(key)) |value| run.setEnvironmentVariable(key, value);
    }
    // Forward the parent's install prefix.
    run.addArg("--prefix");
    run.addDirectoryArg2(
        .{ .relative = .{ .base = .install_prefix } },
        .{ .make_absolute = true },
    );
    // Pass caller arguments after the build options and separator.
    run.addArg("--");
    run.addPassthruArgs();
    run.has_side_effects = true;
    return run;
}

/// Run the nested consumer only when it targets the host natively.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .host_cpu_arch = host.cpu.arch,
        .host_os_tag = host.os.tag,
        .link_mode = .dynamic,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, &target.result, options)) {
        .native => true,
        else => false,
    };
}

/// Generate relocatable pkg-config metadata for the installed artifact.
/// Windows shared consumers need `MI_SHARED_LIB` for DLL imports.
fn add_pkg_config(b: *std.Build, platform: Platform, linkage: std.lang.LinkMode) void {
    const files = b.addWriteFiles();
    // Attach the generated file to the install step.
    const install_pc = b.addInstallFileWithDir(
        files.add("mimalloc.pc", b.fmt(
            \\# mimalloc.pc for the mimalloc {d}.{d}.{d} SDK.
            \\#
            \\# Upstream's own mimalloc.pc.in is generated by CMake from these same
            \\# five fields; every value substituted here is this build's, and
            \\# build.zig's add_pkg_config says where each one comes from. `prefix`
            \\# is pcfiledir-relative so the installed file is correct wherever
            \\# --prefix put it.
            \\prefix=${{pcfiledir}}/../..
            \\exec_prefix=${{prefix}}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: mimalloc
            \\Description: A compact general purpose allocator with excellent performance
            \\Version: {d}.{d}.{d}
            \\URL: https://github.com/microsoft/mimalloc/
            \\Libs: -L"${{libdir}}" -lmimalloc
            \\Libs.private: -lpthread
            \\Cflags: -I"${{includedir}}"{s}
            \\
        , .{
            upstream_version.major,
            upstream_version.minor,
            upstream_version.patch,
            upstream_version.major,
            upstream_version.minor,
            upstream_version.patch,
            // Windows DLL consumers need the import declaration macro.
            if (linkage == .dynamic and platform.os_tag == .windows) " -DMI_SHARED_LIB=1" else "",
        })),
        .prefix,
        "lib/pkgconfig/mimalloc.pc",
    );
    b.getInstallStep().dependOn(&install_pc.step);
}

/// Install upstream and fork licence records with the artifact.
fn install_licence_records(b: *std.Build) void {
    for (licence_records) |record| {
        const install_record = b.addInstallFileWithDir(
            b.path(record),
            .prefix,
            b.fmt("share/licenses/{s}/{s}", .{ lib_name, std.Io.Dir.path.basename(record) }),
        );
        b.getInstallStep().dependOn(&install_record.step);
    }
}

/// Install the four headers installed by upstream.
fn install_public_headers(b: *std.Build) void {
    for (public_headers) |header| {
        const install_header = b.addInstallFileWithDir(
            b.path(header),
            .prefix,
            b.fmt("include/{s}", .{std.Io.Dir.path.basename(header)}),
        );
        b.getInstallStep().dependOn(&install_header.step);
    }
}

fn refusalFor(os_tag: std.Target.Os.Tag) ?[]const u8 {
    _ = os_tag;
    return null;
}

/// Check that target and refusal lists agree with `refusalFor`.
fn checkMatrixPartition(_: *std.Build) void {
    for (check_targets) |query| {
        const os_tag = query.os_tag orelse .linux;
        if (refusalFor(os_tag) != null) {
            std.debug.panic(
                "build.zig: {s} is in check_targets but this build refuses its operating system",
                .{@tagName(os_tag)},
            );
        }
    }
    for (refused_check_targets) |query| {
        const os_tag = query.os_tag orelse .linux;
        if (refusalFor(os_tag) == null) {
            std.debug.panic(
                "build.zig: {s} is in refused_check_targets but refusalFor no longer refuses it; " ++
                    "move it to check_targets and prove it builds",
                .{@tagName(os_tag)},
            );
        }
    }
}

/// Configure the build for the selected target and delivery mode.
/// `-Dsystem` supplies a default; `-fsys=mimalloc` can override it.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const system_default = b.option(
        bool,
        "system",
        "Link an installed libmimalloc instead of compiling src/, and translate the " ++
            "installed headers instead of the bundled ones. This supplies the " ++
            "default of systemIntegrationOption(\"mimalloc\"); a build runner that " ++
            "decides the mode itself (-fsys=mimalloc) overrides it.",
    ) orelse false;

    const use_system = b.systemIntegrationOption(lib_name, .{ .default = system_default });
    const library: Library = if (use_system) .system else .bundled;

    const linkage_option = b.option(
        std.lang.LinkMode,
        "linkage",
        "Deliver the native library as a static archive (the default) or as a real " ++
            "shared object with upstream's soname scheme: libmimalloc.so.3.5.3 with " ++
            "soname libmimalloc.so.3. This selects the delivery and never the " ++
            "dispatch: the same 21 C units are compiled either way. In system mode " ++
            "this graph builds no artifact at all, so there the option names the " ++
            "kind of installed library to bind to instead, and it defaults to " ++
            "dynamic.",
    );

    // Preserve static bundled and dynamic system-linkage defaults.
    const linkage: std.lang.LinkMode = linkage_option orelse
        (if (library == .system) .dynamic else .static);

    // Runtime dispatch is independent of artifact linkage.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. " ++
            "The facade keeps the same translated header and the same public " ++
            "types; each selected native function becomes a dispatch through " ++
            "one process-lifetime table that an explicit load(source) fills, " ++
            "and the module links no archive. Independent of -Dlinkage, which " ++
            "still decides which artifact this build delivers and installs. " ++
            "Default off, and a linked build is unchanged in every respect.",
    ) orelse false;

    // Reject a manifest version that differs from the upstream source version.
    if (manifest_version.order(upstream_version) != .eq) {
        @panic("build.zig.zon .version no longer matches the version this build " ++
            "compiles from src/ and include/; see UPSTREAM.md");
    }

    // Check the target partition before configuring the graph.
    checkMatrixPartition(b);

    const published = addGraph(b, target, optimize, library, linkage, runtime_loaded, true);

    if (published.c_lib) |c_lib| {
        b.installArtifact(c_lib);
        add_pkg_config(b, published.platform, deliveredLinkage(target, linkage));
        install_licence_records(b);
        install_public_headers(b);
    }

    // Compile the smoke example during install; do not install it.
    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, published.module);
    const example = b.addExecutable(.{
        .name = b.fmt("{s}-smoke", .{lib_name}),
        .root_module = example_mod,
    });
    b.getInstallStep().dependOn(&example.step);

    // The smoke step runs the example without installing.
    const run_example = b.addRunArtifact(example);
    run_example.has_side_effects = true;
    run_example.addPassthruArgs();
    b.step("smoke", "Run the deterministic example program").dependOn(&run_example.step);

    // Use a run artifact so the test step can execute for the selected target.
    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, published.module);
    const unit_tests = b.addTest(.{
        .name = b.fmt("{s}-tests", .{lib_name}),
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    b.step("test", "Run the behavioural tests").dependOn(&run_tests.step);

    // Build or run the separate consumer with this graph's resolved configuration.
    b.step("consumer", "Build or run the consumer/ package for the selected target")
        .dependOn(&runConsumer(b, target, optimize, library, deliveredLinkage(target, linkage), runtime_loaded).step);

    // Compile the core, facade, tests, and example for each check target.
    const check_step = b.step(
        "check",
        "Compile the native library, the facade, the tests and the example for " ++
            "each baseline target compatible with the selected linkage and runtime mode",
    );
    if (!target.query.isNative()) {
        add_target_check(b, check_step, target, optimize, library, linkage, runtime_loaded);
    } else {
        for (check_targets) |query| {
            const cross_target = b.resolveTargetQuery(query);
            // Static-only targets cannot check shared delivery or runtime loading.
            if ((linkage == .dynamic or runtime_loaded) and !targetHasDynamicLinker(cross_target)) continue;
            add_target_check(b, check_step, cross_target, optimize, library, linkage, runtime_loaded);
        }
    }

    if (published.c_lib != null) {
        std.debug.print(
            "mimalloc: {d} core units, C11 (gnu11), {s}, MI_MALLOC_VERSION {d}\n",
            .{ core_sources.len, published.platform.kind(), version_number },
        );
        std.debug.print(
            "mimalloc: MI_MALLOC_OVERRIDE is not defined, so this artifact exports " ++
                "mi_* and not malloc, free or operator new; nothing in this workspace " ++
                "is routed through it\n",
            .{},
        );
        std.debug.print("mimalloc: {s}\n", .{switch (deliveredLinkage(target, linkage)) {
            .static => "static archive libmimalloc.a",
            .dynamic => b.fmt(
                "shared object libmimalloc.so.{d}.{d}.{d}, soname libmimalloc.so.{d}",
                .{
                    upstream_version.major,
                    upstream_version.minor,
                    upstream_version.patch,
                    abi_major,
                },
            ),
        }});
        if (runtime_loaded) {
            std.debug.print(
                "mimalloc: runtime-loaded dispatch (-Druntime=true); the facade module " ++
                    "links no archive and a provider is named by an explicit " ++
                    "load(source)\n",
                .{},
            );
        }
        // Mach-O has no export list; COFF uses the generated `.def` above.
        if (deliveredLinkage(target, linkage) == .dynamic and
            target.result.ofmt != .elf)
        {
            std.debug.print(
                "mimalloc: a {s} shared object gets no version script here, so it " ++
                    "exports mimalloc's _mi_ internals as well as its mi_ API\n",
                .{@tagName(target.result.ofmt)},
            );
        }
    } else {
        std.debug.print(
            "mimalloc: system libmimalloc (-lmimalloc) and the installed headers; " ++
                "this package installs no artifact and no header\n",
            .{},
        );
        if (runtime_loaded) {
            std.debug.print(
                "mimalloc: runtime-loaded dispatch (-Druntime=true) over the installed " ++
                    "provider named by an explicit load(source)\n",
                .{},
            );
        }
    }
}
