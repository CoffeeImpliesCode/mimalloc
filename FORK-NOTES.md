# Fork notes

## Source deviations

No vendored upstream source file is modified. The imported files are recorded in `UPSTREAM.sha256`.

| File | Change | Reason |
|---|---|---|
| `zig/root.zig` | Adds a typed facade over mimalloc's C API | Keep allocator ownership and error handling explicit |
| `zig/translate.h` | Translates only `mimalloc.h` and defines no override macro | Limit the C surface and avoid allocator interposition |
| `runtime/loader.zig` | Adds explicit-provider loading with one process-lifetime table | Support runtime loading without implicit fallback |
| `runtime/library.zig` | Adds the mimalloc provider descriptor and load-time checks | Reject an incompatible provider before publishing it |
| `runtime/generate.zig` | Generates dispatch from the selected target's translation | Keep dispatch declarations aligned with the build |
| `runtime/graph.zig` | Wires the loader, descriptor and generated dispatch | Select linked or runtime-loaded calls |
| `runtime/sync.c`, `runtime/sync.h` | Add prefixed mutex and condition-variable support | Synchronize loader state without symbol collisions |

Upstream declares `mi_collect_reduce` and `mi_stats_merge` in `include/mimalloc.h` but defines neither. The facade does not call them, and the runtime descriptor excludes them from its required symbols.

`mi_malloc_size` and `mi_malloc_usable_size` are defined only under `MI_MALLOC_OVERRIDE` in `src/alloc-override.c`. The runtime descriptor also excludes these from required symbols.

## Build graph deviations

- `build.zig` compiles the 21 units in upstream's `mi_sources` closure; it does not run CMake, autotools or a build-time download.
- `src/free.c` is included by `src/alloc.c`, `src/alloc-override.c` is inactive while `MI_MALLOC_OVERRIDE` is undefined, and `src/static.c` is the alternative amalgamation unit. Compiling these separately would duplicate definitions or enable allocator interposition.
- The core uses `-std=gnu11` for C11 atomics and upstream's GNU extensions. Upstream defines its own feature-test macros.
- On Windows, the build sets `MI_WIN_NOREDIRECT=1`; it does not build the separate CRT redirection DLL.
- Bundled builds default to static linkage. Dynamic linkage uses the same source closure and upstream's shared-library ABI version.
- `-Dsystem=true` uses an installed library and headers; the graph does not build or install a bundled artifact in that mode.
- `-Druntime=true` generates dispatch from the same target translation and leaves the C artifact unlinked from the module. A caller must select a provider explicitly.
- The runtime descriptor checks `mi_version` and performs a small allocation/free sanity check. This does not prove full ABI compatibility.
- Missing-symbol errors print the required symbol name before rejecting a provider.
- COFF's export list includes all public-header functions defined by the non-override source closure, including the four word-sized allocation helpers without `mi_decl_export`.
- The 0.17 build API does not expose enabled executors to configuration, so the root consumer step runs native targets and installs foreign targets.
- Nested Zig 0.17 builds inherit `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LIB_DIR`; removed build flags are not forwarded.
- WASI sets `MI_ARENA_SLICE_SHIFT=(13 + MI_SIZE_SHIFT)` because Zig 0.17's `PAGE_SIZE` expands to a linker expression in upstream's preprocessor condition.
- WASI defines `_WASI_EMULATED_PROCESS_CLOCKS` for upstream's `clock()` fallback; Zig 0.17 includes that implementation in its WASI libc.

## Platform boundaries

- `wasm32-wasi` can use static linkage; dynamic linkage is rejected because the target has no dynamic linker.
- Windows uses upstream's non-redirect configuration. This package does not replace the process allocator.
- Mach-O and COFF shared builds have no ELF-style version script; this graph does not filter internal `_mi_` symbols there.
- Zig 0.17's bundled NetBSD headers fail `translate-c` on the `_Pragma("GCC visibility pop")` in `sys/cdefs.h`, reached through `assert.h`.
- A 32-bit test still requests 65,536-byte alignment, while upstream's limit is 32,768 bytes on 32-bit targets. This is a test-bound issue, not an allocator source patch.
