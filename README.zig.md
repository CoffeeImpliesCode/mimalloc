# The Zig interface

How the mimalloc v3.5.3 SDK is consumed from Zig: the typed surface published
by `zig/root.zig`, the raw translated C route, the runtime-loading route, the
ownership rules and the ABI a loaded provider has to satisfy.

`zig/root.zig` is the authority on this page. Where the two differ, the file is
right and this document is out of date.

For provenance, licensing and the build matrix see [`README.md`](README.md);
for the source-level evidence behind the ABI statements see
[`FORK-NOTES.md`](FORK-NOTES.md).

**Status: nothing here has been run.** No gate has been observed for this
package. What follows describes `zig/root.zig` as it stands; it is not a
receipt, and there is no test count to quote.

## The routes

```zig
const mimalloc = @import("mimalloc");   // dep.module("mimalloc")
const c = mimalloc.c;                   // pub const c = @import("c")
```

| Route | How you get it | What you get |
|---|---|---|
| Linked (default) | `zig build`, then `dep.module("mimalloc")` | the typed facade plus the linked `libmimalloc`; every call is a direct call |
| Runtime-loaded | `zig build -Druntime=true` | the same types and the same public surface, resolved through the platform loader by an explicit `load(source)`; the facade module links no archive |
| Installed C | `zig build install`, then `-I<prefix>/include -lmimalloc` | upstream's four installed headers and the library, for a C consumer |
| System | `zig build -Dsystem=true` (or `-fsys=mimalloc`) | an installed `libmimalloc` and its installed headers instead of this source; nothing from this tree is built or installed |

The first three are this package's own routes. System mode is a different
thing: it binds to whatever `libmimalloc` is already on the machine and this
graph builds no artifact for it.

`c` is re-exported **on the `mimalloc` module**, not published as a module of
its own: registering it separately would hand a dependent the declarations
without the library that satisfies them.

### `pub const c` is the escape hatch

**Say it plainly: `pub const c` is the escape hatch for everything this facade
does not name.** It is the translation of `include/mimalloc.h` — upstream's ABI
exactly as published, on the same library, through the same calls. Importing
the facade is all a dependent needs to reach it.

It carries, among the rest, the entry points the facade does not wrap:

* the POSIX- and Windows-shaped `mi_memalign`, `mi_valloc`, `mi_pvalloc`,
  `mi_aligned_alloc`, `mi_reallocarray`, `mi_reallocarr`, `mi_dupenv_s`,
  `mi_wdupenv_s`, `mi_wcsdup`, `mi_mbsdup` and `mi_cfree`
  (`include/mimalloc.h:534-552`);
* the `mi_new*` family (`:561-574`);
* the small-word-size entry points (`:586-589`);
* the block-size-reporting `mi_u*` family (`:222-231`).

In a runtime-loaded build `c` is a **generated dispatch** rather than the
translation step's own output. It publishes the same namespace: every type and
constant is re-exported from the translation rather than restated, so
`c.mi_heap_t` is the same nominal type either way and nothing needs a cast.

Two names in it do not exist in the v3.5.3 source: `mi_collect_reduce`
(`include/mimalloc.h:435`) and `mi_stats_merge` (`:438`) are declared and never
defined. A dependent that calls either fails to link in a linked build and
stops the program by name in a runtime-loaded one. See
[`FORK-NOTES.md`](FORK-NOTES.md) §6.

## The allocator crossing, stated once

**Every pointer this module returns is owned by mimalloc, not by Zig.** It
comes out of `mi_malloc`, which carves a block out of one of mimalloc's own
arenas and returns an interior address inside it (`src/alloc.c:338` ->
`src/alloc.c:289-295` -> `src/page.c`). It must be returned to mimalloc with
`free`, `Heap.free` or `Block.deinit`, and to nothing else.

Three consequences, each stated again where it applies:

* **`std.mem.Allocator` is not what these pointers belong to.** Handing one to
  a Zig allocator's `free` — including `std.testing.allocator` — is a
  *mismatched* free, not a leak. `Block` and `Heap` exist so that a correct
  caller never has to remember which world a pointer came from.
* **No leak oracle is available, and none is claimed.** A Zig test allocator
  detects a leak of memory *it* handed out, because it holds a record of its own
  outstanding blocks. It cannot detect a leak of memory mimalloc owns: the block
  was never its, so there is nothing for it to miss. **Nothing in this package
  asserts that it leaks nothing, because no test in this package can observe
  that claim.** A test that wanted to would be asserting something its own
  framework is not in a position to detect.
* **Addresses say nothing about provenance.** mimalloc returns an interior
  pointer into its arena rather than an OS mapping, so a block's address is not
  evidence of anything. `anyHeapContains` is the only question this package asks
  about whether a pointer is mimalloc's, and it asks upstream's own predicate
  (`src/heap.c:276-279`), not a range test.

`mi_realpath` is the one corner worth naming here: upstream documents the
caller's `resolved_name` buffer as one it may `mi_free` itself
(`src/alloc.c:662-746`), which is why `realpath` here takes a buffer rather
than returning an owning slice.

## Two configurations: linked and runtime-loaded

`runtime_loaded` is a **comptime constant**, so a consumer can write two code
paths and have only the one it chose analyzed.

*Linked* is the default: the C library is linked, `c` is the translation of
`include/mimalloc.h`, and every call is direct with no table and no check.

*Runtime-loaded* is opt-in (`-Druntime`). The library is not linked; `c` is a
dispatch generated from the same translation step's output, and every
declaration `mimalloc.h` makes is resolved through the platform loader after

```zig
try mimalloc.load(.{ .path = "/usr/lib/libmimalloc.so.3" });
```

Before that, a call into the module stops the program with a message naming
the function, in every optimization mode. That is a programming error rather
than a recoverable condition: the table does not exist yet and there is no
partial state to fall back on.

The provider is reached, never guessed. `.path` names a file, `.system` names a
library for the platform loader, and **neither falls back to the other**. There
is no unload, no reset, and no automatic retry; the handle and the loader's own
copy of the request live to the end of the process. `loadedSource()` answers
the request that succeeded, or null.

`load` can decline in eight ways, all named in `LoadError`: `EmptySource`,
`SourceTooLong`, `InvalidSource`, `UnsupportedTarget`, `OpenFailed`,
`MissingSymbol`, `ValidationFailed`, `ProviderMismatch`, `ReentrantLoad`. A
failed attempt publishes nothing and can be retried explicitly by calling
`load` again; a second call with the same request succeeds and changes nothing;
a different request after a success is `ProviderMismatch` and the library
already in use stays in use.

In a **linked** build there is no provider and nothing to load, so `load`
stops the program with a message saying exactly that — rather than quietly
succeeding and leaving a caller to think it had selected a provider.

## Errors

`Error` has exactly two members, and each is one condition this module
actually checked:

* `OutOfMemory` is upstream's NULL and nothing else. For `calloc`, `mallocn`,
  `reallocn` and `recalloc` it covers two upstream causes this code cannot tell
  apart: `mi_count_size_overflow` rejected the product
  (`src/alloc.c:371-375`), or the allocator could not satisfy a request that
  did not overflow. The taxonomy stops there rather than inventing a distinction
  upstream does not report.
* `InvalidAlignment` is checked **here, before the call**. Upstream's rule is
  non-zero and a power of two (`include/mimalloc/internal.h:537-539`) and it is
  reached only through `mi_assert_internal`, which `NDEBUG` compiles away. A
  release build would otherwise hand a nonsense alignment to the page allocator.

When these fail, mimalloc has changed nothing the caller can see: a NULL
return means no block was created, and a rejected alignment never reached the
allocator. In particular **`realloc` failing leaves the block valid and still
owned by the caller** (`src/alloc.c:463-468`: "returning NULL always indicates
an error, and `p` will not have been freed in that case") — which is why
`reallocFree` is a different function rather than a flag on `realloc`.

## The standard malloc interface

`mi_malloc` and kin, `include/mimalloc.h:110-118`:

| Facade | Upstream | Note |
|---|---|---|
| `malloc(size)` | `mi_malloc` | `size == 0` **succeeds** and returns a valid unique pointer, not null; it still has to be freed |
| `zalloc(size)` | `mi_zalloc` | the zeroing is a guarantee, not a side effect of fresh pages |
| `calloc(count, size)` | `mi_calloc` | the product is overflow-checked upstream |
| `mallocn(count, size)` | `mi_mallocn` | same product, not zeroed |
| `mallocSmall`, `zallocSmall` | `mi_malloc_small`, `mi_zalloc_small` | the small-block fast path |
| `realloc(block, new_size)` | `mi_realloc` | on failure `block` survives and is still the caller's |
| `reallocn`, `reallocFree`, `rezalloc`, `recalloc` | `mi_reallocn`, `mi_reallocf`, `mi_rezalloc`, `mi_recalloc` | `reallocFree` is the "also free the old block" spelling; two functions rather than one with a flag |
| `expand(block, new_size)` | `mi_expand` | grow in place when the page has room. **A null answer is not an error**, so this is the one entry point here that returns `?*anyopaque` rather than `Error!*anyopaque`: null means "this block did not grow" (`src/alloc.c:449-462`), which upstream also compiles to `return NULL` outright when `MI_PADDING` is on (`src/alloc.c:449-452`). `realloc` is the entry point that resizes |
| `free`, `freeSize`, `freeSmall`, `freeSmallNonnull` | `mi_free`, `mi_free_size`, `mi_free_small`, `mi_free_small_nonnull` | `freeSize`'s size is a hint, not a contract |
| `usableSize(block)` | `mi_usable_size` | a **rounding answer**, not the request: it reports the page's block size (`src/free.c:587-590`) |
| `goodSize(size)` | `mi_good_size` | a **size-class answer**: rounds up to the bin for a small request, to the OS page size for a large one, and returns the request unchanged above `MI_MAX_ALLOC_SIZE` (`src/page-queue.c:113-125`) |
| `strdup`, `strndup` | `mi_strdup`, `mi_strndup` | the result is a NUL-terminated allocation you own and free with `free` |
| `realpath`, `realpathInto` | `mi_realpath` | see the allocator crossing above; `realpathInto` is the form to use when a path must not allocate |

## The aligned family — `(size, alignment)`

**Every `*_aligned` entry point here takes `(size, alignment)`, not
`(alignment, size)`.** That is upstream's own argument order
(`include/mimalloc.h:149-151`), which upstream chose so alignment follows
size, and it is the opposite of `posix_memalign` and of `aligned_alloc`.

```zig
const p = try mimalloc.mallocAligned(4096, 64);   // 4096 bytes at 64-byte alignment
```

Three things about this section:

* **`alignedAlloc(alignment, size)` is the POSIX-ordered spelling of the same
  request** and is the one to reach for at a `posix_memalign` call site.
  `memalign(alignment, size)` is the older spelling upstream keeps. `valloc(size)`
  and `pvalloc(size)` take no alignment at all — the platform's page alignment
  and, for `pvalloc`, the size rounded up to a multiple of it.
* **Every alignment is checked before the call** and answers
  `error.InvalidAlignment`, which is decided in this module and never reaches
  mimalloc. The check is an ordinary comparison, not a debug assertion.
* **`freeAligned(block, alignment)` and `freeSizeAligned(block, size, alignment)`
  exist for completeness rather than out of necessity**: an aligned block is an
  ordinary block, and `free` returns it. There is deliberately no aligned
  free-on-failure function to name, because no aligned call in this module can
  leave a block behind.

The full set: `mallocAligned`, `zallocAligned`, `callocAligned`,
`mallocAlignedAt`, `zallocAlignedAt`, `callocAlignedAt`, `reallocAligned`,
`reallocAlignedAt`, `rezallocAligned`, `rezallocAlignedAt`, `recallocAligned`,
`recallocAlignedAt`, `freeAligned`, `freeSizeAligned`, `alignedAlloc`,
`memalign`, `valloc`, `pvalloc`. The `…At` variants take an additional
`offset` and place the block so that `offset` sits on an `alignment` boundary.

## Typed and slice-shaped views, and `Block`

These allocate nothing of their own: each is one call to an entry point above
plus a cast. **The slice is a *view* of a mimalloc block.** Its length is the
length that was asked for, not the usable size, and `free` returns the block.

| Facade | Result |
|---|---|
| `allocSlice(T, n)` | `[]T`, `n` elements, not zeroed; the product is overflow-checked here |
| `allocSliceZeroed(T, n)` | `[]T`, zeroed; same product check |
| `allocSliceAligned(T, alignment, n)` | `[]align(alignment) T`, not zeroed |

`alignment` in `allocSliceAligned` is **comptime** on purpose: the returned
slice's alignment is part of its type, `[]align(alignment) T` states it to the
compiler, and `@alignCast` then checks at run time in a safe build that
mimalloc really honoured it. That check is the point — `mi_malloc_aligned`
returns an interior address into its own arena, and the alignment is the one
thing about that address worth proving.

mimalloc aligns every block to at least `MI_MAX_ALIGN_SIZE`
(`include/mimalloc/types.h:38-40`, 16 bytes where a word is 8), so any `T` whose
alignment is at most that needs nothing extra. A stricter `T` needs
`allocSliceAligned`, which asks rather than hopes.

**`Block` is a marker, not a manager.** It adds no bookkeeping; its only
advantage over carrying a `*anyopaque` is that `deinit` exists:

```zig
var b = try mimalloc.Block.alloc(1024);
defer b.deinit();
const bytes: []u8 = b.bytes(1024);      // the length you asked for
const elems: []u32 = b.bytesAs(u32, 256);
const n = b.usableSize();               // what the page layout says
```

`Block.from(raw)` adopts a pointer that already exists; `Block.realloc` returns
the block that now holds it and leaves the original valid on failure.
**`deinit` is not idempotent and is not guarded**: a second `deinit` on the
same value is a double free, because `Block` is a copyable `*anyopaque` and
copying one is exactly the mistake this type exists to make visible.

## Heaps

`include/mimalloc.h:235-275`. A heap is first-class: it can be allocated from
any thread and its blocks can be freed from any thread
(`include/mimalloc.h:235-237`), and it keeps its blocks in pages of its own
while sharing its arena's and its freed pages.

`Heap` is the one **owning** type in this module. `init()` and `initInArena(id)`
create one; `isOpen()` reports whether it is still open, and any method on a
closed heap stops the program rather than falling through to a null pointer and
allocating from the main heap instead.

### `deinit` versus `destroy` — they do different things to live blocks

Closing a heap is **two** operations and this module does not merge them:

| | Upstream | Live blocks afterwards |
|---|---|---|
| `Heap.deinit()` | `mi_heap_delete` (`src/heap.c:236-244`) | **moved to the main heap.** They are *not* freed; the caller still owns them and must still `free` them, which now succeeds through the main heap. Upstream's own comment at `include/mimalloc.h:243` is "move live blocks to the main heap" |
| `Heap.destroy()` | `mi_heap_destroy` (`src/heap.c:261-268`) | **every live block in it is freed**, without the caller freeing any of them. No block from that heap may be freed afterwards |

So a heap that *owns* its blocks should be closed with `destroy`. A caller that
reached for `deinit` and got `destroy`'s behaviour would lose live data, and one
that reached for `destroy` and got `deinit`'s would leak the heap's contents —
which is why they are separate names and not a parameter.

Both refuse the main heap, with a warning rather than a failure
(`src/heap.c:239-242`, `:263-266`), so neither is a way to shut the process's
allocator down.

Both set `raw` to null first, so a second call on the same value is a no-op
rather than a second delete.

The rest of `Heap`: `malloc`, `zalloc`, `calloc`, `realloc` and the aligned
family; `contains(block)`; `collect(force)` (which releases free pages of the
heap's thread-local heap and explicitly does *not* collect the heap —
`include/mimalloc.h:246`); `setNumaAffinity`; `theap()`;
`Heap.of(block)`, which answers `?HeapRef` and is null for any pointer not in
any heap, including every pointer some other allocator returned; and
`Heap.main()`.

## `HeapRef`, `MainHeapRef` and `TheapRef` — borrowed, deliberately

Three types that have **no `deinit` and no `destroy`**, on purpose: the heap
behind each of them belongs to somebody else.

* **`HeapRef`** is what `Heap.of` answers with. A borrowed heap reference.
  `isOpen`, `contains`, `malloc`, `zalloc`. Closing a heap behind its back
  invalidates it and nothing here can tell you.
* **`MainHeapRef`** is what `Heap.main()` answers with. `contains`, `malloc`,
  `zalloc`. **There is deliberately no way to close it** — upstream's own
  `mi_heap_delete` and `mi_heap_destroy` refuse it — and a type with no closing
  method is how that refusal becomes visible at the call site rather than in a
  runtime warning.
* **`TheapRef`** is a thread's own fast path onto a heap
  (`include/mimalloc.h:371-397`): it can only allocate from the thread that
  created it, and it is provider-owned. `TheapRef` holds its `Heap` as a
  `*const Heap` rather than a raw pointer, so closing the heap is the only way
  to invalidate it and that is visible where it happens. It reaches
  `mi_theap_malloc`, `mi_theap_zalloc`, `mi_theap_calloc`, the small and
  aligned variants, `mi_theap_realloc`, `mi_theap_rezalloc`, `collect`, and the
  experimental `guardedSetSampleRate` / `guardedSetSizeBound`
  (`include/mimalloc.h:402-409`: a guard page after a sampled fraction of a
  theap's objects, so a buffer overrun faults instead of corrupting the next
  object).

`theapSetDefault(theap)` makes a theap the one plain `mi_malloc` and friends
allocate from on this thread, returning the previous default or null;
`theapDefault()` reads the thread's current one.

## Arenas

`include/mimalloc.h:324-352`. An arena is a large region of OS memory, reserved
or handed in by the user, out of which pages — and therefore blocks — are
carved. **`ArenaId` is upstream's own `mi_arena_id_t`** (`void*`), not
restated, so the handle this module passes is the one the header declares. It is
created by one of the `*_ex` reservation calls and is meaningful only to the
process that created it.

* `arenaArea(id) ?ArenaArea` — the region the arena owns, as `mi_arena_area`
  reports it. `ArenaArea.start` is **provider-owned memory that must not be
  freed**: an arena is released by the provider, not by a caller.
* `arenaMinAlignment()`, `arenaMinSize()`, `arenaMaxObjectSize()` — policy
  answers from the provider, not constants restated here.
* `arenaContains(id, block)` — whether the block is in this arena's region.
* `reserveOsMemory`, `reserveOsMemoryEx`, `reserveHugeOsPagesAt`,
  `reserveHugeOsPagesAtEx`, `reserveHugeOsPagesInterleave`,
  `reserveHugeOsPages` — the reservation surface, including the POSIX large
  and huge page calls. These return a status, which is more than a NULL/NULL
  distinction; they are not folded into `Error`.
* `manageOsMemory`, `manageOsMemoryEx`, `manageMemory` — hand a region to the
  allocator or take it back. `manageMemory`'s `commit_fun` is experimental and
  `is_zero` is an out-parameter the callback must write; calling into an
  allocator from inside its own commit callback is exactly the kind of thing
  that allocates and deadlocks.
* `debugShowArenas()`, `arenasPrint()` — upstream's own printers.

## Sub-processes

`include/mimalloc.h:354-368`. A sub-process is a set of arenas that stay
separated with no reclamation between them; upstream's use case is several
interpreters in one process. **It is not an OS process and isolates nothing a
`fork` would.**

`Subproc` wraps upstream's own by-value `mi_subproc_id_t`, so it is one nominal
type on both routes: `main()`, `current()`, `create()`, `destroy()`,
`addCurrentThread()` (upstream's timing note is exact — "right after a thread is
created (and no allocation has taken place yet)"), and `visitHeaps(visitor,
arg)`, which answers `false` when the visitor asked to stop.

Every heap handed to `visitHeaps`' visitor is borrowed. **`Heap` is not one of
them**, because the visitor signature carries a raw pointer and closing a heap
from inside this walk would be freeing the thing being walked.

## Options

`include/mimalloc.h:444-519`. `Option` is a Zig enum whose tag type is
upstream's own `mi_option_e`, so it is one nominal type with the header rather
than a copy of it, and **no value is restated**: every tag below is the
translated enumerator.

Every option is process-wide, and most are read once, at first use — upstream's
own note is that changing an option after the first allocation has limited
effect. That is why the setters say nothing about ordering (upstream promises
none) and why `optionSetDefault` exists separately from `optionSet`.

| Facade | Upstream | Note |
|---|---|---|
| `optionIsEnabled`, `optionEnable`, `optionDisable`, `optionSetEnabled` | `mi_option_is_enabled`, `mi_option_enable`, `mi_option_disable`, `mi_option_set_enabled` | |
| `optionSetEnabledDefault`, `optionSetDefault` | `…_set_enabled_default`, `mi_option_set_default` | sets the value the built-in default starts from, not the current one |
| `optionGet`, `optionGetClamp`, `optionGetSize`, `optionSet` | `mi_option_get`, `mi_option_get_clamp`, `mi_option_get_size`, `mi_option_set` | `optionGetSize` returns `usize` because upstream encodes a size as 1024× the count, and re-deriving that multiplier in a caller is how it gets multiplied twice |
| `theapSetDefault`, `theapDefault` | `mi_theap_set_default`, `mi_theap_get_default` | |

Any option can also be set from the environment as `MIMALLOC_<OPTION>`, read by
upstream itself (`src/options.c`) before any of this is called.

Three names from upstream's enumerator list are **deliberately absent**: the
`_mi_option_last` end marker, which is not an option, and the five legacy
aliases at `include/mimalloc.h:501-505` (`large_os_pages`,
`eager_region_commit`, `reset_decommits`, `reset_delay`, `limit_os_alloc`),
which repeat the value of an option already present under its current name. A
Zig enum cannot carry two fields with one value, and the alias is reachable
through `c` if a caller really wants it.

## Lifecycle

| Facade | Upstream | Note |
|---|---|---|
| `processInit()` | `mi_process_init` | **process-wide and one-shot**: it installs a process-wide allocation strategy and is documented for runtime systems that allocate before `main`. It is not per-handle state, and this module does not call it for you |
| `processDone()` | `mi_process_done` | the ordinary way to get the exit-time collection |
| `threadInit()` | `mi_thread_init` | initialize the calling thread |
| `threadDone()` | `mi_thread_done` | let the thread's pages go |
| `threadSetInThreadpool()` | `mi_thread_set_in_threadpool` | the calling thread belongs to a pool and should not keep memory |
| `collect(force)` | `mi_collect` | **process-wide**: acts on every thread, not just the caller's |
| `anyHeapContains(block)` | `mi_any_heap_contains` | whether *any* heap owns the block — the honest ownership question |
| `checkOwned(block)` | `mi_check_owned` | forwards to `anyHeapContains`; `anyHeapContains` is what to write |
| `isInHeapRegion(block)` | `mi_is_in_heap_region` | a weaker predicate than ownership |
| `processInfo()` | `mi_process_info` | `ProcessInfo` — elapsed, user and system time, current and peak RSS, current and peak commit, page faults — filled in one call so the values describe the same instant. Every field is defaulted to 0 |
| `version_num` | `MI_MALLOC_VERSION` (`include/mimalloc.h:11`) | major + two digits of minor + two of patch: 30503 for v3.5.3. Read from the translation constant, not restated |
| `version()` | `mi_version` | what the **linked** library reports; in a runtime-loaded build it is the loaded provider's own answer |
| `isRedirected()` | `mi_is_redirected` | see below |

**`isRedirected()` answers `false` for this package, and that is the honest
answer.** It is upstream's own predicate (`include/mimalloc.h:329`,
`src/init.c:510-512`) and it reports whether *this* provider is the one serving
the process's standard `malloc`. The core is compiled with
`MI_MALLOC_OVERRIDE` undefined, so it exports `mi_malloc` and not `malloc`, and
nothing in this package preloads it or links it in place of the system
allocator. A `dlopen`ed `libmimalloc.so` also answers `false`, because the
process was not preloaded with it. The runtime loader deliberately does not
require it to be `true` — requiring it would refuse every provider the route
exists for.

## Callbacks

Six function-pointer types cross the boundary **inward**: the provider's own C
calls a function this program wrote, with the provider's calling convention and
the provider's thread. Upstream declares them with `mi_cdecl`, which is
`__cdecl` on Windows and nothing on every other target
(`include/mimalloc.h:68`), so `callconv(.c)` is the right spelling for all six
of this package's targets.

| Type | Upstream | Contract |
|---|---|---|
| `DeferredFreeFn` | `mi_deferred_free_fun` (`:189`) | `registerDeferredFree(fn, arg)` — call back when about to collect, so a runtime can free its own objects first. `heartbeat` counts the callbacks |
| `OutputFn` | `mi_output_fun` (`:192`) | `registerOutput(fn, arg)` — where mimalloc's messages go. `msg` is NUL-terminated and **owned by the provider**: copy it if it must outlive the call. `fn` is **nullable**, as it is upstream: a null `fn` restores the default output (`src/options.c:441-442`) |
| `ErrorFn` | `mi_error_fun` (`:195`) | `registerError(fn, arg)` — receives an errno. With none registered, upstream calls `mi_error_default` (`src/options.c:620-625`), which **aborts**; registering one replaces that abort with a return, which is the only reason to register it |
| `BlockVisitFn` | `mi_block_visit_fun` (`:318`) | one page or one block. Returning false stops the walk; every remaining page is skipped (`src/arena.c:2503`, `:2512`) |
| `HeapVisitFn` | `mi_heap_visit_fun` (`:367`) | one heap, **borrowed** |
| `CommitFn` | `mi_commit_fun_t` (`:412`) | commit or reset memory on the allocator's behalf. Experimental; see `manageMemory` |

`arg` is passed back unchanged. Nothing here is called while a lock this
package holds is held, because this package holds no lock while any of these
runs.

## Reporting

These print through the registered output, or to the default output when none is
registered. They allocate nothing this module can see and return nothing.

| Facade | Upstream |
|---|---|
| `optionsPrint()`, `optionsPrintTo(out, arg)` | `mi_options_print`, `mi_options_print_out` |
| `processInfoPrint()`, `processInfoPrintTo(out, arg)` | `mi_process_info_print`, `mi_process_info_print_out` |
| `statsPrintTo(out, arg)` | `mi_stats_print_out` (`include/mimalloc.h:441`) |
| `threadStatsPrintTo(out, arg)` | `mi_thread_stats_print_out` — **deprecated** at `include/mimalloc.h:430`; calling thread only |
| `statsReset()` | `mi_stats_reset` — reset this process's statistics |
| `debugShowArenas()`, `arenasPrint()` | `mi_debug_show_arenas`, `mi_arenas_print` |

Every `…PrintTo(out, arg)` takes a **nullable** `out`, as upstream's
`mi_output_fun* out` does: a null `out` means the default output
(`src/options.c:438`). Printing through the default output allocates nothing
this package can see, which is what makes `optionsPrintTo(null, null)` a
meaningful call rather than a compile error.

`statsPrintTo` is the entry point that reaches `mimalloc-stats.h`'s machinery
**without this package's translation having included that header**; the header
is deliberately not in `zig/translate.h`, for two reasons that both matter to a
build — `<string.h>` would drag the C library's whole string surface into the
translation and force a several-hundred-name noise list, and `mi_stats_t` is a
fixed-layout table of `size_t` counters that upstream extends between minor
versions, so a Zig mirror of it would be a second source of truth about a
layout the library owns. The structured `mi_stats_t` and its JSON form are
reachable through `c` for a caller that needs them.

## The ABI boundary a loaded provider must satisfy

Resolving the symbols and translating the header **is** the boundary. They are
not proof that a provider is compatible. What a provider must be:

1. **Family: mimalloc v3**, `MI_MALLOC_VERSION` 30503 (`include/mimalloc.h:11`).
   `MI_MALLOC_VERSION` encodes major + two digits of minor + two of patch, so
   v3.4.1 is 30401 and v2.5.2 is 20502. **The project publishes v1, v2 and v3
   side by side in one release** — the `v3.5.3` release carries
   `mimalloc-v1.15.2-source.tar.gz`, `mimalloc-v2.5.2-source.tar.gz` and
   `mimalloc-v3.5.3-source.tar.gz` — and all three export the same
   `mi_malloc`/`mi_free` spellings under the same header names. A provider built
   from the v2 or v1 line **passes a symbol check and is a different ABI**.
   `mi_version` is what separates them, and that is why the loader checks it
   and refuses a provider that disagrees.
2. **Layout.** The v3 layout is not the v2 layout. `mi_heap_s`, `mi_theap_s`
   and the arena types are opaque here, so a caller only passes their addresses
   around — but `mi_heap_area_t` (`include/mimalloc.h:308-316`) is a plain
   struct whose five `size_t` fields and two pointers a block-visiting callback
   reads through are part of the boundary. A v2 provider hands a v3 callback a
   different struct.
3. **Allocator.** The whole surface is about memory the *provider* owns:
   `mi_malloc` returns a block from mimalloc's own arena, `mi_free` puts it
   back, `mi_usable_size` reports what the page layout says rather than what
   was asked for, `mi_heap_new` creates a heap the provider tracks. **Nothing in
   this SDK can observe, bound or account for those allocations**, and no test
   framework can supply a leak oracle for them — see the allocator crossing
   above.
4. **Callbacks.** The six function-pointer types cross the boundary in both
   directions. A callback built against this translation is called by the
   provider's own C, with the provider's own calling convention.
5. **Process-wide effects.** `mi_process_init` installs a process-wide
   allocation strategy and `mi_collect` acts on every thread. Neither is
   per-handle state a table can isolate, and this loader does not contain them.

What is checked **before anything is published**: `mi_version` answers this
header's `MI_MALLOC_VERSION` (the family check above), and then one allocation
and one free through the same table — `mi_malloc` for 64 bytes,
`mi_usable_size` reporting at least that many, `mi_any_heap_contains` claiming
it, `mi_free` returning it. That exercises the provider's initialization path
(the first `mi_theap_malloc` is what reaches `_mi_heap_init`,
`src/alloc.c:338` -> `src/init.c:200`) and its free path. The block is freed on
every path out of that validation, **including the refusing ones**, so a failed
validation does not leave a block behind in a provider this process is about to
close.

What is deliberately **not** called at load time: `mi_process_init` and
`mi_process_done` (the first `mi_malloc` runs the provider's own initialization,
and a loader that tore a process down as a side effect of refusing a provider
would be a worse neighbour than one that simply closes its handle), and
`mi_is_redirected` (see above).

## What upstream does not promise, passed through

Restated from the module comment because each of these surprises people:

* **A zero-size request succeeds.** `mi_malloc(0)` returns a valid unique
  pointer, not null (`src/alloc.c:463-465` says so of `mi_realloc` to a zero
  size in the same words), and so does `mi_realloc(p, 0)`. Nothing here turns
  that into an error or into null, and that pointer still has to be freed.
* **`usableSize` is a rounding answer, not the request.**
* **`goodSize` is a size-class answer.**
* **Argument order differs from POSIX** on every `*_aligned` entry point.
* **A heap can be freed from any thread, and blocks in it too.** That is
  upstream's first-class-heap contract (`include/mimalloc.h:235-237`), not an
  accident of this binding.

## Where the evidence for all of this lives

* The module comment at the top of `zig/root.zig` states the allocator
  crossing, the two configurations, the override position, the error taxonomy
  and the upstream non-promises, each with its `src/` or `include/` line.
* `runtime/library.zig` states what a provider must be and the ABI boundary at
  length, including why the v1 and v2 sources in the same release defeat a
  symbol check.
* `runtime/graph.zig` states what is routed, what is required, what is excluded
  and why, and where the `libc_noise` list came from.
* `zig/translate.h` states which header is translated and why the other four
  installed headers are not — including the `mimalloc-stats.h` decision.
* [`FORK-NOTES.md`](FORK-NOTES.md) has the working record and the open
  questions.