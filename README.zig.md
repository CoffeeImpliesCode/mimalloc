# Zig facade API

Public declarations from `zig/root.zig`. Package setup and build options are in `README.md`.

## Routes and loading

`@import("mimalloc")` exposes the typed facade and `pub const c`, the translated `mimalloc.h` API for the same library. `runtime_loaded` is a comptime boolean.

Runtime mode requires an explicit provider before any facade call:

```zig
try mimalloc.load(.{ .path = "/usr/lib/libmimalloc.so.3" });
// Or: try mimalloc.load(.{ .system = "libmimalloc.so.3" });
```

`.path` requires an absolute file path; `.system` names a platform library. The two forms never fall back to each other. The loader copies the request, and `loadedSource()` returns the retained request or null. Same-request calls are idempotent; failures may be retried; a different request after success returns `ProviderMismatch`. There is no unload or reset. A facade call before loading, or `load` in linked mode, panics in every optimization mode.

Runtime loading requires `mi_version()` to match the header's `MI_MALLOC_VERSION`. It then allocates a block, verifies its usable size and heap ownership, and frees it; this is not a complete ABI proof.

## Errors and ownership

`Error` has two cases: `OutOfMemory` maps C `NULL` and count-times-size overflow; `InvalidAlignment` rejects zero or non-power-of-two alignment before the C call.

Every returned allocation belongs to mimalloc, not a Zig allocator. Release pointers with `free`, `Block.deinit`, or the appropriate C API. `realloc` preserves the original block on failure; `reallocFree` frees it on failure. A zero-size request may return a valid block. `expand` returns null when the block cannot grow; `freeSize` takes a hint, and `usableSize` reports the page's block size.

## Allocation functions

| Family | Functions |
|---|---|
| Raw allocation | `malloc`, `zalloc`, `calloc`, `mallocn`, `mallocSmall`, `zallocSmall` |
| Resize | `realloc`, `reallocn`, `reallocFree`, `rezalloc`, `recalloc`, `expand` |
| Release and size | `free`, `freeSize`, `freeSmall`, `freeSmallNonnull`, `usableSize`, `goodSize` |
| Strings and paths | `strdup`, `strndup`, `realpath`, `realpathInto` |

`strdup`, `strndup`, and `realpath` return mimalloc-owned memory; release it with `free`. `realpathInto` writes to a caller buffer and returns null when resolution fails. `goodSize` rounds a request to an allocator size class.

## Aligned allocation

`mallocAligned`, `zallocAligned`, `callocAligned`, `mallocAlignedAt`, `zallocAlignedAt`, `callocAlignedAt`, `reallocAligned`, `reallocAlignedAt`, `rezallocAligned`, `rezallocAlignedAt`, `recallocAligned`, and `recallocAlignedAt` take `(size, alignment)` or their counted equivalent. The `*AlignedAt` variants add `offset` after `alignment` and align the address at that offset. Allocating and resizing wrappers validate alignment first. `freeAligned` and `freeSizeAligned` are available, but ordinary `free` also accepts aligned blocks.

`alignedAlloc` and `memalign` use `(alignment, size)`. `valloc` uses page alignment; `pvalloc` rounds size to a page multiple.

## Slices and `Block`

| API | Result |
|---|---|
| `allocSlice(T, n)` | Uninitialized `[]T`; checked multiplication; `T` alignment must fit `MI_MAX_ALIGN_SIZE` |
| `allocSliceZeroed(T, n)` | Zeroed `[]T`; checked multiplication and the same alignment limit |
| `allocSliceAligned(T, alignment, n)` | `[]align(alignment) T`; alignment is comptime and checked in safe builds |

`Block` is a copyable pointer wrapper. Use `from`, `alloc`, `zalloc`, or `calloc`; `bytes` and `bytesAs` make caller-sized views, `usableSize` queries the actual block size, `realloc` preserves the block on failure, and `deinit` frees it. Call `deinit` once; a second call double-frees.

## Heaps and thread-local heaps

`Heap.init` and `Heap.initInArena` create an owning heap. `deinit` moves live blocks to the main heap; `destroy` frees them. Heap blocks can be released with global `free`.

Heap allocation and resize methods include `malloc`, `zalloc`, `calloc`, `mallocn`, `mallocSmall`, `zallocSmall`, aligned variants, `realloc`, `reallocn`, `reallocFree`, `rezalloc`, `recalloc`, and aligned variants. Other methods include `strdup`, `strndup`, `realpathInto`, `contains`, `collect`, `setNumaAffinity`, `visitBlocks`, `visitAbandonedBlocks`, and `unsafePageIsUnderUtilized`. `visitBlocks` requires sole-thread access to the heap; `unsafePageIsUnderUtilized` requires sole access to the page.

`Heap.main()` borrows the main heap; `Heap.of(block)` returns a borrowed `HeapRef` when a mimalloc heap owns the block. `HeapRef` provides `isOpen`, `contains`, `malloc`, and `zalloc` and can become stale when its owner closes. `MainHeapRef` provides `contains`, `malloc`, and `zalloc`; it cannot be closed.

`Heap.theap()` returns a provider-owned `TheapRef` for the heap's calling thread. It supports allocation, resize, and collection; `guardedSetSampleRate` and `guardedSetSizeBound` are experimental. Use it only from its creating thread and before closing its parent heap. `theapSetDefault` and `theapDefault` set and read the calling thread's default theap; pass null to clear it.

## Arenas and sub-process groups

`ArenaId` is the upstream handle. `arenaArea`, `arenaMinAlignment`, `arenaMinSize`, `arenaMaxObjectSize`, and `arenaContains` inspect an arena; `ArenaArea.start` is provider-owned and must not be freed or written. Reservation functions are `reserveOsMemory`, `reserveOsMemoryEx`, `reserveHugeOsPagesAt`, `reserveHugeOsPagesAtEx`, `reserveHugeOsPagesInterleave`, and `reserveHugeOsPages`. `manageOsMemory`, `manageOsMemoryEx`, and `manageMemory` register caller-provided regions; `CommitFn` is experimental, writes `is_zero`, and must not allocate or block on another allocating thread.

`Subproc` groups mimalloc arenas without reclaiming between groups; it is not an OS process. It provides `main`, `current`, `create`, `destroy`, `addCurrentThread`, and `visitHeaps`. Destroying it invalidates its blocks; visited heaps are borrowed.

## Options and lifecycle

`Option` uses the translated `mi_option_e` tags. `optionIsEnabled`, `optionEnable`, `optionDisable`, `optionSetEnabled`, `optionSetEnabledDefault`, `optionGet`, `optionGetClamp`, `optionGetSize`, `optionSet`, and `optionSetDefault` access them. Options are process-wide; most are read once at first use. `optionSetDefault` changes the built-in default, not the current value.

`processInit`, `processDone`, `threadInit`, `threadDone`, `threadSetInThreadpool`, and `collect` expose upstream lifecycle calls. Call `processInit` early; call `processDone` only after allocating threads stop and before dynamic unloading. `threadSetInThreadpool` marks the calling thread's memory to survive thread exit. `collect` releases free pages from the calling thread's default theap; it is not process-wide. `anyHeapContains` checks ownership; `checkOwned` is its legacy alias, and `isInHeapRegion` only checks the address range.

`version_num` is the translated header version; `version()` reports the linked library or loaded provider. `isRedirected()` reports whether that provider serves the process's standard `malloc`. `processInfo()` returns `ProcessInfo` with elapsed, user, and system time, current and peak RSS, current and peak commit, and page faults.

## Callbacks and reporting

`DeferredFreeFn` runs before collection with `force` and heartbeat values; `registerDeferredFree` installs it. `registerOutput` accepts a nullable `OutputFn`; messages are provider-owned NUL-terminated strings, so copy them to retain. `registerError` replaces upstream's default abort handler.

`BlockVisitFn` and `HeapVisitFn` receive borrowed objects; returning false stops traversal. `CommitFn` is experimental, writes `is_zero`, and must not allocate or block on another allocating thread.

Reporting calls: `optionsPrint`, `optionsPrintTo`, `processInfoPrint`, `processInfoPrintTo`, `statsPrintTo`, `threadStatsPrintTo` (deprecated, calling thread only), `statsReset`, `debugShowArenas`, and `arenasPrint`. Output callbacks may be null; null selects upstream's default output.