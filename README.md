# mimalloc

mimalloc v3.5.3 — a compact general purpose allocator with excellent
performance characteristics — as a complete standalone Zig SDK: the whole v3
core, the public C headers, a typed Zig surface, the raw translated C route and
an optional runtime-loading route, built from the official release sources with
no CMake, no autotools and no build-time download.

* Upstream: the `mimalloc-v3.5.3-source.tar.gz` release, 2026-09-17, 1458292
  bytes, sha256
  `43857a9e4f26412e970cbe49635d0465c2de6e77a697ce3d4b926a473d1045ca` — see
  [`UPSTREAM.md`](UPSTREAM.md).
* Native source: unmodified. Every one of the 52 vendored upstream files is
  recorded by digest in [`UPSTREAM.sha256`](UPSTREAM.sha256).
* Licence: MIT for mimalloc itself, per file and with two exceptions the
  inventory names; MIT for this fork's own files — see [`NOTICE.md`](NOTICE.md)
  and [`FORK-LICENSE.md`](FORK-LICENSE.md). Upstream's notice, reproduced here
  because a downstream reading only this file must still see it, is
  `Copyright (c) 2018-2025 Microsoft Corporation, Daan Leijen`
  ([`LICENSE`](LICENSE):3); the per-file banners carry
  `Copyright (c) 2018-2026, Microsoft Research, Daan Leijen` and a different
  year range in each file (`include/mimalloc.h`:2), which is what
  [`NOTICE.md`](NOTICE.md)'s inventory is for.
* Upstream's own README is preserved verbatim in
  [`README.upstream.md`](README.upstream.md).
* **No gate has been run for this package.** Every row of the matrix below is
  `PENDING-VERIFICATION` and the driver owns those results.
* **This package does not replace your allocator.** See the section of that
  name below, which is not a footnote.

## Native-source deviations

**None.** Every file under `include/` and `src/`, plus `LICENSE`,
`README.upstream.md` and `SECURITY.md`, is byte-identical to the release
tarball. No portability patch, no reformat, no `#if` wrapped around a platform
workaround, and no header edited to remove a declaration upstream wrote.

That is a checkable claim rather than an assertion:

```sh
sha256sum -c UPSTREAM.sha256          # the bytes
tools/check-provenance.sh             # the bytes, the exact file set, the notices
```

A checksum run alone cannot see a file that appears under `include/` or `src/`
with no recorded digest, so the file *set* is a separate check from the
digests. Any future native edit has to move those digests, add a per-file
record to [`NOTICE.md`](NOTICE.md) and add a numbered entry to
[`CHANGELOG.md`](CHANGELOG.md) in the same change, and needs an observed
failure to justify it.

Four upstream facts shape this SDK, all read out of the source rather than
assumed:

* **The import is the compiled closure, not the whole release.** Upstream also
  ships `docs/`, `test/`, `cmake/`, `ide/`, `bin/`, `contrib/` and its root
  `CMakeLists.txt`. None is vendored, each for a stated reason in
  [`UPSTREAM.md`](UPSTREAM.md), "What was NOT taken". Nothing was dropped for
  size: three files inside the imported set compile to nothing and travel
  anyway.
* **Two header declarations have no definition.** `mi_collect_reduce`
  (`include/mimalloc.h:435`) and `mi_stats_merge` (`include/mimalloc.h:438`) are
  declared by the vendored header and defined nowhere in the v3.5.3 source
  closure. They are upstream's, and this fork did not stub them, patch them out
  or add them. See "The two declarations upstream never defines" below.
* **Nothing is generated at build time from upstream's side.** mimalloc has no
  configure step and no generated header; `CMakeLists.txt` selects platform
  macros rather than producing inputs. This build does generate files — the
  installed `mimalloc.pc`, a version script on ELF, and under `-Druntime=true`
  the dispatch — and none of them is a second source of truth for the C.
* **The release carries three source lines.** The v1 and v2 sources are published
  in the **same** `v3.5.3` release beside the v3 one, and all three export the
  same `mi_malloc`/`mi_free` spellings under the same header names. This SDK is
  the v3 line and says so where it can be checked — see the ABI boundary in
  [`README.zig.md`](README.zig.md).

### The two declarations upstream never defines

`mi_collect_reduce` and `mi_stats_merge` sit in upstream's own `Deprecated`
block in `include/mimalloc.h` and are defined in no translation unit of the
imported source. `SOURCE-CONFIRMED`: they appear in exactly two places in the
whole 52-file import, both in that header (`include/mimalloc.h:435` and `:438`),
and nowhere else.

Three consequences, and all three are design decisions rather than workarounds:

* A **linked** build never asks the linker for either one, because the Zig
  facade does not call them. A dependent that reaches for one through
  `pub const c` gets a link error, which is the honest answer.
* The **runtime** loader excludes both from the symbol set it requires a
  provider to export — `provider_excluded` in `runtime/graph.zig` — so their
  absence cannot fail every *other* symbol's load on every platform.
* The header is **not patched**. Recording an upstream defect in this
  repository's build files and records is where it belongs; editing the
  vendored header would break the "byte-identical to the tarball" claim for
  every one of the 52 digests to fix a defect that upstream owns.

### What this package does not import

Not one line of the import re-implements anything. `zig/root.zig` is a facade:
it turns NULL into one honest error, checks an alignment rule upstream only
asserts, and names the ownership boundary. Every value that comes back out of
it was produced by the C under `src/`.

## Native-build deviations

What the compiled package does that upstream's CMake does not. Each is a fork
decision with a stated reason; none changes an algorithm, and none edits an
upstream file.

* **Zig builds it; upstream's build system is unused.** `build.zig` compiles
  the closure `CMakeLists.txt:107-126` names — the `mi_sources` list, read out
  of that file rather than guessed — which is 21 translation units: `alloc.c`,
  `alloc-aligned.c`, `alloc-posix.c`, `arena.c`, `bitmap.c`, `heap.c`,
  `init.c`, `libc.c`, `options.c`, `os.c`, `page.c`, `page-map.c`,
  `prim/prim.c`, `prim/prim-tls.c`, `random.c`, `sample-guarded.c`,
  `sample-profile.c`, `stats.c`, `subproc.c`, `theap.c` and `threadlocal.c`. No
  CMake, no autotools, no make, and no download at build time. The two
  `prim/prim*.c` entries are the platform layer: `src/prim/prim.c:11-25`
  `#include`s the platform implementation as text and the `#if` chain decides
  which one, so exactly one of `unix`, `osx`, `wasi`, `windows`, `emscripten`
  is compiled and nothing in this graph lists a platform directory.
* **Three upstream files are carried and not separately compiled, and all three
  are upstream's own doing.**
  * `src/free.c` is `#include`d as text by `src/alloc.c:19-22`, which is why
    upstream's own list has no entry for it. Compiling it separately would
    define `mi_free` twice.
  * `src/alloc-override.c` is included by the same three lines and its whole
    body is guarded by `#if defined(MI_MALLOC_OVERRIDE)`
    (`src/alloc-override.c:13`), a macro this build never defines. The unit
    contributes nothing.
  * `src/static.c` is the whole-amalgamation translation unit
    (`src/static.c:23` includes `alloc.c`, which includes `alloc-override.c` and
    `free.c`) for a single-object build a C++ compiler can drop into another
    build. Upstream compiles it only as its separate `mimalloc-obj` target
    (`CMakeLists.txt:1092`). Compiling it here as well would define every
    symbol twice.
* **`-std=gnu11` is named explicitly.** `include/mimalloc/atomic.h:53-55`
  includes C11 `<stdatomic.h>` on every non-C++, non-MSVC target and there is
  no lower dialect that has it. `gnu11` rather than `c11` because upstream's
  own sources take GNU extensions in `#if defined(__GNUC__)` paths —
  `src/prim/prim.c:31-44` keys a constructor attribute off `__GNUC__` — and a
  strict `-std=c11` would hide those extensions from those guards. Nothing
  else belongs on the compile line: `src/alloc.c:7-8` and
  `src/prim/unix/prim.c:10-11` each define `_DEFAULT_SOURCE` themselves, before
  including anything that needs it.
* **On Windows, `MI_WIN_NOREDIRECT=1` is defined.** This is upstream's *own*
  switch for not using the CRT redirection module: `CMakeLists.txt:323-327`
  defines it exactly this way when `MI_WIN_REDIRECT` is off, and `MI_WIN_REDIRECT`
  is off by default (`CMakeLists.txt:54`). It matters here because
  `src/prim/windows/prim.c:1165-1198` compiles, under
  `MI_SHARED_LIB && !MI_WIN_NOREDIRECT`, a block declaring
  `__declspec(dllimport) mi_allocator_init` — a symbol exported by upstream's
  separate `mimalloc-redirect` DLL, which this package does not build
  (`CMakeLists.txt:1060`). **This is a choice among two upstream-supported
  configurations, not a patch**, and the other one is a real option this package
  declines because it would need a second artifact.
* **Two deliveries, one source list.** `-Dlinkage=static` (the default)
  produces `libmimalloc.a`; `-Dlinkage=dynamic` produces a real shared object
  with upstream's own soname scheme — `CMakeLists.txt:997` sets
  `VERSION ${mi_version}` and `SOVERSION ${mi_version_major}` — so
  `libmimalloc.so.3.5.3` with soname `libmimalloc.so.3`. The option selects the
  delivery and nothing about the compilation: the same 21 C units are compiled
  either way. On Windows the shared delivery additionally gets
  `MI_SHARED_LIB`/`MI_SHARED_LIB_EXPORT`, which is the declaration half of the
  same split (`include/mimalloc.h:39-67`).
* **A typed Zig surface beside the raw one.** `zig/root.zig` publishes a
  documented facade over the same library; the translated headers are reached
  as `c` **on that same module**, not registered as a module of their own.
  Documented in [`README.zig.md`](README.zig.md).
* **Optional runtime loading.** `-Druntime=true` replaces
  `translate.createModule()` with `runtime/graph.zig`'s `createModule`, which
  generates a dispatch from the same translation step's output and links no
  archive at all. It is orthogonal to `-Dlinkage`: the artifact is still built
  and installed, because a caller may name a provider this tree did not build.
* **Optional system mode.** `-Dsystem=true` (default false; `-fsys=mimalloc`
  overrides it) binds to an installed `libmimalloc` through
  `systemIntegrationOption` and translates the installed headers instead of the
  bundled ones. In that mode this graph builds no artifact and installs nothing
  — there is no stand-in to install — and the default linkage is `dynamic`,
  because `linkSystemLibrary`'s own default is and the bundled graph's default
  is static; deriving one from the other would silently change a consumer's
  linkage in the mode that option was not written for. The `consumer` step
  resolves the same mode and forwards it into the nested build, so
  `zig build consumer -Dsystem=true` reaches the installed library rather than
  quietly proving the bundled graph a second time.
* **The full installed closure, from one writer.** `lib/libmimalloc.a` or the
  three shared names; `include/` with the four headers upstream installs
  (`mimalloc.h`, `mimalloc-override.h`, `mimalloc-new-delete.h`,
  `mimalloc-stats.h`), flat and with no `mimalloc/` subdirectory because the
  four of them do not include it (`CMakeLists.txt:1082-1085`);
  `lib/pkgconfig/mimalloc.pc`; and `share/licenses/mimalloc/` holding
  `LICENSE` — upstream's own grant — together with `NOTICE.md`,
  `FORK-LICENSE.md` and `UPSTREAM.md`. Which headers install is upstream's
  decision about its own installed surface, not this graph's:
  `include/mimalloc-profile.h` and the seven internal headers ship in the
  package and are **not** installed, exactly as upstream does not install them.
* **One version, two places.** `build.zig` refuses to configure unless
  `build.zig.zon`'s `.version` equals the 3.5.3 read out of
  `include/mimalloc.h:11`, so the manifest, the `mimalloc.pc` `Version:` field
  and the shared object's file name cannot describe three different releases.
  It parses the manifest string as a semantic version rather than comparing it
  as text, so a manifest edited into something that is not a version fails
  there instead of wrapping.

### History of these deviations

The deviations above are the current state and all of them landed when this
package was added. [`CHANGELOG.md`](CHANGELOG.md) numbers them, and
[`FORK-NOTES.md`](FORK-NOTES.md) records the evidence and the open questions
behind each one — the source-closure decisions, the `MI_MALLOC_OVERRIDE`
decision, the Windows switch, the C dialect, the two undefined declarations and
the runtime seam.

## This package does not replace your allocator

**Nothing in this workspace is routed through mimalloc.** Not one provider that
is already loaded here, not one link line, not one call site.

Four facts, each of which is a property of this build rather than a promise
about the future:

* **`MI_MALLOC_OVERRIDE` is never defined — anywhere, on any configuration, on
  any target.** It is the one macro that decides whether this library defines
  the standard allocator: with it, `src/alloc-override.c:23-120` and `:240-300`
  alias `malloc`, `calloc`, `realloc`, `free`, `posix_memalign` and the C++
  `operator new` family onto their `mi_` counterparts. Without it the unit is
  empty past line 13.
* **So the artifact exports `mi_malloc`, `mi_free` and their kin, and does NOT
  export `malloc`, `free` or `operator new`.** `zig build` prints this on its
  configure line, every time, before anything has been compiled.
* **No executable built by this package links a library that overrides the
  standard allocator**, and nothing in this package sets `LD_PRELOAD` or
  otherwise interposes.
* **`isRedirected()` answers `false`.** It is upstream's own predicate
  (`include/mimalloc.h:329`, `src/init.c:510-512`) and it reports what the
  provider says about itself: the honest answer for a `dlopen`ed
  `libmimalloc.so` is `false`, because the process was not preloaded with it.
  The runtime loader deliberately does **not** require it to be `true` — that
  would refuse every provider the route exists for.

Upstream's own README describes the ways mimalloc *can* be made the process
allocator (`LD_PRELOAD=... myprogram`, the Windows redirection DLL, the
override headers). None of them is what this package does, and nothing here
should be read as claiming otherwise.

**Making mimalloc the process allocator is a separate migration.** It would be
a change to whatever would consume it — a link line, a preload, or a call site
— and it would carry its own measurement: what it costs in RSS, in throughput,
in fragmentation, and in every other process on the machine that shares the
loader. It is not part of this addition, no gate here was run to justify it, and
no document in this repository should be read as an endorsement of it.

## Current support matrix

**Every row except the published platform matrix is `PENDING-VERIFICATION`.**
The driver runs these; this table is the contract it runs them against. The
platform-matrix row has been run and is recorded below under "The full
platform matrix"; its status is `OBSERVED`, red in 19 of 53 cells, with every
cell classified and every cause named. No other gate has been run for this
package, and no test count is claimed for any of them.

| Gate | Command | Status |
|---|---|---|
| Install step, bundled static | `zig build -j8 --summary all` | PENDING-VERIFICATION |
| Install step, bundled shared | `zig build -Dlinkage=dynamic -j8 --summary all` | PENDING-VERIFICATION |
| Behavioural tests, Debug | `zig build test -j8 --summary all` | PENDING-VERIFICATION |
| Behavioural tests, ReleaseSafe | `zig build test -Doptimize=ReleaseSafe -j8 --summary all` | PENDING-VERIFICATION |
| Example program | `zig build smoke -j8 --summary all` | PENDING-VERIFICATION |
| Six-target compile-only check | `zig build check -j8 --summary all` | PENDING-VERIFICATION |
| One foreign target, compiled | `zig build -Dtarget=aarch64-linux-gnu -j8 --summary all` | PENDING-VERIFICATION |
| Runtime-loaded route, explicit provider | `zig build test smoke -Druntime=true -j8 --summary all` | PENDING-VERIFICATION |
| System mode, installed provider | `zig build -Dsystem=true -j8 --summary all` | PENDING-VERIFICATION |
| Consumer package, entered directly | `cd consumer && zig build run -j8 --summary all` | PENDING-VERIFICATION |
| Published platform matrix | `"$HOME/.local/bin/cross-test"` from the package root | `OBSERVED` 2026-10-05 — exit 1, 53 cells: 10 pass, 19 fail, 24 build_only. [Receipt](#the-full-platform-matrix) |
| Provenance, digests and notices | `tools/check-provenance.sh` | PENDING-VERIFICATION |

Every command takes the driver's `-j8` and `--summary all`, plus its own
`--cache-dir` under the approved cache root. The options are the package's
five: `-Dsystem`, `-Dlinkage`, `-Druntime`, `-Doptimize` and `-Dtarget`.

### The six-target check, and what it is not

`zig build check` compiles the native library, the translation, the facade, the
tests and the example for each of the six baseline targets and **runs nothing**:

`x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`,
`x86_64-windows-gnu`, `riscv64-linux-gnu`, `wasm32-wasi`.

`refused_check_targets` is **empty**: all six are checked and none is dropped.
`wasm32-wasi` is in the matrix rather than out of it because
`src/prim/prim.c:17-19` selects `src/prim/wasi/prim.c` under `__wasi__`, so
upstream ships the primitives for it and excluding the row would be excluding
the one target that most needs to be compiled. `checkMatrixPartition` enforces
the partition against `refusalFor`, so a target can only be added to one list
by an edit that says which.

**A successful foreign compile is `build_only`, and it is never a pass.** It is
coverage of the compiler, not evidence about behaviour. `check` itself runs
nothing, so no test number may be read out of it — not even "the tests
compiled".

The one refusal in this build is about a *delivery*, not a target:
`deliveredLinkage` needs a platform with a dynamic linker, and `wasm32-wasi`
has none. That refuses `-Dlinkage=dynamic` on that row; the default static
build of the same row is not refused and is in the check matrix.

### The full platform matrix

The 53-platform matrix is **not** a `zig build` step. It is run by the
host-local `cross-test` harness, driven by `cross-test.profile.sh` from the
package root, and it supplies native or foreign execution itself. `build_only`
cells there are compiled-not-run coverage and are recorded separately from
executed ones, never as passes.

#### `OBSERVED` — the 53-cell run, 2026-10-05

Command, from the package root:

```sh
. "$HOME/.local/lib/host-scratch.sh" || exit 1
"$HOME/.local/bin/cross-test" --jobs 8 --build-jobs 8 \
  --output "$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/mimalloc"
```

Compiler: `0.16.0` at
`$ZIG_GLOBAL_CACHE_DIR/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig`.
Optimize mode: `Debug` (the profile's `CROSS_BUILD_STEP=test`, unmodified).
`target_count=53`, `target_jobs=8`, `jobs_per_build=8`,
`build_timeout_seconds=1800`, `run_timeout_seconds=900`,
`bookkeeping_failure=false`.

**Harness exit code 1.** Console receipt:
`cross-test: status=fail pass=10 fail=19 build_only=24 partial=0`.
Summary receipt:
`$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/mimalloc/cross-test-summary.json`
(`schema 2`, `run_id 20261005-191559-58950-7377`); per-cell logs are under
`…/cross/mimalloc/runs/20261005-191559-58950-7377/`.

The 53 cells classify as **10 pass, 19 fail, 24 build_only, 0 partial**. Every
passing cell reports `run.tests = 34`: the whole suite, all 34 tests, on each
one. Nothing was sampled and no cell was dropped.

| Class | Cells | What was observed |
|---|---|---|
| **pass** | 10 | `x86_64-linux` (native), `aarch64-linux`, `aarch64_be-linux`, `loongarch64-linux`, `mips64-linux`, `mips64el-linux`, `powerpc64-linux`, `powerpc64le-linux`, `riscv64-linux`, `s390x-linux`. 34/34 tests each; exit 0 on build and run. |
| **build_only** | 24 | Built clean (build exit 0) and **not executed**: no local runner for the OS or ABI. Never a pass. |
| **runtime_fail** | 10 | Built clean and ran under QEMU user mode. Nine cells: **33 pass / 1 fail** of 34, one named test. `hexagon-linux`: **9 pass / 25 crash**, nondeterministic. Causes below. |
| **refused** | 0 | No cell was refused by this build. |
| **compile_fail** | 9 | The nine `*-netbsd` cells: `zig translate-c` exit 1. Named boundary below. |

`build_only` is not one undifferentiated bucket. It is 24 named cells, and
each is compiled-but-never-run because the host has no executor for it:
`aarch64-freebsd`, `aarch64-maccatalyst`, `aarch64-macos`, `aarch64-openbsd`,
`aarch64-windows`, `arm-freebsd`, `arm-openbsd`, `mips64-openbsd`,
`mips64el-openbsd`, `powerpc-openbsd`, `powerpc64-freebsd`, `powerpc64le-freebsd`,
`powerpc64-openbsd`, `riscv64-freebsd`, `riscv64-openbsd`, `thumb-windows`,
`wasm32-wasi`, `x86-openbsd`, `x86-windows`, `x86_64-freebsd`, `x86_64-maccatalyst`,
`x86_64-macos`, `x86_64-openbsd`, `x86_64-windows`.

The harness records `reason=runtime_unavailable` on all 24. The per-OS detail
comes from the same run's `cross-test --list` receipt, which names the missing
executor per target: `no_local_runner_freebsd` (6), `no_local_runner_maccatalyst`
(2), `no_local_runner_macos` (2), `no_local_runner_openbsd` (9),
`unsupported_windows_arch` (2: `aarch64-windows`, `thumb-windows`),
`missing_wasmtime` (1: `wasm32-wasi`), `missing_wine` (1: `x86-windows`),
`missing_wine64` (1: `x86_64-windows`). That same `--list` also reports
`no_local_runner_netbsd` for 9 targets; those 9 are the `*-netbsd` cells of
Boundary 2, which failed at build and so never reached a run phase.

#### Boundary 1 — `hexagon-linux` is a QEMU defect, not a mimalloc or QEMU-runner limit

This is the one cell in the run whose cause is **not** upstream's and **not**
this fork's, and it is recorded here rather than hidden. `hexagon-linux` built
clean and then crashed 25 of its 34 tests with `signal ABRT`, the first
reported failure being `tests.test.every size is honoured, and the usable
size is at least the request`.

The cause is a defect inside the QEMU Hexagon translator, established by
observation, not by inference:

1. **Nondeterministic.** The same binary, the same argument, the same
   emulator, repeated 10 times at `sz=64`: `v66 ..X.XXXX..`, `v67 .XXX..XXXX`,
   `v68 .X.XXX.X..`, `v69 XX.XXXX..X`, `v71 X..XXX.XXX`, `v73 ..X.XXXXX.`. All
   six CPU models the emulator offers (`v66 v67 v68 v69 v71 v73`) fail, and
   none is stable. A defect in this fork's source cannot be
   nondeterministic across identical inputs.
2. **QEMU asserts against itself.** The same program built `-O2` with
   `MI_DEBUG=2` fails 10 of 10 runs with a QEMU-internal assertion, not a
   mimalloc message:
   `ERROR:../target/hexagon/translate.h:100:ctx_log_pred_read_new: assertion
   failed: (test_bit(pnum, ctx->pregs_written))`. That is a failed invariant
   inside `target/hexagon/translate.h`, in QEMU's own source tree.
3. **The allocator is not at fault on the same inputs.** Built `-O2` with
   `-DNDEBUG`, the identical program passes 10 of 10 runs at every size
   tested (8, 32, 48, 64, 128, 256). Plain `malloc`/`free` under the same
   emulator passes. `__atomic` fetch-add, compare-exchange, load and store —
   32-bit and 64-bit — all report `OK` on every run. `__builtin_rotl32` and
   `__builtin_rotr32`, which `mi_ptr_encode`/`mi_ptr_decode`
   (`include/mimalloc/internal.h:1292`, `:1281`) are built from, both report
   `OK`.
4. **Upstream's own arch table has no Hexagon entry.** `bits.h:88-103` names
   `MI_ARCH_ARM64`, `MI_ARCH_X64`, `MI_ARCH_X86`, `MI_ARCH_ARM32`,
   `MI_ARCH_RISCV`, `MI_ARCH_RISCV32` and `MI_ARCH_RISCV64` and nothing else.
   A repository-wide search for `hexagon` in `include/` and `src/` returns
   nothing. Upstream states support for "Windows, macOS, Linux, WASM, various
   BSD's, Haiku, MUSL, etc" (`README.upstream.md:35-36`) and Hexagon is not
   among them.

The four observations agree: the Debug-mode free-list corruption message is
the *symptom* the emulator produces, and the emulator's own failing invariant
is the cause. `zig cc --print-targets` lists `hexagon - Hexagon` with no
`[experimental]` marker, so the target is nominally supported by the compiler;
the defect is in the executor. This cell is a **runtime failure of the test
environment**, and it stays a failure. It is not relabelled a pass, not
skipped, and not counted as behaviour evidence about mimalloc on Hexagon.

#### Boundary 2 — the nine `*-netbsd` cells cannot be translated by the pinned compiler

`aarch64-netbsd`, `aarch64_be-netbsd`, `arm-netbsd`, `armeb-netbsd`,
`mips-netbsd`, `mipsel-netbsd`, `powerpc-netbsd`, `x86-netbsd` and
`x86_64-netbsd` each failed at `zig translate-c` with exit 1 and
`error: 5 compilation errors`, identically, with `compile lib mimalloc
Debug <target> success` already logged before the failure. The C library
itself compiles for NetBSD; what fails is the translation of this package's
one header, and it fails **inside the pinned toolchain's own NetBSD libc
headers**, not inside any file in this repository:

```
lib/libc/include/generic-netbsd/sys/cdefs.h:413:45: note: expanded from here
#  define __END_PUBLIC_DECLS __END_EXTERN_C _Pragma("GCC visibility pop")
lib/libc/include/generic-netbsd/assert.h:105:1: error: expected ';', found ''
__END_DECLS
```

`assert.h:105` is `__END_DECLS`, which `generic-netbsd/sys/cdefs.h:432`
expands to `__END_PUBLIC_DECLS`, which at `:413` uses `_Pragma`. Isolated and
confirmed:

* `translate-c -lc -target aarch64-netbsd` over a file containing **only**
  `#include <assert.h>`: exit 1.
* The same file with only `#include <stddef.h>`: exit 0. With only
  `#include <stdbool.h>`: exit 0. `<assert.h>` is the specific header, and
  `include/mimalloc.h:100` includes it.
* Prepending `#define _Pragma(x)` to that same one-header file:
  `translate-c -lc -target aarch64-netbsd` **exit 0**.

So the pinned Zig 0.16.0 `translate-c` cannot lower `_Pragma` inside
NetBSD's `__END_DECLS`, and `mimalloc.h` cannot be translated for a NetBSD
target because upstream's own header requires `<assert.h>`. A build
configuration change cannot remove that dependency, and no vendored file may
be edited to work around it. `x86_64-freebsd` and `aarch64-linux` translate
`#include <assert.h>` cleanly, so this is specific to the NetBSD header set,
not to `assert.h` in general. Nine cells, one cause, established from the
toolchain's own source and from observed messages. This is a **platform
boundary of the pinned toolchain**, and it is left failing on the record.

#### Boundary 3 — the 32-bit `aligned_at` refusal, which is upstream's own bound

The ten `runtime_fail` cells are `arm-linux`, `armeb-linux`, `hexagon-linux`,
`mips-linux`, `mipsel-linux`, `powerpc-linux`, `riscv32-linux`, `thumb-linux`,
`thumbeb-linux` and `x86-linux`. Nine of them fail the same single test with
the same message, `error: 'tests.test.an aligned block at an offset puts the
offset on the boundary' failed`, and with 33 of the other 34 tests passing.

The message is mimalloc's own, at `src/alloc-aligned.c:66-70`: a non-zero
offset is refused outright above `MI_PAGE_MAX_OVERALLOC_ALIGN`, and the
observed text is `aligned allocation with a large alignment cannot be used
with an alignment offset (size 256, alignment 65536, offset 8)`.

That bound is **width-dependent, and the test that trips it does not know
that**. `MI_PAGE_MAX_OVERALLOC_ALIGN` is `MI_ARENA_SLICE_SIZE`
(`include/mimalloc/types.h:510`), which is `1 << MI_ARENA_SLICE_SHIFT`
(`:235`), which is `13 + MI_SIZE_SHIFT` (`:217`), and `MI_SIZE_SHIFT` is 3 on
64-bit and 2 on 32-bit (`include/mimalloc/bits.h:57-62`). So the bound is

* **65536** where `SIZE_MAX == UINT64_MAX` (the 64-bit cells, which pass), and
* **32768** where `SIZE_MAX == UINT32_MAX` (the 32-bit cells).

`tests.zig:217` filters with `if (alignment > 65_536) continue;`, and
`probe_alignments` (`tests.zig:88`) ends in `65_536`. On a 32-bit target
65536 is therefore **above** upstream's bound and upstream refuses it, which is
the refusal the test then reports as an allocator failure. On a 64-bit target
65536 is exactly at the bound and the same request succeeds — which is why
every 64-bit cell passes and every 32-bit cell fails. The comment at
`tests.zig:188-195` states the bound is upstream's and reads 64 KiB; that is
correct for 64-bit and wrong for 32-bit, because the constant is
width-dependent.

This is a **defect in this fork's test, not in upstream and not in the
toolchain**, and it is named as one. The fix belongs in `tests.zig`: derive
the bound from `MI_SIZE_SIZE` (or from the translated `MI_PAGE_MAX_OVERALLOC_ALIGN`
in the `c` module) instead of writing 65536 as a literal. **No edit has been
made here.** A behavioural test has not been weakened, no skip has been added
and no `|| true` has been written; the ten cells are recorded as they ran. The
cell outcomes stand as observed, and the nine 32-bit failures attributed to
this cause are `runtime_fail`, not a platform boundary.

`hexagon-linux` appears in this table because the harness counted it here,
but its cause is Boundary 1 and not this one: it fails 25 of 34 tests, not 1
of 34, and nondeterministically.

## Consumption

### From Zig, typed

`@import("mimalloc")` is the documented facade published by `zig/root.zig`.
`zig build` installs it as the module a dependent names:

```zig
// build.zig of the dependent
const mimalloc = b.dependency("mimalloc", .{});
exe.root_module.addImport("mimalloc", mimalloc.module("mimalloc"));
```

```zig
// the dependent's source
const mimalloc = @import("mimalloc");

pub fn main() !void {
    var block = try mimalloc.Block.alloc(64);
    defer block.deinit();
    @memset(block.bytes(), 0);
}
```

One behavioural detail belongs here rather than being left to be discovered:
**every pointer this module returns is owned by mimalloc, not by Zig.** It goes
back to `free`, `Heap.free` or `Block.deinit`, and to nothing else. Handing one
to `std.heap.page_allocator` or to a `defer testing.allocator.free(...)` is a
mismatched free, not a leak — which is why `Block` and `Heap` exist. The full
surface, its ownership rules and the ABI a loaded provider must satisfy are in
[`README.zig.md`](README.zig.md).

The escaped raw route is one name away and is the same library:

```zig
const c = @import("mimalloc").c;   // the translated include/mimalloc.h
```

`c` is re-exported **on the `mimalloc` module**, not published as a module of
its own: registering it separately would hand a dependent the declarations
without the library that satisfies them.

### From Zig, as a static archive

`dep.artifact("mimalloc")` returns the compiled `libmimalloc.a` (or the shared
object under `-Dlinkage=dynamic`) for a dependent that wants to link or
`install` it rather than import the module.

### From C

The installed tree carries upstream's own four public headers and the library,
so a C consumer needs an include path and `-lmimalloc`:

```c
#include <mimalloc.h>

void* p = mi_malloc(64);
/* p belongs to mimalloc: return it with mi_free, not free */
mi_free(p);
```

```sh
cc -I"$prefix/include" prog.c -L"$prefix/lib" -lmimalloc -o prog
```

Note the header is `mimalloc.h`, that every pointer it returns is
mimalloc's, and that a C consumer of a shared build on Windows needs
`-DMI_SHARED_LIB=1` to get the same `__declspec(dllimport)` answer the
translation gets.

The installed layout, in full:

```
include/mimalloc.h
include/mimalloc-override.h
include/mimalloc-new-delete.h
include/mimalloc-stats.h
lib/libmimalloc.a                       # or libmimalloc.so.3.5.3 + soname libmimalloc.so.3
lib/pkgconfig/mimalloc.pc
share/licenses/mimalloc/LICENSE
share/licenses/mimalloc/NOTICE.md
share/licenses/mimalloc/FORK-LICENSE.md
share/licenses/mimalloc/UPSTREAM.md
```

`pkg-config --cflags --libs mimalloc` reports the same thing from the installed
`mimalloc.pc`, which for a shared install on Windows also carries
`-DMI_SHARED_LIB=1`. Its `prefix` is `pcfiledir`-relative, so the file is
correct wherever `--prefix` put it.

### Runtime loading

`-Druntime=true` swaps the linked calls for calls through one
process-lifetime table, selected explicitly:

```zig
const mimalloc = @import("mimalloc");

fn start() !void {
    try mimalloc.load(.{ .path = "/usr/lib/libmimalloc.so.3" });  // an absolute path
    try mimalloc.load(.{ .system = "libmimalloc.so.3" });        // the soname
}
```

There is **no path-to-system fallback, no automatic retry and no unload**.
Calling any native entry point before a successful load stops the program with
a message naming the function, in every optimization mode — that is a
programming error rather than a recoverable condition, because the table does
not exist yet and there is no partial state to fall back on. A second `load`
with the same request succeeds and changes nothing; a different request after a
success is `ProviderMismatch` and the library already in use stays in use.

One load has **not** been observed for this package. Loading a table is a
pointer-resolution step, not an ABI proof: the scalar, layout, configuration,
callback and allocator requirements a provider must meet are listed in
[`README.zig.md`](README.zig.md) and in `runtime/library.zig`, and the only
thing the loader checks at load time is `mi_version` answering this header's
`MI_MALLOC_VERSION`, plus one allocation and one free through the same table.

## Commands

```sh
zig build                                            # the library, headers, .pc, licence records
zig build -Dlinkage=dynamic                          # the same, as libmimalloc.so.3.5.3
zig build test                                       # Debug
zig build test -Doptimize=ReleaseSafe
zig build smoke
zig build check                                      # six targets, compiles only, runs nothing
zig build consumer                                   # the separate consumer/ package
zig build -Dsystem=true                              # against an installed libmimalloc
sha256sum -c UPSTREAM.sha256                         # the upstream bytes
tools/check-provenance.sh                            # the bytes, the exact file set, the notices
"$HOME/.local/bin/cross-test"                        # the published platform matrix
```

## Documents in this repository

| File | What it is |
|---|---|
| [`README.md`](README.md) | this file: deviations, matrix, consumption |
| [`README.zig.md`](README.zig.md) | the public API of `zig/root.zig`, its ownership rules and the runtime ABI boundary |
| [`UPSTREAM.md`](UPSTREAM.md) | which upstream, what was taken, what was not, and how it was imported |
| [`UPSTREAM.sha256`](UPSTREAM.sha256) | the digest of every vendored upstream file |
| [`NOTICE.md`](NOTICE.md) | the per-file licence inventory, upstream and fork |
| [`FORK-LICENSE.md`](FORK-LICENSE.md) | the grant for this fork's own files |
| [`FORK-NOTES.md`](FORK-NOTES.md) | the working record: decisions, evidence and open questions |
| [`CHANGELOG.md`](CHANGELOG.md) | the numbered history, newest last |
| [`README.upstream.md`](README.upstream.md) | upstream's own `readme.md`, byte for byte |
| [`LICENSE`](LICENSE) | upstream's MIT grant, as the release carries it |
| [`SECURITY.md`](SECURITY.md) | upstream's own security policy |