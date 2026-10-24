# mimalloc

Zig 0.17.0 SDK for upstream mimalloc v3.5.3.
It provides a typed facade, the translated C API, and optional runtime or system integration.

## Source deviations

- No upstream source file is modified. The package imports 52 files from the official v3.5.3 release; `UPSTREAM.sha256` records them.
- The package uses the v3 source line only. Upstream's v1/v2 trees, documentation, tests, CMake files, IDE files, binaries, and contrib files are not imported; see `UPSTREAM.md`.
- Upstream declares `mi_collect_reduce` and `mi_stats_merge` but defines neither in v3.5.3. Calling either through `c` fails to link in linked mode; runtime loading does not require them from a provider.
- `mi_malloc_size` and `mi_malloc_usable_size` require upstream's allocator override, which this package disables. Linked calls fail to link; runtime loading treats these declarations as optional. Use `mi_usable_size` for package-owned blocks.
- `README.upstream.md` preserves upstream's README. `NOTICE.md` and `FORK-LICENSE.md` record attribution and file-specific terms.

## Build deviations

- `build.zig` compiles the 21 C translation units in upstream's source closure. It does not use CMake, autotools, or a build-time download.
- `src/free.c` and `src/alloc-override.c` are included by `src/alloc.c`; `src/static.c` is the alternative amalgamation unit and is not compiled separately.
- The C build uses `-std=gnu11`. Windows builds set `MI_WIN_NOREDIRECT=1`; `MI_MALLOC_OVERRIDE` stays undefined, so the package does not interpose `malloc` or build the CRT redirect DLL.
- Static and shared deliveries use the same source list. Static is the default; ELF shared builds use `libmimalloc.so.3` as the soname.
- Runtime mode generates a dispatch from the translation output; the facade links no archive, but the library artifact is still built and installed. System mode translates installed headers and builds or installs no artifact.
- Installation includes the library, four public headers, `lib/pkgconfig/mimalloc.pc`, and license records under `share/licenses/mimalloc/`.

## Support matrix

| Target or mode | Boundary |
|---|---|
| Configured baseline targets | `x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`, `x86_64-windows-gnu`, `riscv64-linux-gnu`, `wasm32-wasi` |
| `check` | Native builds compile baseline targets compatible with the selected mode; shared linkage or runtime loading excludes static-only targets. Cross builds check only the selected target. |
| `wasm32-wasi` | Static linkage only; no dynamic loader. Runtime loading and shared linkage are unavailable. |
| Emscripten, freestanding | Runtime loading is unavailable without a dynamic loader. |
| NetBSD | Zig 0.17.0 `translate-c` rejects NetBSD's `assert.h`, which reaches `_Pragma` in `sys/cdefs.h`. |
| 32-bit tests | One alignment test requests 65,536 bytes; upstream's 32-bit maximum is 32,768 bytes. |
| Mach-O and COFF shared builds | No ELF version script; internal `_mi_` symbols are not filtered. |

## Consumption

The package name is `mimalloc`; its version is `3.5.3` and its minimum Zig version is `0.17.0`.

Add a path dependency in the consumer's `build.zig.zon`:

```zig
.dependencies = .{
    .mimalloc = .{ .path = "../mimalloc" },
},
```

Use the public module or compiled artifact in the consumer's `build.zig`:

```zig
const dep = b.dependency("mimalloc", .{});
exe.root_module.addImport("mimalloc", dep.module("mimalloc"));
```

The module is named `mimalloc` and exports the typed facade plus `pub const c`. The artifact is also named `mimalloc`; use `dep.artifact("mimalloc")` for link-only consumption. Static builds produce `libmimalloc.a`; dynamic builds produce a shared library.

Build options: `-Dlinkage=static|dynamic` (default `static`), `-Druntime=true`, `-Dsystem=true` or `-fsys=mimalloc`, and the standard `-Doptimize` and `-Dtarget` options.

A C consumer uses the installed headers and links `-lmimalloc`; `mimalloc.pc` supplies pkg-config flags. For a shared Windows C build, define `MI_SHARED_LIB=1`.

## Runtime checks

Runtime checks need an existing shared provider, even when `-Dlinkage=static` selects the bundled artifact.
Each step reads a separate environment variable containing an absolute provider path:

| Step | Variable |
|---|---|
| `test` | `MIMALLOC_PROVIDER` |
| `smoke` | `MIMALLOC_SMOKE_PROVIDER` |
| `consumer` | `MIMALLOC_CONSUMER_PROVIDER` |

Set all three variables when you run these steps together:

```sh
provider=/absolute/path/libmimalloc.so.3
MIMALLOC_PROVIDER="$provider" \
MIMALLOC_SMOKE_PROVIDER="$provider" \
MIMALLOC_CONSUMER_PROVIDER="$provider" \
zig build test smoke consumer -Druntime=true
```

The `smoke` and `consumer` steps also accept `-- --provider <absolute path>`. The `test` step still needs `MIMALLOC_PROVIDER`.
