# Fork notes

The working record for this SDK: what was decided, where the fact came from,
and what each decision does **not** prove.

**No gate has been run.** Nothing in this file is a receipt. Statements read out
of a file or a manifest are `SOURCE-CONFIRMED`; decisions are `CONSTRAINT`;
anything reasoned but unexecuted is a `HYPOTHESIS`; every landed correction with
no gate behind it is `PENDING-VERIFICATION`; §12 is the list of what the driver
still has to run.

## 1. The import, and what verifies it

A release tarball, imported whole and verified by sha256. `SOURCE-CONFIRMED`:
`mimalloc-v3.5.3-source.tar.gz`, published 2026-09-17, 1458292 bytes, sha256
`43857a9e4f26412e970cbe49635d0465c2de6e77a697ce3d4b926a473d1045ca`, extracting
to `mimalloc-d4881d338125e1cb7c47ba4cfb398d6f7c0c8d45/`.

**There was no `git clone`, no submodule and no history.** The extraction
directory name is the commit the archive was built from, and the annotated tag
object `deac3dcf5f0614884013d411a5c07e16bec96c9f` for `v3.5.3` was read from
the GitHub API. Both are recorded in `UPSTREAM.md` **as release metadata, not
as a VCS import**: they cannot reconstruct this tree and nothing here was
derived from them. The identity of the imported bytes is the release sha256 and
the 52 per-file digests.

52 files, 1166419 bytes. `sha256sum -c UPSTREAM.sha256` checks the bytes;
`tools/check-provenance.sh` additionally checks the exact file set, which a
checksum run cannot see — a file added under `include/` or `src/` with no
recorded digest would pass `sha256sum -c` and mean nothing.

One upstream fact that makes the file *set* a question rather than a formality:
the import is the **compiled and installed closure, not the whole release**.
`docs/`, `test/`, `cmake/`, `ide/`, `bin/`, `contrib/` and the root
`CMakeLists.txt` are not vendored, each for a stated reason in `UPSTREAM.md`.
Three files inside the imported set compile to nothing and travel anyway
(§2), so "what is compiled" and "what is vendored" are two different questions
and this package answers both explicitly.

**Bound to:** this project, and the same rule applies to any tarball-only
import in this workspace — record the commit if you like, but do not let it
stand in for a digest, and do not describe an archive import as a VCS import.

## 2. The source closure: 21 units, and three files that are not among them

`SOURCE-CONFIRMED`: `core_sources` in `build.zig` is upstream's own
`mi_sources` list, read out of `CMakeLists.txt:107-126` rather than guessed or
re-derived. It is 21 translation units:

`src/alloc.c`, `src/alloc-aligned.c`, `src/alloc-posix.c`, `src/arena.c`,
`src/bitmap.c`, `src/heap.c`, `src/init.c`, `src/libc.c`, `src/options.c`,
`src/os.c`, `src/page.c`, `src/page-map.c`, `src/prim/prim.c`,
`src/prim/prim-tls.c`, `src/random.c`, `src/sample-guarded.c`,
`src/sample-profile.c`, `src/stats.c`, `src/subproc.c`, `src/theap.c`,
`src/threadlocal.c`.

`src/prim/prim.c` and `src/prim/prim-tls.c` are the platform layer in one:
`src/prim/prim.c:11-25` `#include`s the platform implementation as text and the
`#if` chain decides which. Every platform's implementation therefore lives in
this repository — `unix`, `osx`, `wasi`, `windows`, `emscripten` — and exactly
one is compiled.

**A build that listed a platform directory would be a fork decision, not an
import.** It would duplicate a selection upstream already makes, and it would be
a second place to keep in step with `#if` chain edits. `HYPOTHESIS`, reasoned
and not run: a target this chain does not name would fail at compile time with a
missing symbol rather than at configure time with a clear message. Not observed;
not worth provoking.

Three upstream files are vendored and **not** separately compiled, and all three
are upstream's own doing rather than this fork's preference:

| File | Why it is not a separate unit |
|---|---|
| `src/free.c` | `src/alloc.c:19-22` `#include`s it as text. That is why upstream's own `mi_sources` list has no entry for it. Compiling it separately would define `mi_free` twice. It **is** compiled — as part of `alloc.c` |
| `src/alloc-override.c` | Included by the same three lines, and its whole body is behind `#if defined(MI_MALLOC_OVERRIDE)` (`src/alloc-override.c:13`). This build never defines it, so the unit contributes nothing — see §3 |
| `src/static.c` | The whole-amalgamation unit: `src/static.c:23` includes `alloc.c`, which includes `alloc-override.c` and `free.c`. It exists for a single-object build a C++ compiler can drop into another build, and upstream compiles it **only** as its separate `mimalloc-obj` target (`CMakeLists.txt:1092`). Compiling it alongside the ordinary units would define every symbol twice |

None of the three was edited and none was dropped. That distinction matters:
deleting an uncompiled upstream file would be a source deviation and would move
a digest; keeping it and recording why is a build-graph fact and does not.

## 3. `MI_MALLOC_OVERRIDE`, and why this package is not an override

`MI_MALLOC_OVERRIDE` is never defined — anywhere, on any configuration, on any
target. `SOURCE-CONFIRMED`: it is the one macro that decides whether this
library defines the standard allocator. With it, `src/alloc-override.c:23-120`
and `:240-300` alias `malloc`, `calloc`, `realloc`, `free`, `posix_memalign`
and the C++ `operator new` family onto their `mi_` counterparts; without it,
nothing past line 13 exists.

So the delivered artifact exports `mi_malloc`, `mi_free` and their kin and does
**not** export `malloc`, `free` or the C++ operators. `zig build` prints this
on its configure line, before anything has been compiled, on every run.

**This package does not replace the process allocator, and that is a
decision rather than a limitation.** Four consequences, each checkable:

* No provider already loaded in this workspace is re-routed through it.
* `LD_PRELOAD` is not set by anything here, and no executable this package
  builds links a library that overrides the standard allocator.
* `isRedirected()` answers `false`. In a linked build that is this build's own
  fact; in a runtime-loaded build it is the provider's, and a `dlopen`ed
  `libmimalloc.so` still answers `false` because the process was not preloaded
  with it.
* The runtime loader deliberately does **not** require `mi_is_redirected` to be
  `true`. It is the single most informative fact about a loaded provider and it
  is not a requirement, because requiring it would refuse every provider the
  route exists for (`runtime/library.zig`, "What is deliberately *not* called
  here").

**Making mimalloc the process allocator is a separate migration.** Upstream
describes how — `LD_PRELOAD=... myprogram`, the Windows redirection DLL, the
override headers — and none of it is what this package does. It would be a
change to whatever would consume it: a link line, a preload, or a call site.
It would carry its own measurement, in RSS, throughput, fragmentation and in
every other process on the machine sharing the loader. It is not part of this
addition and no document here may be read as endorsing it.

The `MI_MALLOC_OVERRIDE` decision is also why `zig/translate.h` defines no macro
of its own and includes only `<mimalloc.h>`: defining it on the translation
header would put a C definition of `malloc` into the translation — an
interposition this package does not perform, and a symbol a `libmimalloc.so`
this build did not compile would not export.

**Bound to:** this package. The transferable rule is narrower and worth
stating: *an allocator package that does not claim to be the process allocator
must leave the override macro undefined on every compile line including the
translation header, and must say so in the facade, not only in its build file.*
A consumer reading `zig/root.zig` alone should not have to read `build.zig` to
learn that.

## 4. `MI_WIN_NOREDIRECT=1`: a configuration choice, not a patch

On Windows, `MI_WIN_NOREDIRECT=1` is defined.

`SOURCE-CONFIRMED`: this is upstream's *own* switch. `CMakeLists.txt:323-327`
defines it exactly this way when `MI_WIN_REDIRECT` is off, and `MI_WIN_REDIRECT`
is off by default (`CMakeLists.txt:54`). It matters here because
`src/prim/windows/prim.c:1165-1198` compiles, under
`MI_SHARED_LIB && !MI_WIN_NOREDIRECT`, a block declaring
`__declspec(dllimport) mi_allocator_init` — a symbol exported by upstream's
separate `mimalloc-redirect` DLL, which this package does not build
(`CMakeLists.txt:1060`).

**This is a choice among two upstream-supported configurations, not a patch.**
Upstream supports both; the other one is real and available. It is declined here
because it would require this package to build and install a second artifact
whose entire purpose is to be preloaded into processes this package has not
been asked to own — which is the same boundary §3 draws, reached by a different
door.

Nothing upstream was edited to make this work, and no upstream source line was
changed to accommodate it. That is the whole distinction, and it is why this
belongs in "Native-build deviations" in `README.md` rather than in "Native-source
deviations".

## 5. `-std=gnu11`, named rather than inherited

`SOURCE-CONFIRMED`, two reasons, both from upstream's own text:

* `include/mimalloc/atomic.h:53-55` includes C11 `<stdatomic.h>` on every
  non-C++, non-MSVC target. There is no lower dialect that has it, so the C
  level is not a preference.
* `gnu11` rather than `c11` because upstream's own sources take GNU extensions
  inside `#if defined(__GNUC__)` guards — `src/prim/prim.c:31-44` keys a
  constructor attribute off `__GNUC__` — and a strict `-std=c11` would hide those
  extensions from those guards.

Nothing else belongs on the compile line. `src/alloc.c:7-8` and
`src/prim/unix/prim.c:10-11` each define `_DEFAULT_SOURCE` themselves, before
including anything that needs it, so **no feature-test macro is added by this
build** — adding one would override upstream's own arrangement with a second
one.

**Bound to:** C projects whose headers include `<stdatomic.h>` on some targets
and whose sources guard GNU extensions on others. In that situation `-std=gnu11`
is the one line that satisfies both without editing a file; the check that it was
the *only* thing needed is that upstream defines its own feature-test macros
early, which is not a general property.

## 6. Two declarations upstream never defines, and what they cost this build

`mi_collect_reduce` (`include/mimalloc.h:435`) and `mi_stats_merge`
(`include/mimalloc.h:438`) sit in upstream's public header, in its own
`Deprecated` block, and are defined in **no** translation unit of the v3.5.3
source closure.

`SOURCE-CONFIRMED`: each appears in exactly one place in the 52-file import —
its own declaration — and nowhere else. The nearest real symbol is
`_mi_stats_merge_into` (`include/mimalloc/internal.h:318`, defined at
`src/stats.c:451-455`), which is the *internal* merge helper the public
declaration's name suggests was a public wrapper around.

Three places handle it, and the choice of the three matters more than the
handling:

1. **The vendored header is not patched.** Not to remove the declarations, not
   to add definitions, not to add `#if` around them. Editing one vendored file
   moves the integrity record for the whole 52-file set and destroys the
   "byte-identical to the tarball" claim the entire provenance story rests on —
   in exchange for papering over a defect upstream owns. The defect is recorded
   here instead.
2. **The runtime loader excludes them**, which is what shapes
   `runtime/graph.zig`'s `provider_excluded`:

   ```zig
   const provider_excluded = "mi_collect_reduce,mi_stats_merge";
   ```

   Without that line a *required* set containing them would fail **every**
   load on **every** platform, against a perfectly good provider — the failure
   would say nothing about the provider and everything about upstream's header.
   A name in `provider_excluded` is routed and optional rather than direct, so
   the declaration is still a routed call rather than a reference the C library
   has to satisfy, and its absence cannot fail any other symbol's load.
   `provider_optional` is **empty** and is written out rather than omitted, so
   that adding a header with a genuinely optional entry point is a change in
   that file with a name in it.
3. **The Zig facade calls neither**, so a linked build never asks the linker for
   a symbol that does not exist. A dependent that reaches one through
   `pub const c` gets a link error, which is the honest answer rather than a
   stub that would return a plausible nothing.

`mi_stats_reset` (`include/mimalloc.h:437`) and `mi_stats_print_out` (`:441`) sit
in the same block, **are** defined, and are wrapped normally —
`statsReset()` and `statsPrintTo()` in the facade. The two undeclared names are
not a signal that the block is dead; they are two missing definitions among
twelve declarations.

**Bound to:** any fork of a C library whose public header declares a function
it does not define. The rule is: *record the defect in your own build files,
exclude the name from a required-symbol set that would otherwise be refused
wholesale, and never edit the vendored header to make your build succeed.*

## 7. Why `mimalloc-stats.h` is not in `zig/translate.h`

`zig/translate.h` includes exactly one header, `<mimalloc.h>`, and defines no
macro. The other four installed headers are excluded, and the statistics header
is excluded for two reasons that **both** matter to a build:

1. `<string.h>`. `include/mimalloc-stats.h:12-13` opens `<mimalloc.h>`,
   `<string.h>` and `<stdint.h>`. Pulling `<string.h>` into the translation
   drags the C library's whole string surface across every target family this
   package can be configured for, and would force a several-hundred-name noise
   list in `runtime/graph.zig` that this build would then have to keep honest
   for six families. The current list is 19 names because the closure
   `include/mimalloc.h` opens — `<stddef.h>`, `<stdbool.h>`, `<assert.h>`
   (`include/mimalloc.h:98-100`) — is unusually small. Adding `<string.h>` to it
   is a different order of magnitude.
2. **`mi_stats_t` is a fixed-layout table of `size_t` counters**
   (`include/mimalloc-stats.h:106-121`) that upstream extends between minor
   versions. Modelling it in Zig by hand would be re-deriving a layout the
   library owns, which is exactly what a facade must not do.

Neither reason alone would be decisive: the entry points a caller actually wants
are declared in `<mimalloc.h>` itself — `mi_stats_print_out`
(`include/mimalloc.h:441`), `mi_process_info` (`:204`), `mi_options_print_out`
(`:202`) — and reach through this wrapper unchanged. The two together are
decisive.

**The other three are excluded for the same but simpler reason:**
`mimalloc-override.h` and `mimalloc-new-delete.h` are the interposition
wrappers (§3), and `mimalloc-profile.h` adds only compile-time profiling knobs
(`include/mimalloc-profile.h:12-13`).

All five are still **installed**, unchanged, by `build.zig`, because they are
upstream's installed headers and a C++ or profiling consumer of the installed
tree needs them. What is not translated and what is installed are two different
questions, and upstream's own install list (`CMakeLists.txt:1082-1085`) is the
answer to the second: `mimalloc.h`, `mimalloc-override.h`,
`mimalloc-new-delete.h`, `mimalloc-stats.h` — four, flat, with no
`mimalloc/` subdirectory, because the four do not include it.
`include/mimalloc-profile.h` and the seven internal headers ship in the package
and are not installed, because upstream does not install them either.

## 8. `libc_noise`, and where those nineteen names came from

`runtime/graph.zig` classifies the C library's own names as noise so the
dispatch does not route them: `__assert, __assert13, __assert2, __assert_fail,
__assert_perror_fail, __assert_rtn, __assert_single_arg, __diagassert,
__diagassert13, _assert, _errno, _get_errno, _set_errno, _wassert,
__threadhandle, __threadid, __max_align_ld, __max_align_ll`.

**They were read out of the pinned Zig 0.16.0 distribution's own
`lib/libc/include` headers, not out of a `translate-c` run, because this build
has never been executed.** That is a deliberate substitution and it is a
limitation, so both halves are stated:

* Each name is cited in `runtime/graph.zig` by path and line — for example
  `generic-glibc/assert.h:95` for `__assert_fail`,
  `any-windows-any/stddef.h:18` for `_errno`,
  `any-darwin-any/_assert.h:63` for `__assert_rtn`,
  `generic-openbsd/stddef.h:78-79` for `__max_align_ll`/`__max_align_ld`.
* The families covered are the ones `lib/libc/include` holds for a target this
  package can be built for: `any-darwin-any`, `any-windows-any`,
  `generic-glibc`, `generic-musl`, `generic-freebsd`, `generic-netbsd`,
  `generic-openbsd`. `wasm32-wasi` resolves `generic-musl`.
* The list is a **union across families** on purpose. A name a given target's
  libc does not declare never appears in that target's translation, so the
  entry costs nothing; a name that was *missing* would be routed and would turn
  every load on that family into a `MissingSymbol`.

Two details that are easy to get wrong and are load-bearing:

* **Every line of the list ends with a comma.** `runtime/generate.zig` reads
  these three lists through `std.mem.splitScalar(u8, list, ',')` and a Zig
  multiline string concatenates its lines with nothing between them, so a line
  without a trailing comma glues its last name to the next line's first into a
  token matching neither declaration — and both get routed.
* **Each name is listed exactly, not by a `__` prefix rule.** A prefix rule
  would also swallow `_mi_` internal names if a header ever exposed one.

**Open, and owed to a gate:** this list has not been compared against a real
translation for any target. If a name is wrong, the failure mode is symmetric —
a name listed that should not be stays direct and a `libmimalloc.so` that does
not export it fails to link in a linked build; a name missing from the list gets
routed and becomes a `MissingSymbol` at load time on that family. Neither has
been observed, because nothing has been run.

**Bound to:** this package, and to any runtime-loading route over a header whose
libc closure has not been measured for the target. The transferable half: *a
noise list read out of headers is a hypothesis about a translation until a
translation has been produced, and it should be labelled as one at the point it
is written.*

## 9. The runtime-loading seam

`-Druntime` swaps `translate.createModule()` for `runtime/graph.zig`'s
`createModule`. **The one thing a caller must not do is link the compiled C
archive into a module that imports this dispatch**: the facade's `c` import is
the dispatch, and if anything else in the graph references the library the
linker resolves the symbols statically and the runtime route silently becomes a
linked one.

The route has four parts and one generated file:

| File | What it is |
|---|---|
| `runtime/loader.zig` | the reusable state machine and platform layer, holding no per-SDK name. Imported by the facade in **both** configurations, because `LoadSource` and `LoadError` must be the same types whichever configuration is built |
| `runtime/library.zig` | this SDK's descriptor: the namespaced synchronization binding, the one load-time check, and the ABI boundary |
| `runtime/generate.zig` | the build-time generator, run on the build machine over **the real translation step's output**, so the dispatch describes the headers this build selected rather than another one |
| `runtime/graph.zig` | the build half: wires the three modules together and substitutes `createModule` |
| `runtime/sync.c`, `runtime/sync.h` | the process-global mutex, condition variable and thread identity, compiled with `-DRT_SYNC_PREFIX=mimalloc_rt` |

The properties, all of which are the shared route's and none of which is
particular to mimalloc:

* **One process-lifetime table.** No unload, no reset, no per-handle state.
* **Explicit provider selection.** `.path` names a file, `.system` names a
  library for the platform loader. Neither falls back to the other and there is
  no implicit fallback of any kind.
* **Atomic publication.** Nothing is published until every required symbol
  resolved and the provider's own validation passed.
* **No automatic retry.** A failed attempt publishes nothing; retry is an
  explicit second `load`.
* **An ordinary pre-initialization panic in every optimization mode.** Calling
  into a module that has not loaded stops the program naming the function. It
  is not a debug assertion, because there is no partial state to fall back on
  and a release build that silently allocated from a stale or null table would
  be worse.
* **Linked calls stay direct.** `-Druntime` changes the dispatch, not the
  public types.

`RT_SYNC_PREFIX` must be changed in **two** places together — the compile flag
in `runtime/graph.zig` and the prefix `runtime/library.zig` binds — and a build
where they disagree fails to link, which is the whole error report. A binary
that needs two independent instances of this SDK changes both and gives the
second its own copy of both files; nothing else in the package assumes one.

## 10. The ABI boundary, and the three source lines in one release

The supported external ABI family is **mimalloc v3**, `MI_MALLOC_VERSION`
30503 (`include/mimalloc.h:11`), built from this repository's `src/` and
`include/` with no override macro defined.

**The v1 and v2 sources are published in the same `v3.5.3` release as the v3
one.** The release carries `mimalloc-v1.15.2-source.tar.gz`,
`mimalloc-v2.5.2-source.tar.gz` and `mimalloc-v3.5.3-source.tar.gz`, and all
three export the same `mi_malloc`/`mi_free` spellings under the same header
names. A provider built from the v2 or v1 line **passes a symbol check and is a
different ABI**. That single fact is why the loader checks `mi_version` before
publishing anything, and why it is the only thing that separates the families.

The rest of the boundary, stated in `runtime/library.zig` and repeated in
[`README.zig.md`](README.zig.md): the v3 layout is not the v2 layout
(`mi_heap_area_t`, `include/mimalloc.h:308-316`, is a plain struct a
block-visiting callback reads through); the whole surface is about memory the
*provider* owns and nothing in this SDK can observe, bound or account for it;
the six callback types cross the boundary in both directions with the
provider's calling convention; and `mi_process_init` and `mi_collect` are
process-wide effects a table cannot isolate.

**What the loader checks, and what it deliberately does not.** Checked: `mi_version`
answers this header's `MI_MALLOC_VERSION`, then one allocation and one free
through the same table — `mi_malloc` for 64 bytes, `mi_usable_size` reporting at
least that many, `mi_any_heap_contains` claiming it, `mi_free` returning it. Not
called: `mi_process_init`, `mi_process_done` and `mi_is_redirected` (see §3).
Resolving symbols and translating a header **is** the boundary; neither is proof
of compatibility, and this package does not pretend to check more than it checks.

## 11. The six-target check matrix

`check` compiles the native library, the translation, the facade, the tests and
the example for each of `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`aarch64-macos-none`, `x86_64-windows-gnu`, `riscv64-linux-gnu` and
`wasm32-wasi`, and **runs nothing**.

**`refused_check_targets` is empty and `checkMatrixPartition` enforces that it
stays a partition.** A target cannot be quietly wrong in either direction, and a
caller finds out from `zig build` rather than from a gate: adding a target whose
operating system `refusalFor` refuses is a configure-time panic, and a target in
`refused_check_targets` whose operating system `refusalFor` no longer refuses is
*also* a configure-time panic telling the author to move it back and prove it
builds. `refusalFor` is null for every OS this package targets today.

**Why `wasm32-wasi` is in the matrix and not out of it:**
`src/prim/prim.c:17-19` selects `src/prim/wasi/prim.c` under `__wasi__`, so
upstream ships the primitives for it. Excluding the row would be excluding the
one target that most needs to be compiled. Whether a cell links and runs is for
the driver's gate to observe; this file claims nothing either way.

**What `check` is not.** It compiles; it runs nothing. `std.testing.refAllDeclsRecursive`
does not prove a body was instantiated, an unreferenced C archive is not a
check, and **no test number may be read out of a `check` run** — not even "the
tests compiled".

**The one refusal in this build is about a delivery, not a target.**
`deliveredLinkage` needs a platform with a dynamic linker, and `wasm32-wasi`
has none, so `-Dlinkage=dynamic` is refused on that row. The default static
build of the same row is not refused and is in the matrix. That is a property of
the delivery, not of the source.

## 12. What the driver still has to run

Only row 11 below has been run; §12a records it. Every other row is
`PENDING-VERIFICATION`, and there is no test count to report for any of them
until a gate produces one.

| # | Gate | Command |
|---|---|---|
| 1 | Install step, bundled static | `zig build -j8 --summary all` |
| 2 | Install step, bundled shared | `zig build -Dlinkage=dynamic -j8 --summary all` |
| 3 | Behavioural tests, Debug | `zig build test -j8 --summary all` |
| 4 | Behavioural tests, ReleaseSafe | `zig build test -Doptimize=ReleaseSafe -j8 --summary all` |
| 5 | Example program | `zig build smoke -j8 --summary all` |
| 6 | Six-target compile-only check | `zig build check -j8 --summary all` |
| 7 | One foreign target, compiled | `zig build -Dtarget=aarch64-linux-gnu -j8 --summary all` |
| 8 | Runtime-loaded route against an explicit provider | `zig build test smoke -Druntime=true -j8 --summary all` |
| 9 | System mode against an installed provider | `zig build -Dsystem=true -j8 --summary all` |
| 10 | Consumer package, entered directly | `cd consumer && zig build run -j8 --summary all` |
| 11 | Published platform matrix | `"$HOME/.local/bin/cross-test"` from the package root |
| 12 | Provenance, digests and notices | `tools/check-provenance.sh` |

Each carries the driver's `--cache-dir` under the approved cache root. Record
for each: command, optimize mode, target, exit code, date and receipt path.

**Three things to read off those runs specifically, because nothing here can
predict them:**

* Row 8 against a provider this tree built and installed — a `dlopen`ed
  `libmimalloc.so.3` named explicitly, not a linked copy standing in for it.
  The whole test binary should run through the dispatch, not only the example.
* Row 11's cell classification. `build_only` is compiled-not-run and is **never**
  a pass; record how many cells executed, how many compiled without a runner,
  how many were refused and how many failed, separately.
* Row 12's file-set check, which is the part `sha256sum -c` cannot do.

## 12a. Row 11 has now run — 2026-10-05

`OBSERVED`. Full receipt in README.md, "The full platform matrix". Command,
compiler, optimize mode, exit code and receipt path are there; this section
records what the run says and what it does not settle.

`cross-test --jobs 8 --build-jobs 8` from the package root, unmodified
`cross-test.profile.sh`, Zig 0.16.0 at
`$ZIG_GLOBAL_CACHE_DIR/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig`,
step `test`, `Debug`. `target_count=53`, `bookkeeping_failure=false`.
**Harness exit 1**: `status=fail pass=10 fail=19 build_only=24 partial=0`.
`run_id 20261005-191559-58950-7377`, summary at
`$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/mimalloc/cross-test-summary.json`.
Wall time 1293 s.

Row 11's three sub-questions, answered with counts:

* **Executed: 20 cells.** 10 passed all 34 tests; 10 failed after executing.
* **Compiled without a runner: 24 cells**, all `build=pass exit=0` with
  `run=unavailable`. Named individually in README.md with the per-cell reason.
  None of them is a pass and none is counted as behaviour evidence.
* **Refused by this build: 0 cells.** `refused_check_targets` stays empty.
* **Failed: 19 cells**, in three groups of nine, nine and one.

The nineteen failures have three distinct causes, and only one of the three is
a genuine platform boundary:

1. **Nine `*-netbsd` cells — pinned-toolchain boundary, established.**
   `zig translate-c` exit 1, `error: 5 compilation errors`, after
 `compile lib mimalloc Debug <target> success` had already been logged. The
   errors are inside the toolchain's own
   `lib/libc/include/generic-netbsd/sys/cdefs.h:413`
   (`_Pragma("GCC visibility pop")` reached from `assert.h:105` `__END_DECLS`
   via `cdefs.h:432` `__END_PUBLIC_DECLS`). Isolated: a file containing only
   `#include <assert.h>` fails to translate for `aarch64-netbsd` and succeeds
   for `aarch64-linux` and `x86_64-freebsd`; the same file with
   `#define _Pragma(x)` prepended translates cleanly for `aarch64-netbsd`.
   `include/mimalloc.h:100` requires `<assert.h>`, so no build-configuration
   change removes it and no vendored file may be edited to dodge it.
2. **Nine 32-bit cells — a defect in *this fork's* test, not a boundary.**
   All nine fail the single test `'an aligned block at an offset puts the
   offset on the boundary'` with 33 of 34 passing, and all nine carry the same
   upstream message `aligned allocation with a large alignment cannot be used
   with an alignment offset (size 256, alignment 65536, offset 8)` from
   `src/alloc-aligned.c:66-70`. `MI_PAGE_MAX_OVERALLOC_ALIGN` is
   `MI_ARENA_SLICE_SIZE` (`types.h:510`) = `1 << (13 + MI_SIZE_SHIFT)`
   (`types.h:235`, `:217`) and `MI_SIZE_SHIFT` is 3 on 64-bit but 2 on 32-bit
   (`bits.h:57-62`). The bound is therefore **65536 on 64-bit and 32768 on
   32-bit**. `tests.zig:217` filters on the literal `65_536` and
   `probe_alignments` (`tests.zig:88`) ends in `65_536`, so on a 32-bit target
   the test asks for a request upstream documents it refuses, and reports the
   refusal as an allocator failure. Every 64-bit cell passes and every 32-bit
   cell fails, which is the signature of a width-dependent constant. **The fix
   is in `tests.zig` and has not been made**: derive the bound from
   `MI_SIZE_SIZE` or from the translated `MI_PAGE_MAX_OVERALLOC_ALIGN` rather
   than writing 65536. Nothing was weakened, skipped or `|| true`-ed to get
   here; the cells are recorded as they ran.
3. **`hexagon-linux` — the executor, not this source. Established by
   observation.** 9 pass, 25 crash of 34, `signal ABRT`. Nondeterministic: one
   fixed binary at one fixed argument, ten repeats, all six QEMU CPU models
   (`v66 ..X.XXXX..`, `v67 .XXX..XXXX`, `v68 .X.XXX.X..`, `v69 XX.XXXX..X`,
   `v71 X..XXX.XXX`, `v73 ..X.XXXXX.`). The `-O2 -DMI_DEBUG=2` build fails
   10/10 with QEMU's own assertion
   `ERROR:../target/hexagon/translate.h:100:ctx_log_pred_read_new: assertion
   failed: (test_bit(pnum, ctx->pregs_written))`. The `-O2 -DNDEBUG` build of
   the same program passes 10/10 at sizes 8..256, plain `malloc`/`free` passes,
   and 32- and 64-bit `__atomic` ops plus `__builtin_rotl32`/`rotr32` all
   report OK. `bits.h:88-103` lists seven arch macros and no Hexagon. This cell
   stays a **runtime failure of the test environment** and is never counted as
   evidence about mimalloc on Hexagon.

**What row 11 did not settle.** It says nothing about `build_only` behaviour
(nothing ran), nothing about `-Dlinkage=dynamic`, `-Dsystem=true` or
`-Druntime=true`, and nothing about rows 1-10 and 12, which remain
`PENDING-VERIFICATION`. The native `x86_64-linux` cell is the only one that ran
on the host itself; the other nine passes ran under QEMU user mode, which is
real execution but is not the host ABI.

## 13. Open questions and things that are not known yet

Stated rather than papered over, and each is a real gap rather than a
disagreement:

* **`libc_noise` is unverified against any translation** (§8). It was read out
  of the pinned Zig 0.16.0 distribution's headers because no gate has run. Rows
  3 and 8 are what would confirm or refute it.
* **The Windows rows are entirely unobserved.** `MI_WIN_NOREDIRECT=1`,
  `MI_SHARED_LIB`/`MI_SHARED_LIB_EXPORT`, the module-definition export list and
  the `dllimport` half of a consumer's `Cflags` are all reasoned from upstream's
  own source and CMake, and none has been compiled. Row 6 covers the
  compile half of it and says nothing about a DLL consumer.
* **A Mach-O or COFF shared object gets no version script here.** ELF gets one;
  Mach-O and COFF do not, so a shared object from this build exports mimalloc's
  `_mi_` internals as well as its `mi_` API. `zig build` prints that difference
  on its configure line rather than leaving it to be discovered with `nm -d`. It
  is a capability boundary, not an oversight, and it is a property of the
  object format rather than something this graph can fix.
* **There is no leak oracle and none will be supplied** (§14). Any future claim
  that this package "leaks nothing" is unobservable here by construction, and a
  test that asserts it would be asserting something its own framework is not in
  a position to detect.

## 14. The no-leak-oracle rule, stated once for this package

Where memory crosses into a third-party allocator, say so; a test framework
cannot supply a leak oracle for it.

`SOURCE-CONFIRMED`, from the shape of the boundary: `mi_malloc` returns a block
from mimalloc's own arena and `mi_free` puts it back (`src/alloc.c:338` ->
`src/alloc.c:289-295` -> `src/page.c`). A Zig test allocator holds a record of
its own outstanding blocks and can detect a leak of memory **it** handed out. It
cannot detect a leak of memory mimalloc owns: the block was never its, so there
is nothing for it to miss.

**No test in this package asserts that it leaks nothing, and none may be added
that does.** `std.testing.allocator` is the wrong instrument for this boundary,
and a test that used it to check mimalloc's blocks would be reporting a leak
oracle's silence as a result. `Block`, `Heap` and the typed slice views exist so
that the correct free is visible at the call site instead.

The same rule applies to the callback types: a `BlockVisitFn` or `HeapVisitFn`
receives a pointer the provider owns, and this package does not take ownership of
it or free it.

**Bound to:** this package, and to every SDK in this workspace whose library owns
its memory across the FFI boundary. The transferable statement: *a leak check
only measures the allocator that made the allocation, and a test suite that
claims otherwise is reporting the absence of an observer as an observation.*