// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Build graph for the mimalloc SDK.
//!
//! ## What is built, and from what
//!
//! The complete v3 core, compiled from this repository's own `src/` and
//! `include/`. There is no CMake, no autotools, no `Makefile`, no build-time
//! download and no system-installed default: the source list below is the same
//! `mi_sources` list upstream's `CMakeLists.txt:107-126` names, read out of that
//! file rather than guessed, and it is the whole closure.
//!
//! Two of upstream's source files are deliberately **not** in that list, and
//! both absences are upstream's own:
//!
//!   * `src/free.c` is textually included by `src/alloc.c` at
//!     `src/alloc.c:19-22`, which is why upstream's list has no entry for it.
//!     Compiling it separately would define `mi_free` twice.
//!   * `src/alloc-override.c` is included by the same three lines and is empty
//!     unless `MI_MALLOC_OVERRIDE` is defined (`src/alloc-override.c:13`). This
//!     graph never defines it. See "This build is not an override" below.
//!
//! `src/static.c` is retained but not compiled either: it is the whole-amalgamation
//! translation unit (`src/static.c:23` includes `alloc.c`, which includes
//! `alloc-override.c` and `free.c`) for a C++-compiled single-object build, and
//! upstream compiles it only as its own `mimalloc-obj` target
//! (`CMakeLists.txt:1092`). Compiling it here as well would define every symbol
//! twice.
//!
//! ## This build is not an override
//!
//! `MI_MALLOC_OVERRIDE` is never defined, anywhere, on any configuration. That
//! is the one macro that decides whether this library defines the standard
//! allocator: with it, `src/alloc-override.c` aliases `malloc`, `calloc`,
//! `realloc`, `free`, `posix_memalign` and the C++ `operator new` family onto
//! their `mi_` counterparts (`src/alloc-override.c:23-120`, `:240-300`), and
//! upstream's own CMake builds a separate `mimalloc-obj` object file precisely
//! so that an overriding build can opt in (`CMakeLists.txt:1092-1096`,
//! `:1172-1182`).
//!
//! So the artifact this graph delivers exports `mi_malloc`, `mi_free` and their
//! kin and does **not** export `malloc`, `free` or the C++ operators. Nothing in
//! this workspace is routed through it; `zig/root.zig` says so from the caller's
//! side and `isRedirected` is what a provider reports about itself.
//!
//! ## Two deliveries, one source list
//!
//! `-Dlinkage` selects the artifact and nothing about the compilation. Static is
//! the default; dynamic produces a real shared object with upstream's own soname
//! scheme (`CMakeLists.txt:997`: `VERSION ${mi_version}` and
//! `SOVERSION ${mi_version_major}`), so `libmimalloc.so.3.5.3` with soname
//! `libmimalloc.so.3`.
//!
//! ## Generated inputs are per target
//!
//! Nothing is generated for the host and shipped to a target. There is exactly
//! one generated file in this package, `zig/translate.h` -> the translation, and
//! it is produced by `b.addTranslateC` for the target being built, with that
//! target's platform macros and that target's include path. The runtime route
//! adds a second generated file, the dispatch, and `runtime/graph.zig` runs its
//! generator on the build machine *reading that same per-target translation*, so
//! the dispatch describes the headers this build selected.
//!
//! ## The six-target check matrix
//!
//! `check` compiles the whole closure, the translation, the facade, the tests
//! and the example for each of the six baseline targets and runs nothing.
//! `wasm32-wasi` is in the matrix, not out of it: `src/prim/prim.c:17-19`
//! selects `src/prim/wasi/prim.c` under `__wasi__`, so upstream ships the
//! primitives for it. Whether a cell links and runs is for the driver's gate to
//! observe, and this file claims nothing either way; `refused_check_targets` is
//! empty and `checkMatrixPartition` enforces that, so a target can only be added
//! to one list by an edit that says which.
//!
//! What *is* refused, and where, is `deliveredLinkage`: `-Dlinkage=dynamic`
//! needs a platform with a dynamic linker, and wasm32-wasi has none. That is a
//! property of the delivery, not of the source, so the default static build of
//! that row is not refused and only the shared one is.
//!
//! ## Runtime loading
//!
//! `-Druntime` swaps `translate.createModule()` for `runtime/graph.zig`'s
//! `createModule`, which generates a dispatch from the same translation step's
//! output and links no archive at all. It is orthogonal to `-Dlinkage`: the
//! artifact is still built and installed, because a caller may name a provider
//! this tree did not build. One process-lifetime table, explicit provider
//! selection, no fallback, atomic publication, explicit retry, and an ordinary
//! pre-initialization panic in every optimization mode. Linked calls stay
//! direct.
const std = @import("std");

const graph = @import("runtime/graph.zig");

const manifest = @import("build.zig.zon");

/// `build.zig.zon .version`, parsed rather than compared as text, so a manifest
/// edited into something that is not a version fails here instead of wrapping.
const manifest_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon .version is not a semantic version");

/// The module and artifact name. `dep.module("mimalloc")` in a dependent's
/// `build.zig` and `dep.artifact("mimalloc")` both name this.
const lib_name = "mimalloc";

/// The Zig facade, and the only thing published as a module.
const facade_source = "zig/root.zig";

/// The one header the translation step is handed.
const translate_header = "zig/translate.h";

/// The test root. It names the test blocks; a root that only re-exported them
/// would discover no tests and still exit zero.
const test_source = "tests.zig";

/// The example program.
const example_source = "smoke.zig";

/// The vendored upstream source root, where every `src/` unit includes its
/// neighbours by bare name (`src/alloc.c:20-21`).
const source_dir = "src";

/// The vendored upstream public header root. `zig/translate.h` includes
/// `<mimalloc.h>`, which is here and nowhere else.
const header_dir = "include";

/// The upstream release this package is built from, and the number
/// `include/mimalloc.h:11` spells as `MI_MALLOC_VERSION`.
///
/// Checked against the manifest on every configure, so a manifest edit without
/// the source it describes is a stop rather than a silent mismatch.
const upstream_version: std.SemanticVersion = .{ .major = 3, .minor = 5, .patch = 3 };

/// `MI_MALLOC_VERSION` for that release: major times ten thousand, plus two
/// digits of minor, plus two of patch (`include/mimalloc.h:11`).
const version_number: u32 =
    upstream_version.major * 10_000 + upstream_version.minor * 100 + upstream_version.patch;

/// The shared object's soname major, upstream's `SOVERSION`
/// (`CMakeLists.txt:997`): 3 for the v3 line. A provider from the v2 or v1
/// line has soname `libmimalloc.so.2` or `.1`, which is why the soname and
/// `mi_version` are two answers to the same question.
const abi_major: u32 = upstream_version.major;

/// The complete core closure: upstream's `mi_sources`
/// (`CMakeLists.txt:107-126`), in the order upstream lists it.
///
/// `src/prim/prim.c` and `src/prim/prim-tls.c` are the two primitive units
/// because `src/prim/prim.c:11-25` `#include`s the platform implementation as
/// text. Only the one for the target being built is compiled, and the `#if`
/// chain decides which; nothing here lists a platform directory.
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

/// The headers upstream installs, and this graph installs unchanged.
///
/// Exactly upstream's four, from `CMakeLists.txt:1082-1085`. Upstream does not
/// install `include/mimalloc/*.h` or `include/mimalloc-profile.h`, because the
/// four installed headers do not include them: `mimalloc.h` reaches only
/// `<stddef.h>`, `<stdbool.h>` and `<assert.h>` (`include/mimalloc.h:98-100`).
/// The internal headers are still in this repository, because the build needs
/// them; they are simply not part of the installed surface, which is upstream's
/// decision rather than this graph's.
const public_headers = [_][]const u8{
    "include/mimalloc.h",
    "include/mimalloc-override.h",
    "include/mimalloc-new-delete.h",
    "include/mimalloc-stats.h",
};

/// The licence and provenance records installed beside the artifact, so that an
/// installed tree carries upstream's grant and this fork's own.
const licence_records = [_][]const u8{
    "LICENSE",
    "NOTICE.md",
    "FORK-LICENSE.md",
};

/// The C dialect the core is compiled with.
///
/// `-std=gnu11` is named rather than inherited, because mimalloc's core needs
/// C11 `<stdatomic.h>`: `include/mimalloc/atomic.h:53-55` includes it on every
/// non-C++, non-MSVC target, and there is no lower dialect that has it. `gnu11`
/// rather than `c11` because upstream's own sources use GNU extensions in
/// `#if defined(__GNUC__)` paths - `src/prim/prim.c:31-44` keys the
/// constructor attribute off `__GNUC__` - and a strict `-std=c11` would hide
/// those extensions from those guards.
///
/// Nothing else is needed: `src/alloc.c:7-8` and `src/prim/unix/prim.c:10-11`
/// each define `_DEFAULT_SOURCE` themselves, before including anything that
/// needs it, so no feature-test macro belongs on this line.
const c_flags = [_][]const u8{"-std=gnu11"};

/// Which library this build takes its declarations and its library from.
const Library = enum {
    /// Compile this repository's `src/`. The only mode with a real artifact.
    bundled,
    /// Bind to an installed `libmimalloc` through `systemIntegrationOption`.
    system,
};

/// The six baseline cross targets `check` compiles, without running any of them.
///
/// All six are here and none is refused. `wasm32-wasi` is included because
/// `src/prim/prim.c:17-19` selects `src/prim/wasi/prim.c` for it; see the
/// module comment. A row is never dropped: a target that turns out not to work
/// belongs in `refused_check_targets` with the reason, and `checkMatrixPartition`
/// stops a list that disagrees with `refusalFor`.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

/// Targets `check` refuses outright.
///
/// Empty, and `checkMatrixPartition` enforces that it stays a partition of
/// `check_targets`: a target cannot be in both lists, and a target in this list
/// whose operating system `refusalFor` no longer refuses is a configure-time
/// stop rather than a row that quietly stopped being checked.
const refused_check_targets = [_]std.Target.Query{};

/// The platform-dependent compile macros, resolved for the target being built.
///
/// There is exactly one platform macro, and it is Windows-only:
///
///   `MI_WIN_NOREDIRECT=1` - upstream's own "do not use the CRT redirection
///   module" switch. `CMakeLists.txt:323-327` defines it exactly this way when
///   `MI_WIN_REDIRECT` is off, and it is off by default
///   (`CMakeLists.txt:54`). It matters here because
///   `src/prim/windows/prim.c:1165-1198` compiles, under
///   `MI_SHARED_LIB && !MI_WIN_NOREDIRECT`, a block that declares
///   `__declspec(dllimport) mi_allocator_init` - a symbol exported by upstream's
///   separate `mimalloc-redirect` DLL, which this package does not build
///   (`CMakeLists.txt:1060`). Naming the switch selects upstream's supported
///   non-redirect path and leaves `src/prim/prim.c:64-74` to supply the generic
///   `_mi_is_redirected`, which answers `false`. This is a choice among two
///   configurations upstream itself supports, not a patch to upstream's source;
///   `FORK-NOTES.md` records it.
///
/// Nothing else is platform-conditional. `MI_SECURE`, `MI_DEBUG`, `MI_STATS`,
/// `MI_PADDING`, `MI_TRACK` and `MI_GUARDED` all default themselves in
/// `include/mimalloc/types.h:68-88` and `include/mimalloc/track.h`, and
/// `MI_DEBUG` additionally keys off `NDEBUG` there, which the optimize mode
/// already sets. Defining any of them would be this graph choosing a policy
/// upstream did not ask for.
const Platform = struct {
    os_tag: std.Target.Os.Tag,

    fn forTarget(target: std.Build.ResolvedTarget) Platform {
        return .{ .os_tag = target.result.os.tag };
    }

    /// The platform macros for this platform, as name/value pairs.
    fn macros(self: Platform) []const [2][]const u8 {
        _ = self;
        return &.{};
    }

    /// Whether a shared build needs `MI_SHARED_LIB` and `MI_SHARED_LIB_EXPORT`.
    ///
    /// Both, on every platform, which is what upstream's shared target gets
    /// (`CMakeLists.txt:998`). They change what they change:
    /// `include/mimalloc.h:39-67` turns `mi_decl_export` into `__declspec`
    /// decoration on Windows and into `visibility("default")` elsewhere,
    /// `src/prim/windows/prim.c:1013` selects the DLL `DllMain` path for a
    /// legacy TLS configuration, `src/theap.c:242` skips the weak random
    /// initialiser, and `src/init.c:616` skips the forced collection at exit
    /// because a stand-alone process reclaims itself anyway.
    fn sharedMacros(linkage: std.builtin.LinkMode) []const [2][]const u8 {
        return switch (linkage) {
            .static => &.{},
            .dynamic => &.{
                .{ "MI_SHARED_LIB", "1" },
                .{ "MI_SHARED_LIB_EXPORT", "1" },
            },
        };
    }

    /// Whether a shared build needs the declaration half of that split on the
    /// *consuming* side.
    ///
    /// `MI_SHARED_LIB` alone, never `MI_SHARED_LIB_EXPORT`: without either,
    /// `include/mimalloc.h:40-42` makes `mi_decl_export` empty on Windows;
    /// with `MI_SHARED_LIB` alone it becomes `__declspec(dllimport)`
    /// (`include/mimalloc.h:43`), which is what a consumer of the DLL needs. On
    /// every other target both macros are no-ops (`include/mimalloc.h:63-67`).
    fn sharedConsumerMacros(linkage: std.builtin.LinkMode) []const [2][]const u8 {
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

/// What one configured graph produced.
const Graph = struct {
    c_lib: ?*std.Build.Step.Compile,
    module: *std.Build.Module,
    platform: Platform,
};

/// Whether this target's OS has a dynamic linker at all, and therefore whether
/// it can carry a shared object.
///
/// Windows uses its PE/COFF loader without an interpreter path. Other shared
/// targets need a dynamic linker. WASI has neither.
fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// The linkage this build delivers, or a refusal when the target cannot carry
/// what was asked for.
///
/// There is no substitution here. "Deliver a shared object" is a real request
/// and a target whose platform has no dynamic linker cannot honour it; handing
/// back an archive under that name would be a result the caller did not ask for
/// and cannot tell from support.
fn deliveredLinkage(target: std.Build.ResolvedTarget, requested: std.builtin.LinkMode) std.builtin.LinkMode {
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

/// The artifact name this graph installs or reports, with the target's triple
/// when the build is not the published one.
fn artifactName(b: *std.Build, target: std.Build.ResolvedTarget, public: bool) []const u8 {
    if (public) return lib_name;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}", .{ lib_name, triple });
}

/// Builds one configuration: the artifact, the translation and the facade
/// module that a dependent imports.
///
/// The runtime-loading seam is `runtime/graph.zig`, which the API role owns. It
/// exposes `createModule` and `createCoreModule`, and `-Druntime` substitutes
/// the first for `translate.createModule()`. It takes the `TranslateC` step this
/// function has already built, so the generated dispatch keeps the exact
/// translated type and constant namespace rather than compiling a second copy of
/// the native extern declarations: the `mi_heap_t` a facade names and the
/// declaration behind the table are one type.
///
/// `-Dlinkage` is orthogonal and keeps meaning what it means: it selects which
/// artifact this build *delivers* and installs, never which one the module
/// dispatches through.
///
/// The `rt` import is for the linked branch only, and the reason is the nominal
/// type rather than the code: `graph.createModule` creates the one core-module
/// instance the generated dispatch uses and re-exports `LoadSource`/`LoadError`
/// from it; a second instance created here for the facade would be a *different*
/// `LoadSource`, and `mimalloc.load(source)` would be handing the facade's type
/// to a function expecting the dispatch's. One instance per build, no more.
/// `zig/root.zig` picks between the two with a comptime branch on
/// `runtime_loaded`, so the module a configuration does not need is never
/// resolved and never compiled.
fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    public: bool,
) Graph {
    const platform = Platform.forTarget(target);
    const name = artifactName(b, target, public);

    const c_lib: ?*std.Build.Step.Compile = if (library == .bundled)
        add_c_library(b, target, optimize, linkage, platform, name)
    else
        null;

    // Resolved here as well as in `add_c_library`, and for the same reason: the
    // translation and the library must not be able to disagree about whether
    // this delivery is shared.
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
        // `zig/translate.h` includes `<mimalloc.h>` and defines no macro of its
        // own; the header search path below is the only one it has, so the
        // translation cannot bind to whatever mimalloc happens to be installed
        // on the build machine (`WISDOM.md` W14). System mode deliberately does
        // not add it: there the installed headers are the ones this describes.
        .root_source_file = b.path(translate_header),
        .target = target,
        .optimize = optimize,
        // `mimalloc.h` reaches `<stddef.h>`, `<stdbool.h>` and `<assert.h>`
        // (`include/mimalloc.h:98-100`), so the translation needs the target's
        // libc the same way the compiled core does.
        .link_libc = true,
    });
    if (translate_include) |dir| translate.addIncludePath(dir);
    for (translate_macros) |macro| translate.defineCMacro(macro[0], macro[1]);
    for (translate_shared) |macro| translate.defineCMacro(macro[0], macro[1]);

    // No C dialect on the translation, and that is a fact rather than an
    // omission. `std.Build.Step.TranslateC` has no flag-adding entry point at
    // all in Zig 0.16 - its whole surface is `addIncludePath`,
    // `addSystemIncludePath`, `addAfterIncludePath`, `addConfigHeader`,
    // `addFrameworkPath`, `addSystemFrameworkPath`, `defineCMacro`,
    // `defineCMacroRaw`, `addCheckFile` and `linkSystemLibrary` - so nothing
    // could be passed even if it were needed. It is not needed: the header's
    // whole include closure is `<stddef.h>`, `<stdbool.h>` and `<assert.h>`, none
    // of which declares anything whose spelling is dialect-dependent, and the
    // only macros this header defines itself - `mi_decl_*`, `MI_MALLOC_VERSION`,
    // `MI_SMALL_*` - are dialect independent. The C11 requirement is the
    // *core's* (`include/mimalloc/atomic.h:53-55`), compiled by
    // `add_c_library` and never by the translator.
    //
    // `NDEBUG` is the one macro that does change this header's closure, and it
    // changes it the same way for both routes: it is set by the optimize mode.
    // Under it, glibc's `assert.h` declares nothing at all - its declarations
    // are in the `#else /* Not NDEBUG. */` branch of `generic-glibc/assert.h:91`
    // to `:118` - so a release translation has no assertion entry point to
    // classify at all and a Debug one has the four `libc_noise` names for it.
    // `runtime/graph.zig` lists all of them, which is what makes the list
    // correct in both modes.

    // System mode: the installed `mimalloc.pc` names the include directory this
    // translation needs and the library the module binds, and this one call
    // gives both to both. `createModule` carries the entry onto the `c` module
    // below, so a dependent compiles and links against the same prefix the
    // declarations were read from.
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
        // A loaded provider must arrive through the platform loader, so the link
        // line names nothing. Linking the archive as well would make the linker
        // resolve the same symbols statically and the runtime route would
        // quietly be a linked one. The artifact itself is still built and
        // installed, because delivery and dispatch are separate questions: the
        // whole point of the mode is that a caller may name a provider this tree
        // did not build.
        module.addImport("c", graph.createModule(b, translate, target, optimize));
    } else {
        // The translated header is imported, never registered.
        // `addModule("c")` would make `dep.module("c")` resolve and hand a
        // dependent the same declarations without the library that satisfies
        // them; `mimalloc.c` on the facade is the supported way in and carries
        // the facade's own linkage.
        module.addImport("c", translate.createModule());
        module.addImport("rt", graph.createCoreModule(b, target, optimize));
        // System mode names the installed library through the translation above,
        // so this module already carries it.
        if (c_lib) |lib| module.linkLibrary(lib);
    }

    // The same include paths as the archive's own module, on the module a
    // dependent actually imports, so a dependent that compiles its own C against
    // this package finds the same headers the core was compiled with. System
    // mode does not add them: the installed include directory reaches the
    // dependent through the same `mimalloc.pc` entry.
    if (library == .bundled) {
        module.addIncludePath(b.path(source_dir));
        module.addIncludePath(b.path(header_dir));
    }

    return .{ .c_lib = c_lib, .module = module, .platform = platform };
}

/// Compiles the core for one target: `core_sources` and nothing else.
///
/// `requested` is the linkage the caller asked for. What it selects is the
/// artifact and nothing else about the compilation. What a shared artifact adds
/// is its own requirements - the soname, PIC, the export surface and the
/// `MI_SHARED_LIB` macro split - and `delivered` is what this target can
/// actually carry.
fn add_c_library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    requested: std.builtin.LinkMode,
    platform: Platform,
    name: []const u8,
) *std.Build.Step.Compile {
    const linkage = deliveredLinkage(target, requested);
    const c_lib = b.addLibrary(.{
        .name = name,
        .linkage = linkage,
        // Upstream's `VERSION ${mi_version}` (`CMakeLists.txt:997`), which Zig
        // turns into `libmimalloc.so.3.5.3` plus the soname it derives. `version`
        // is null for a static archive, which has no soname and no versioned
        // file name.
        .version = if (linkage == .dynamic) upstream_version else null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            // libc, because every translation unit reaches the C library for its
            // own vocabulary: `<string.h>` for memcpy/memset/strlen across
            // `src/alloc.c:15`, `src/alloc-posix.c:17-18` and `src/free.c`;
            // `<stdio.h>` for the verbose and error output in `src/options.c`;
            // `<unistd.h>` and `<sys/mman.h>` for `src/prim/unix/prim.c`;
            // `<windows.h>` for `src/prim/windows/prim.c`; and `<pthread.h>` for
            // `include/mimalloc/atomic.h:22`.
            .link_libc = true,
            // A shared library is position-independent whether or not this says
            // so; naming it makes the requirement explicit.
            .pic = if (linkage == .dynamic) true else null,
        }),
    });
    const c_mod = c_lib.root_module;

    // For the sources' own quoted includes: `src/alloc.c:20-21` includes
    // `alloc-override.c` and `free.c` by bare name, and `src/arena.c:25`
    // includes `bitmap.h`.
    c_mod.addIncludePath(b.path(source_dir));
    // For `<mimalloc.h>` and `<mimalloc/internal.h>`, which the sources reach
    // with angle brackets (`src/alloc.c:11-13`).
    c_mod.addIncludePath(b.path(header_dir));

    // Zig 0.16 takes C flags per source file rather than on the module.
    _ = c_flags;

    // The platform configuration for the target being built, not for the host.
    // `addGraph` gives the translation the same list.
    for (platform.macros()) |macro| c_mod.addCMacro(macro[0], macro[1]);

    // `MI_MALLOC_OVERRIDE` is deliberately absent, on the line that compiles the
    // definitions as well as on the header. See the module comment: defining it
    // would make this archive export `malloc`, `free` and `operator new`.
    for (Platform.sharedMacros(linkage)) |macro| c_mod.addCMacro(macro[0], macro[1]);

    c_mod.addCSourceFiles(.{ .files = &core_sources, .flags = &.{} });

    // The export surface, per object format.
    //
    // ELF gets a version script, which is the only one of the three formats where
    // Zig can name an export set: `mi_*` is the whole public header - every
    // declaration in `include/mimalloc.h` is `mi_`-prefixed - and everything
    // else, the `_mi_` internals, stays local. Without it a GCC or Clang shared
    // object exports every non-static symbol, which is how a `_mi_` internal ends
    // up visible.
    //
    // COFF gets a module definition file, for the same reason in the only
    // mechanism Windows has. It is generated rather than vendored because it is
    // this build's export list, not upstream's: upstream has no `.def` for the
    // shared target (`CMakeLists.txt:995-1005` does not mention one) and relies
    // on `__declspec` from `mi_decl_export`.
    //
    // Mach-O gets neither, because Zig 0.16 has no exported-symbols option for
    // it. Said out loud in `build` rather than left to be discovered with `nm`.
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

/// The public entry points, for the COFF export list.
///
/// Read out of `include/mimalloc.h`: every function declaration in it, which is
/// every line numbered 110 through 441 that declares one. Both
/// `mi_collect_reduce` (`include/mimalloc.h:435`) and `mi_stats_merge`
/// (`include/mimalloc.h:438`) are **absent on purpose** - they are declared in
/// the header and defined nowhere in the source, so a `.def` listing either one
/// would be a link error. See `runtime/library.zig` and `FORK-NOTES.md`.
///
/// The `_mi_` internals are absent because they are not in the public header at
/// all.
const public_entry_points = [_][]const u8{
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
    "mi_options_print",
    "mi_options_print_out",
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

/// Compile the whole package for one matrix cell, without running anything.
///
/// The tests, the example and the whole C closure for the target are what makes
/// this a check of the facade rather than of an unreferenced archive: an archive
/// nothing references is not a check, and neither is `refAllDeclsRecursive`.
fn add_target_check(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) void {
    const cross_target = b.resolveTargetQuery(query);
    // The triple names the cross artifacts. Six targets in one build graph
    // otherwise produce six steps called "mimalloc", which makes `--summary all`
    // useless for telling them apart.
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

    // The artifact itself is part of what this package delivers, so a target
    // where the core does not compile is a target this SDK does not support and
    // the matrix says so at build time rather than at install. System mode
    // builds none: there is no local library to deliver.
    if (cross.c_lib) |c_lib| step.dependOn(&c_lib.step);
}

/// Runs the consumer package as its own `zig build` in `consumer/`.
///
/// The consumer is a separate package on purpose: a manifest dependency here
/// would close a cycle, because its manifest points back at this package by
/// path. Running it as a separate build is what makes the proof real - that a
/// package which only writes `b.dependency("mimalloc", ...)` and
/// `dep.module("mimalloc")` gets a working, correctly linked library, with the
/// archive and libc arriving through the module and nothing else.
///
/// Everything this build resolved travels with it: the target and CPU, the
/// optimize mode, the library mode, the linkage and dispatch shapes, the
/// executor switches, both cache directories, the install prefix, the job width
/// and the summary. An argument left behind would be a proof of a configuration
/// nobody asked for.
///
/// Run when this host can execute the selected target, and install otherwise:
/// `hostCanExecute` asks exactly what `std.Build.Step.Run` asks of a foreign
/// binary, so the decision here and the nested run cannot disagree. An executor
/// counts only when its `-f` switch was given; a target with none installs,
/// which is compile evidence and never a semantic pass.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) *std.Build.Step.Run {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    // The same query's other half. The triple above names the architecture, the
    // OS and the ABI; it carries no CPU model and no feature set, and `cpu` is a
    // separate option of its own. `serializeCpu` writes `native` for a query that
    // named no CPU and `baseline` for a cross query that named none, and
    // `Target.Query.parseCpu` recognises both spellings, so the nested
    // `standardTargetOptions` resolves this build's selection rather than one of
    // its own. `addArg` copies each argument, so these temporaries can go right
    // after.
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // `b.graph.zig_exe` is the compiler running this build script, so the nested
    // build is the same toolchain rather than whatever is on PATH.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    // The model and its feature set, for the reason the serialization above
    // gives. Without it the nested build would compile the consumer at a
    // baseline CPU on a host that built the library for something else, and the
    // step would prove a configuration nobody asked for.
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // The delivery and dispatch options have to reach the nested build or the
    // consumer would silently check the default graph and say nothing about the
    // configuration that was asked for.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    // Both spellings go, not only the true one, so a cell's configuration is
    // stated rather than inferred from a default and the flag cannot be dropped
    // on the way down.
    run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));
    // The mode *this* build resolved, which is a different question from which
    // option asked for it. `b.systemIntegrationOption` is fed by the build
    // runner's `-fsys=`/`-fno-sys=` flags and is never an entry in the `-D` map,
    // so forwarding `-Dsystem` would set the nested graph's *default* and leave
    // the answer to that graph's own runner instead of this build's. Both
    // spellings go, so the dependency's own `systemIntegrationOption(lib_name,
    // ...)` resolves the answer this build already reached: a dependency shares
    // its parent's `Graph` and `system_library_options` is a field of it.
    run.addArg(if (library == .system) b.fmt("-fsys={s}", .{lib_name}) else b.fmt("-fno-sys={s}", .{lib_name}));
    // Forward the selected executor and its dynamic-linker support.
    if (b.enable_darling) run.addArg("-fdarling");
    if (b.enable_qemu) run.addArg("-fqemu");
    if (b.enable_rosetta) run.addArg("-frosetta");
    if (b.enable_wasmtime) run.addArg("-fwasmtime");
    if (b.enable_wine) run.addArg("-fwine");
    if (b.libc_runtimes_dir) |runtimes| run.addArgs(&.{ "--libc-runtimes", runtimes });
    // The nested build carries this workspace's job count and summary in its own
    // command line. Nothing can append a `-j` to a `Run` step's command, so a
    // nested build left to derive its own width takes `cpu_count - 1` instead,
    // and the consumer this step proves then compiles at a different width from
    // the build that asked for it - and at a different width again on whichever
    // machine runs the gate. `--summary all` is for the same reader: the nested
    // build is a separate graph whose steps are named after the consumer
    // package, and a failure inside it is otherwise one unnamed line.
    run.addArg("-j8");
    run.addArg("--summary");
    run.addArg("all");
    // A null `path` means "the current directory", and the working directory is
    // already the consumer package, so the default is right.
    if (b.cache_root.path) |cache| {
        run.addArg("--cache-dir");
        run.addArg(b.fmt("{s}/consumer", .{cache}));
    }
    // The global cache is inherited whole rather than subdirectoryed: it is one
    // shared store of packages and hashes, so a nested build left to resolve its
    // own would fetch again what this one already holds, and would write outside
    // the root this workspace approved.
    if (b.graph.global_cache_root.path) |global_cache| {
        run.addArg("--global-cache-dir");
        run.addArg(global_cache);
    }
    // The install prefix this invocation resolved, handed on when the caller
    // named one. A nested `zig build` left to resolve its own installs into
    // `consumer/zig-out` - a build artefact inside a source package - rather
    // than into the directory the caller asked for. A relative `--prefix` would
    // resolve against the working directory set above, `consumer/`, and not
    // against this build's root, so it is made absolute before it is handed on.
    // `DESTDIR` needs no forwarding, because the nested build inherits the
    // environment this one ran with.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        const prefix = if (std.fs.path.isAbsolute(b.install_prefix))
            b.install_prefix
        else
            b.pathJoin(&.{ b.graph.cache.cwd, b.install_prefix });
        run.addArg("--prefix");
        run.addArg(prefix);
    }
    // The caller's own arguments, last and behind `--`: `--` is where the build
    // runner stops parsing options and keeps the rest as `b.args`, so this `--`
    // has to follow every argument above - those are this package's own
    // bookkeeping with the nested build, and only what the caller typed after
    // `--` belongs to the program. `consumer/src/main.zig` documents
    // `--provider <path>` as a command-line input, and this is the only place
    // those words can enter the nested graph at all.
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    // The nested build is the step's only observable effect.
    run.has_side_effects = true;
    return run;
}

/// True when this build can execute `target`'s binaries.
///
/// `std.zig.system.getExternalExecutor` is the predicate
/// `std.Build.Step.Run` applies to the artifact it is about to spawn, and
/// `allow_*` carries this build's own executor switches, so the two cannot
/// disagree. `link_libc` holds in every mode this package builds; the `.qemu`
/// arm carries `Run`'s own second gate.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .allow_darling = b.enable_darling,
        .allow_qemu = b.enable_qemu,
        .allow_rosetta = b.enable_rosetta,
        .allow_wasmtime = b.enable_wasmtime,
        .allow_wine = b.enable_wine,
        // `Run` reads this off the artifact it is about to spawn, and the
        // consumer links libc through the `mimalloc` module
        // (`build.zig:485`, `:492`), so the same fact answers here.
        .qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, host, candidate, options)) {
        .native, .rosetta => true,
        // Reachable only for an executor the switches above enabled, each of
        // which `Run` gates on the same switch and nothing else.
        .wine, .wasmtime, .darling => true,
        // Not a yes on its own: `Run` fails a cross GNU libc target given no
        // `--libc-runtimes`, so this step installs it instead.
        .qemu => !(candidate.isGnuLibC() and b.libc_runtimes_dir == null),
        // Same OS and CPU with no dynamic linker to load, or an architecture and
        // system this build has no enabled executor for.
        .bad_dl, .bad_os_or_cpu => false,
    };
}

/// The `mimalloc.pc` a C consumer resolves through.
///
/// The shape is upstream's own `mimalloc.pc.in`, with this build's version and
/// the delivery's actual flag substituted in. `prefix` is `pcfiledir`-relative
/// so the installed file is correct wherever `--prefix` put it. `Cflags` carries
/// the include directory and, for a shared install on Windows,
/// `MI_SHARED_LIB` - which is the same fact `addGraph` puts on the translation,
/// and which a C consumer needs in order to get the same `__declspec(dllimport)`
/// answer without repeating the flag. On ELF and Darwin that macro is an inert
/// spelling of the default visibility (`include/mimalloc.h:63-67`), so putting
/// it in a consumer's `Cflags` there would be noise that changes nothing.
fn add_pkg_config(b: *std.Build, platform: Platform, linkage: std.builtin.LinkMode) void {
    const files = b.addWriteFiles();
    // The returned step is bound to the install step. `addInstallFileWithDir`
    // *creates* a `Step.InstallFile` and nothing more - dropping the return
    // value builds nothing and installs nothing, and the omission is silent.
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
            // Upstream's DLL declaration half, for a shared install and only
            // where `__declspec` exists at all.
            if (linkage == .dynamic and platform.os_tag == .windows) " -DMI_SHARED_LIB=1" else "",
        })),
        .prefix,
        "lib/pkgconfig/mimalloc.pc",
    );
    b.getInstallStep().dependOn(&install_pc.step);
}

/// Installs the licence records beside the artifact.
///
/// A private repository removes no upstream obligation. Upstream's grant is a
/// standalone file, `LICENSE`, and it installs. `NOTICE.md` is the per-file
/// inventory and `FORK-LICENSE.md` is this fork's own grant; both install too,
/// because an installed tree that carries only the upstream text hides both.
fn install_licence_records(b: *std.Build) void {
    for (licence_records) |record| {
        // Bound, for the reason `add_pkg_config` says.
        const install_record = b.addInstallFileWithDir(
            b.path(record),
            .prefix,
            b.fmt("share/licenses/{s}/{s}", .{ lib_name, std.fs.path.basename(record) }),
        );
        b.getInstallStep().dependOn(&install_record.step);
    }
}

/// Installs the public headers, exactly the four upstream installs.
///
/// `CMakeLists.txt:1082-1085`. Upstream installs them flat, with no
/// `include/mimalloc/` subdirectory, because the four of them do not include it.
/// The internal headers are still available to a dependent that wants the
/// complete source, through this repository's `include/` directory, which
/// `addGraph` already puts on the dependent's include path.
fn install_public_headers(b: *std.Build) void {
    for (public_headers) |header| {
        const install_header = b.addInstallFileWithDir(
            b.path(header),
            .prefix,
            b.fmt("include/{s}", .{std.fs.path.basename(header)}),
        );
        b.getInstallStep().dependOn(&install_header.step);
    }
}

/// What makes an operating system unbuildable here, if anything.
///
/// Null for every OS this package targets. The function and its two callers are
/// here because the matrix partition has to be checked against something, and a
/// check with nothing to check against is not a check. An OS that becomes
/// refusable is added here and in `refused_check_targets` in the same change.
fn refusalFor(os_tag: std.Target.Os.Tag) ?[]const u8 {
    _ = os_tag;
    return null;
}

/// The one thing `checkMatrixPartition` checks: that `check_targets` and
/// `refused_check_targets` are a partition.
///
/// A row cannot be quietly wrong in either direction, and a caller finds out from
/// `zig build` rather than from a gate. `refused_check_targets` is empty today;
/// the function exists so that adding a refusal is an edit that has to be
/// consistent with `refusalFor`, and so that deleting one is not silent.
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

/// One configure-time step into one graph.
///
/// -Dsystem links an installed libmimalloc instead of compiling `src/`, and
/// translates the installed headers instead of the bundled ones. This supplies
/// the default of `systemIntegrationOption("mimalloc")`; a build runner that
/// decides the mode itself (-fsys=mimalloc) overrides it.
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
        std.builtin.LinkMode,
        "linkage",
        "Deliver the native library as a static archive (the default) or as a real " ++
            "shared object with upstream's soname scheme: libmimalloc.so.3.5.3 with " ++
            "soname libmimalloc.so.3. This selects the delivery and never the " ++
            "dispatch: the same 21 C units are compiled either way. In system mode " ++
            "this graph builds no artifact at all, so there the option names the " ++
            "kind of installed library to bind to instead, and it defaults to " ++
            "dynamic.",
    );

    // Two defaults, because the two modes had two. The bundled graph compiled a
    // static archive before this option existed and must keep doing so, because
    // that is what a link line or an `LD_PRELOAD` of this library's users
    // expects by default; `linkSystemLibrary`'s own default is `.dynamic`, and
    // system mode must keep that too. Deriving one from the other would silently
    // change a consumer's linkage in the mode that option was not written for.
    const linkage: std.builtin.LinkMode = linkage_option orelse
        (if (library == .system) .dynamic else .static);

    // -Druntime selects the *dispatch*, and it is orthogonal to -Dlinkage: the
    // option says which artifact this build delivers and installs, this one says
    // whether the Zig facade calls it through a link line or through a table an
    // explicit `load(source)` fills. Under `-Druntime` nothing is linked into
    // the facade module at all, so a caller may name a provider this tree did
    // not build - and the artifact is still built and installed, so a caller may
    // equally name the one it did.
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

    // `build.zig.zon .version` and the version this build compiles and stamps
    // into `mimalloc.pc` and the shared object's file name are one fact.
    // `std.SemanticVersion.parse` fails loudly rather than wrapping a
    // non-version, and the comparison catches a manifest edited without the
    // source it describes.
    if (manifest_version.order(upstream_version) != .eq) {
        @panic("build.zig.zon .version no longer matches the version this build " ++
            "compiles from src/ and include/; see UPSTREAM.md");
    }

    // Two lists, one decision function, checked before any graph is configured.
    checkMatrixPartition(b);

    const published = addGraph(b, target, optimize, library, linkage, runtime_loaded, true);

    // In system mode there is no artifact from this tree to install and no
    // header of its own to install, and installing an empty stand-in would be a
    // claim this build cannot make.
    if (published.c_lib) |c_lib| {
        b.installArtifact(c_lib);
        add_pkg_config(b, published.platform, deliveredLinkage(target, linkage));
        install_licence_records(b);
        install_public_headers(b);
    }

    // `zig build` also compiles the example. The example is the cheapest thing
    // that proves the facade, the translated header and the C archive agree on
    // types, symbols and link-time dependencies. It is compiled, not installed:
    // it is a proof, not a deliverable.
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

    // A run artifact already depends on building the executable, which depends
    // on compiling the C and linking the facade. `zig build smoke` deliberately
    // does not depend on the install step: installing is `zig build`'s job and
    // conflating the two would make a smoke run depend on the install layout.
    const run_example = b.addRunArtifact(example);
    run_example.has_side_effects = true;
    if (b.args) |args| run_example.addArgs(args);
    b.step("smoke", "Run the deterministic example program").dependOn(&run_example.step);

    // The test root is `tests.zig`, which names the test blocks; a root that
    // only re-exported them would discover no tests and still exit zero.
    // `addRunArtifact` is used rather than a plain compile so that this is a
    // real runnable test step for whatever `-Dtarget` names: a foreign target is
    // left to whichever executor the cross-test harness detects, and this build
    // does not decide that.
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

    // The separate consumer package, built as its own `zig build`. It runs when
    // this host can execute the selected target and installs when it cannot.
    // An install is compile evidence and nothing more.
    //
    // `library` is the mode `build` resolved, not the option a caller typed, so
    // the nested build is asked for the configuration this build is actually in.
    b.step("consumer", "Build or run the consumer/ package for the selected target")
        .dependOn(&runConsumer(b, target, optimize, library, deliveredLinkage(target, linkage), runtime_loaded).step);

    // The cross target gate. Compiling the tests, the example and the whole C
    // closure for each target is what makes this a check of the facade rather
    // than of an unreferenced archive. Nothing runs here.
    const check_step = b.step(
        "check",
        "Compile the native library, the facade, the tests and the example for " ++
            "each of the six baseline check targets without running any of them",
    );
    if (!target.query.isNative()) {
        add_target_check(b, check_step, target.query, optimize, library, linkage, runtime_loaded);
    } else {
        // `[0..]`, not `.*`: `.*` is for dereferencing a single optional or
        // error-union payload, so the pointer-to-array has to become a slice
        // before it can be iterated.
        for (check_targets[0..]) |query| {
            add_target_check(b, check_step, query, optimize, library, linkage, runtime_loaded);
        }
    }

    // Which configuration this compiled, and which artifact it hands back, are
    // facts worth reading out of the build rather than inferring from a cache
    // directory. These are configure-time lines, not gate results: nothing has
    // been compiled when they print.
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
            // Dispatch is a separate fact from delivery, and a runtime-loaded
            // build links nothing into the facade module: the caller names a
            // provider with an explicit `load(source)` and the symbols arrive
            // through the platform loader. Printing it here is what keeps "the
            // library is still built and installed" from reading as "the module
            // links it".
            std.debug.print(
                "mimalloc: runtime-loaded dispatch (-Druntime=true); the facade module " ++
                    "links no archive and a provider is named by an explicit " ++
                    "load(source)\n",
                .{},
            );
        }
        // See `add_c_library`. A Mach-O or COFF shared object gets an export
        // list here but a Mach-O one gets no mechanism for it, so a Darwin shared
        // object from this build exports mimalloc's `_mi_` internals as well as
        // its API. Said here rather than left to be discovered with `nm -d`.
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
