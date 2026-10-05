# Changelog

Numbered, newest last. Each entry says what changed and what it did **not**
prove.

**One gate has been run for this package: the 53-platform cross-test matrix,
recorded in entry 3 below.** Every other entry lands as `PENDING-VERIFICATION`;
nothing else here is a receipt for a build, a test, a smoke run or a
cross-target check, and no test count is quoted for any of them. Statements
read out of files are marked `SOURCE-CONFIRMED` and name the file and line they
came from. Only the driver may move anything to `VERIFIED`, and only beside an
observed run.

## 1. 2026-10-05 — the mimalloc v3.5.3 SDK is added

The first entry in this file is this addition: a standalone foundation library
for mimalloc, mirroring the existing forks, built from the official release
sources with no CMake, no autotools and no build-time download.

### What landed

**The import.** The upstream release `mimalloc-v3.5.3-source.tar.gz` (published
2026-09-17, 1458292 bytes, sha256
`43857a9e4f26412e970cbe49635d0465c2de6e77a697ce3d4b926a473d1045ca`) was
imported: `LICENSE`, `README.upstream.md` (the tarball's own `readme.md`, byte
for byte) and `SECURITY.md`; all 12 headers under `include/`; and all 37 files
under `src/`. **52 files, 1166419 bytes**, every one recorded by digest in
`UPSTREAM.sha256`.

`SOURCE-CONFIRMED`: no vendored file has been edited. There is no portability
patch, no reformat and no header edited to remove a declaration upstream wrote.
The import is a release tarball and not a VCS import — there is no clone, no
history and no patch series; the commit and the annotated tag object in
`UPSTREAM.md` are recorded as release metadata read from the GitHub API, and
they are not the identity of the imported bytes.

**The build graph** (`build.zig`, `build.zig.zon`): the 21-unit `mi_sources`
closure read out of upstream's `CMakeLists.txt:107-126` rather than guessed,
two deliveries (`-Dlinkage=static`/`dynamic` with upstream's own soname
scheme), `-Druntime` for the load-at-runtime route, `-Dsystem` for binding to
an installed `libmimalloc`, the four installed headers, a generated
`mimalloc.pc`, and the three licence records. Five steps exist: the default
install step, `test`, `smoke`, `consumer` and `check`.

**The typed Zig surface** (`zig/root.zig`, `zig/translate.h`): the complete
documented facade over the same library, with the translated header reached as
`pub const c` on the same module.

**The runtime-loading route** (`runtime/loader.zig`, `runtime/library.zig`,
`runtime/graph.zig`, `runtime/generate.zig`, `runtime/sync.c`, `runtime/sync.h`):
one process-lifetime table, explicit `path` or `system` provider selection, no
fallback, no automatic retry, atomic publication, an ordinary
pre-initialization panic in every optimization mode. Linked calls stay direct.

**The package's own tests, example, consumer and provenance records**, and the
full documentation set: `README.md`, `README.zig.md`, `UPSTREAM.md`,
`UPSTREAM.sha256`, `NOTICE.md`, `FORK-LICENSE.md`, `FORK-NOTES.md` and this
file.

### Recorded facts, each read out of the source rather than assumed

* **`src/free.c` and `src/alloc-override.c` are not separate translation
  units.** `src/alloc.c:19-22` `#include`s both as text, which is why
  upstream's own `mi_sources` list has no entry for either.
  `src/alloc-override.c:13` guards its whole body behind
  `#if defined(MI_MALLOC_OVERRIDE)`.
* **`src/static.c` is carried and not compiled.** It is the
  whole-amalgamation unit (`src/static.c:23` includes `alloc.c`) and upstream
  compiles it only as its separate `mimalloc-obj` target
  (`CMakeLists.txt:1092`).
* **`MI_MALLOC_OVERRIDE` is never defined**, so the delivered artifact exports
  `mi_malloc`/`mi_free` and **not** `malloc`, `free` or the C++ operators, and
  `isRedirected()` answers `false`. **This package does not replace any
  allocator already loaded in this workspace, and nothing in it is routed
  through mimalloc.**
* **On Windows, `MI_WIN_NOREDIRECT=1` is defined** — upstream's own switch for
  not using the CRT redirection module (`CMakeLists.txt:323-327`, default off
  at `CMakeLists.txt:54`), because the redirect path needs a separate
  `mimalloc-redirect` DLL this package does not build (`CMakeLists.txt:1060`).
  A choice among two upstream configurations, not a patch.
* **`-std=gnu11` is named explicitly** because `include/mimalloc/atomic.h:53-55`
  needs C11 `<stdatomic.h>`, and `gnu11` rather than `c11` because upstream's
  own sources take GNU extensions under `#if defined(__GNUC__)`.
* **`refused_check_targets` is empty** and `checkMatrixPartition` enforces the
  partition, so all six baseline targets are in `check` and none is silently
  dropped.

### The two declarations upstream never defines

`mi_collect_reduce` (`include/mimalloc.h:435`) and `mi_stats_merge`
(`include/mimalloc.h:438`) are declared in upstream's public header, in its own
`Deprecated` block, and are defined in **no** translation unit of the v3.5.3
source closure. `SOURCE-CONFIRMED`: each appears in exactly one place in the
52-file import — its own declaration in `include/mimalloc.h` — and nowhere else.

They are upstream's defect, and this addition handles it in three places rather
than by touching the vendored header:

1. **The header is not patched.** Editing it would move the digest of every one
   of the 52 files' integrity record to fix a defect upstream owns, and would
   break the "byte-identical to the tarball" claim that the whole provenance
   story rests on.
2. **The runtime loader excludes them** from the set it requires a provider to
   export — `provider_excluded` in `runtime/graph.zig` is exactly
   `"mi_collect_reduce,mi_stats_merge"` — so their absence cannot fail every
   *other* symbol's load, on any platform, against a perfectly good provider.
3. **The Zig facade calls neither**, so a linked build never asks the linker
   for a symbol that does not exist. A dependent that reaches one through
   `pub const c` gets a link error, which is the honest answer.

### What this entry does not prove

Nothing requiring a compiler or a runner. No build has been attempted, no test
has been executed, no cross-target check has been run, no consumer package has
been built, and the provenance script has never been executed — it is delivered
as source.

Every gate named in [`README.md`](README.md)'s support matrix is
`PENDING-VERIFICATION`, and there is no test count to report and none may be
invented. A successful foreign compile is `build_only` and is never a pass.

This entry does not claim that mimalloc is this process's allocator, that any
provider here is redirected, or that making it so would be free. That would be a
separate migration of a link line, a preload or a call site, with its own
measurement, and it is not part of this addition.

### Licensing

mimalloc's tree is MIT at the root (`LICENSE`) but is **not** a single label
across 52 files, and `NOTICE.md` records the differences per file: the copyright
year range and holders differ from file to file and even the punctuation differs;
`src/prim/emscripten/prim.c` names a third holder, Alon Zakai;
`src/prim/windows/etw.h` carries only "Copyright (c) Microsoft Corporation. All
Rights Reserved." with **no grant in the file**, being a Message Compiler
generated include; and six files carry no per-file notice at all, covered by the
root `LICENSE`.

This fork's own files are released under the MIT terms recorded in
`FORK-LICENSE.md`, on the owner's per-project authorization. Upstream's terms do
not themselves grant rights to fork-authored additions, and no upstream author
is credited with any fork code. The owner's name is not given and no individual
copyright holder is invented: the grant is collective.
## 2. 2026-10-05 — the tree is ported to Zig 0.16.0 and its gates are green

The tree in entry 1 had never been compiled. This entry records what the
compiler forced, what was wrong in the Zig-side sources, and what the vendored C
does not do. Every gate below was **observed** with the pinned Zig 0.16.0
(`zig build`, `zig build test`, `zig build smoke`, `zig build check`, and
`zig build consumer` beyond the required set); the file header's rule that only
the driver may move an entry to `VERIFIED` is unchanged, so this entry is still
`PENDING-VERIFICATION` as a statement about the driver, and the observations
below are receipts for the driver to weigh.

### What the compiler forced

- **`std.zig.system.GetExternalExecutorOptions` has no `.target`.** `hostCanExecute`
  (`build.zig:993-1020`) passed the whole struct in one argument and had no target
  field at all; the 0.16 signature is
  `getExternalExecutor(io, host, candidate, options)`. It now passes
  `b.graph.io` and the two `*const std.Target` pointers, and maps the returned
  `Executor` in a `switch` whose `.qemu` arm carries `Run`'s own second gate.
  Every other SDK in this workspace already does exactly this.
- **`sharedConsumerMacros` is a `Platform` static, not a member.**
  `build.zig:424` called `platform.sharedConsumerMacros(delivered)`; the function
  takes no `self`, so the name resolved against the file-scope `Platform` struct
  and the compiler reported `no field or member function named
  'sharedConsumerMacros' in 'build.Platform'`. Now
  `Platform.sharedConsumerMacros(delivered)`.
- **`std.mem.join` returns an error union.** `build.zig:622` fed it straight to
  `b.fmt("EXPORTS\n{s}\n", ...)`, which 0.16 rejects with `invalid format string
  's' for type 'error{OutOfMemory}![]u8'`. It is now `catch @panic("OOM")`, the
  idiom the sibling SDKs use.
- **A bare call inside `Block` named two declarations.** `Block`'s methods
  `zalloc`, `calloc`, `usableSize` and `realloc` sit in the same scope as the
  file-scope functions of the same names, and 0.16 reports `ambiguous reference`
  rather than preferring the inner one. Four file-scope aliases
  (`zig/root.zig:821-832`) give each call exactly one target.
- **`x orelse error.Foo` propagates the peer type to the operand.** Where the
  result location was a struct-literal field of optional type, 0.16 coerces the
  error literal to the *optional* and rejects it: `expected type
  '?*translate.struct_mi_heap_s', found 'error{OutOfMemory}'`. The two `Heap`
  constructors now use `orelse return error.OutOfMemory`. The other sixty-odd
  `orelse error.OutOfMemory` sites sit directly in a `return`, where the peer
  type is the error union and 0.16 accepts them unchanged.
- **`@ptrCast` from `*anyopaque` needs `@alignCast` first.** Three sites
  (`Block.bytesAs`, `allocSlice`, `allocSliceZeroed`) raised `@ptrCast increases
  pointer alignment`; they now use the `@ptrCast(@alignCast(raw))` form
  `allocSliceAligned` already used.
- **Callback types must match the translation exactly.** `OutputFn`'s `msg` was
  `[*:0]const u8` where translate-c declares `[*c]const u8`; `BlockVisitFn`'s
  first two parameters were `?*c.mi_heap_t` and `?*const c.mi_heap_area_t` where
  the declaration is `?*const mi_heap_t` and a non-optional
  `[*c]const mi_heap_area_t`; `CommitFn`'s `is_zero` was `?*bool` where it is
  `[*c]bool`. All are the translation's spelling now.
- **`consumer/build.zig.zon` carried a hand-derived fingerprint.** The compiler
  rejected `0x1cb20f1826ab4958` and printed `0x1b13260083a8ce07`, which is now
  the manifest's value. The comment claimed a `sha256` derivation the toolchain
  does not use; it now records the message the toolchain printed and says the
  derivation lives in the compiler.
- **`consumer/src/main.zig`: two argument-count defects.** `checkOverflow`
  discarded a non-void `*anyopaque` (`value of type '*anyopaque' ignored`), and
  three `fail(...)` call sites passed a `fmt` with two specifiers to a helper
  that prints `fmt` twice and so needs one (`too few arguments`). The helper's doc
  now states the contract, and its `what` argument is called out as part of the
  format string.

### What was wrong in the Zig-side sources

- **`mimalloc.expand` did not exist** and `tests.zig` called it. `mi_expand`
  (`include/mimalloc.h:113`) is now wrapped at `zig/root.zig:480-493` and listed
  in `README.zig.md`. It returns `?*anyopaque`, not `Error!*anyopaque`: a null
  answer means "this block did not grow", which is upstream's ordinary answer
  (`src/alloc.c:449-462`) and not an error of the caller's.
- **The output callbacks refused the null upstream accepts.** `registerOutput`,
  `optionsPrintTo`, `processInfoPrintTo`, `statsPrintTo` and `threadStatsPrintTo`
  declared `out: OutputFn`; upstream declares `mi_output_fun* out` and handles
  null in its own body (`src/options.c:438`, `:441-442`). All five now take
  `?OutputFn`, which is what `optionsPrintTo(null, null)` — the call the tests
  make — requires.
- **Four test oracles asserted things upstream does not do.** Each was measured
  against this tree's own archive before being replaced, and each replacement
  asserts *more* than the criterion it replaced:
  1. `goodSize(goodSize(n)) == goodSize(n)` — false for **every** one of 1..4096.
     `mi_good_size` looks the bin up for `size + MI_PADDING_SIZE`
     (`src/page-queue.c:116`), so its answer describes a larger request than the
     one asked about. Replaced by four properties of a rounding (never down,
     never stepping backwards, never shrinking on a second pass) plus the
     promise the test's name made and nothing checked: `usableSize(malloc(goodSize(n))) >=
     goodSize(n)`.
  2. `calloc(0, maxInt)` must fail — `0 * anything` is 0, which is representable,
     and C99 7.22.3.2 asks no more. Upstream allocates it. Replaced with a third
     genuinely overflowing product and an assertion that the zero-size request
     **succeeds** and frees, which the module comment had only promised.
  3. `arenaMinSize() >= arenaMinAlignment()` — these are two independent upstream
     constants and the inequality always fails the other way (32 MiB against
     256 MiB here, `include/mimalloc/types.h:781` against `:268-270`). Replaced by
     the property upstream does state: each is a product of powers of two.
  4. `arenaMaxObjectSize() >= optionGetSize(.arena_max_object_size)` — upstream
     **clamps** the option down to `mi_arena_max_fixed_object_size`
     (`src/arena.c:116-124`). Replaced by an exact check of the KiB-to-bytes
     conversion the test is named for, and by the clamp's monotonicity.
- **One test asserted the transition's opposite.** The thread-local-heap test
  compared the default *in force after the install* with the value the setter
  displaced; after installing a theap, the default in force **is** that theap.
  It now walks the whole round trip in the order the transition happens.
- **`peak_rss >= current_rss` is not upstream's promise.** `mi_process_info` seeds
  both from the commit counters (`src/stats.c:586-587`) and
  `_mi_prim_process_info` then overwrites only the peak with the kernel's
  `rusage.ru_maxrss * 1024` (`src/prim/unix/prim.c:810-814`) while `current_rss`
  keeps mimalloc's committed bytes. Replaced with the commit counters' own
  monotonicity and per-figure positivity.
- **A test needed a second thread on a target that has none.** `zig build check`
  compiles `tests.zig` for `wasm32-wasi`, where `std.Thread.spawn` is a
  `@compileError` (`lib/std/Thread.zig:346`). The cross-thread free test now
  returns `error.SkipZigTest` when `builtin.single_threaded`, which is the
  comptime condition that removes the untaken branch from analysis entirely. It
  is a skip, not a pass, and it is the workspace idiom
  (`geographiclib-c/tests.zig:1254`).

### Two upstream defects, reported and not worked around

Neither vendored file was edited. Both are `MI_DEBUG`-mode or caller-shape
issues in mimalloc v3.5.3, measured against this tree's archive.

1. **`mi_malloc_aligned_at` aborts on an odd offset in any `MI_DEBUG` build.**
   With a non-zero offset it returns `base + adjust`
   (`src/alloc-aligned.c:81-86`); an odd offset makes `adjust` odd and the
   pointer odd, and `mi_ptr_page_is_valid_ex` rejects any pointer not aligned to
   `MI_SIZE_SIZE` (`src/free.c:195-198`). mimalloc then trips its own assertion
   that the aligned pointer has a usable size (`src/alloc-aligned.c:117`) and
   aborts **inside the allocation**, before the caller sees a pointer. Measured:
   every odd offset aborts that way at every alignment; every word-aligned offset
   succeeds up to 64 KiB. The test walks word-aligned offsets and says why.
2. **`mi_malloc_aligned_at` under-allocates by up to `offset` bytes.** It
   over-allocates `max(size, MI_MAX_ALIGN_SIZE) + alignment - 1`
   (`src/alloc-aligned.c:73`) and then moves the pointer forward by up to
   `alignment - 1`, so a field of `size` bytes placed `offset` bytes in can run
   past the end. Measured: `usableSize` is 1 to `offset` bytes short of
   `offset + size` at every non-zero offset and every alignment from 2 to
   64 KiB. Upstream's own guarantee is only `usableSize >= size`
   (`src/alloc-aligned.c:117`), and that is what the test asserts.

### What this entry does not prove

No cross-target matrix was run **for this entry**; entry 3 below runs it and
records 19 failures in 53 cells. No Nix build, no CI.
`-Dlinkage=dynamic` and
`-Dsystem=true` remain unbuildable: `deliveredLinkage` (`build.zig:355`) panics
by design because the `check` step's target list includes `wasm32-wasi`, which
has no dynamic linker, and the panic message says so. That is this package's own
stated policy and not a 0.16 defect; changing the check-target list is a design
decision this port did not make. `-Druntime=true` was observed to build.


## 3. 2026-10-05 — the 53-platform cross-test matrix is run and recorded

`OBSERVED`. Red in 19 of 53 cells. Every other row of §12 in FORK-NOTES.md
stays `PENDING-VERIFICATION`.

### The run

From the package root, with the host scratch environment sourced and this
tree's own `cross-test.profile.sh` used unmodified:

```sh
"$HOME/.local/bin/cross-test" --jobs 8 --build-jobs 8 \
  --output "$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/mimalloc"
```

Compiler `0.16.0`, step `test`, optimize `Debug`, `target_count=53`,
`target_jobs=8`, `jobs_per_build=8`, `bookkeeping_failure=false`,
`run_id 20261005-191559-58950-7377`. **Harness exit code 1.**
`cross-test: status=fail pass=10 fail=19 build_only=24 partial=0`. Summary at
`$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/mimalloc/cross-test-summary.json`.

**10 pass** — `x86_64-linux`, `aarch64-linux`, `aarch64_be-linux`,
`loongarch64-linux`, `mips64-linux`, `mips64el-linux`, `powerpc64-linux`,
`powerpc64le-linux`, `riscv64-linux`, `s390x-linux`. 34 of 34 tests each.

**24 build_only** — compiled clean, never executed, no runner on this host.
Named individually in README.md. **Not passes.**

**19 fail**, in three causes:

* **9 `*-netbsd` cells, `zig translate-c` exit 1 — a pinned-toolchain
  boundary.** The failing text is inside the toolchain's own
  `lib/libc/include/generic-netbsd/sys/cdefs.h:413`, reached from
  `assert.h:105` `__END_DECLS`. Neutralising `_Pragma` makes the same
  one-header translation succeed for `aarch64-netbsd`.
  `include/mimalloc.h:100` needs `<assert.h>`, so no configuration change
  avoids it and no vendored file may be edited to dodge it.
* **9 32-bit cells, one failing test each (33 of 34 passing) — a defect in
  this fork's test, not a boundary.** `tests.zig:217` filters alignments on
  the literal `65_536`, but upstream's `MI_PAGE_MAX_OVERALLOC_ALIGN` is 65536
  on 64-bit and 32768 on 32-bit (`types.h:510`, `:235`, `:217`;
  `bits.h:57-62`), and above that bound upstream refuses any non-zero offset
  (`src/alloc-aligned.c:66-70`). Every 64-bit cell passes; every 32-bit cell
  fails. **No fix has been made.** The test was not weakened, no skip was
  added and no failure was relabelled.
* **`hexagon-linux`, 9 pass / 25 crash, nondeterministic — the executor.**
  QEMU's own assertion `target/hexagon/translate.h:100:ctx_log_pred_read_new`
  fails 10/10 on the optimized build; all six QEMU CPU models fail
  intermittently on the debug build; the same program at `-O2 -DNDEBUG`
  passes 10/10 and plain `malloc`/`free` passes. The cell stays a runtime
  failure on the record and is never counted as evidence about mimalloc on
  Hexagon.

### What this entry does not prove

It proves nothing about rows 1-10 or 12 of FORK-NOTES.md §12, which stay
`PENDING-VERIFICATION`. It proves nothing about `-Dlinkage=dynamic`,
`-Dsystem=true` or `-Druntime=true`. The 24 `build_only` cells prove
compilation only and say nothing about behaviour. The nine QEMU passes are real
execution but are not the host ABI.