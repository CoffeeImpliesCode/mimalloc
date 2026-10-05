// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Zig facade over the mimalloc v3 C implementation.
//!
//! No part of the allocator is reimplemented here. Every value that comes back
//! out of this module was produced by the C under `src/`, reached through
//! `pub const c`, the module the translation step produces from
//! `zig/translate.h`. What the facade adds is the part a C header cannot
//! express: NULL answers turned into one honest error, a checked alignment rule
//! where upstream only has a debug assertion, a block type that says who owns
//! the bytes, a heap that owns itself and says what closing it means, and the
//! process-wide lifecycle and option surface named.
//!
//! ## Import routes
//!
//! One Zig route is published: `dep.module("mimalloc")` in the dependent's
//! `build.zig`, which is `@import("mimalloc")` in source. The translated header
//! is `c` on that same module and is not published as a module of its own, so
//! the declarations and the library that satisfies them arrive through one
//! route. A C consumer takes the installed headers and the installed library
//! instead; `README.zig.md` names that layout.
//!
//! ```zig
//! const mimalloc = @import("mimalloc");
//!
//! pub fn main() !void {
//!     var block = try mimalloc.Block.alloc(32);
//!     defer block.deinit();
//!     @memset(block.bytes(), 0);
//! }
//! ```
//!
//! ## The allocator crossing, stated once and applying everywhere
//!
//! **Every pointer this module returns is owned by mimalloc, not by Zig.** It
//! comes out of `mi_malloc`, which carves a block out of one of mimalloc's own
//! arenas and returns an interior address inside it (`src/alloc.c:338` ->
//! `src/alloc.c:289-295` -> `src/page.c`'s page allocator). It must be returned
//! to mimalloc with `free` (or `Heap.free`, or `Block.deinit`) and to nothing
//! else.
//!
//! Three consequences follow, and this module states each of them at the place
//! it applies rather than only here:
//!
//!   * **`std.mem.Allocator` is not what these pointers belong to.** Handing one
//!     to a Zig allocator's `free` - including `std.testing.allocator` - is a
//!     mismatched free, not a leak. `Block.deinit` and `Heap` exist so that a
//!     correct caller never has to remember which of the two worlds a pointer
//!     came from.
//!   * **No leak oracle is available, and none is claimed.** A Zig test
//!     allocator can detect a leak of memory *it* handed out, because it holds a
//!     record of its own outstanding blocks. It cannot detect a leak of memory
//!     mimalloc owns: the block was never its, so there is nothing for it to miss.
//!     Nothing in `tests.zig` or `smoke.zig` asserts that this package leaks
//!     nothing, because no test in this package can observe that claim.
//!   * **Addresses say nothing about provenance.** mimalloc returns an interior
//!     pointer into its arena rather than an OS mapping, so a block's address is
//!     not evidence of anything. `anyHeapContains` is the only question this
//!     package asks about whether a pointer is mimalloc's, and it asks upstream's
//!     own predicate (`src/heap.c:276-279`), not a range test.
//!
//! `mi_realpath` is the one place this crossing has a corner worth naming:
//! upstream documents the caller's `resolved_name` buffer as one it may
//! `mi_free` itself (`src/alloc.c:662-746`), which is why `realpath` here takes
//! a buffer rather than returning an owning slice.
//!
//! ## Two configurations: linked and runtime-loaded
//!
//! This module is built in one of two shapes, and `runtime_loaded` says which
//! at comptime.
//!
//! *Linked* is the default. The C library is linked, `c` is the translation of
//! `include/mimalloc.h`, and every call below is a direct call with no table and
//! no check.
//!
//! *Runtime-loaded* is opt-in (`-Druntime`). The library is not linked; `c` is
//! a dispatch generated from the same translation step's output, and every
//! declaration `mimalloc.h` makes is resolved through the platform loader when
//! the caller calls
//!
//! ```zig
//! try mimalloc.load(.{ .path = "/usr/lib/libmimalloc.so.3" });
//! ```
//!
//! before using anything else. A call into a module that has not loaded stops
//! the program with a message naming the function, in every optimization mode.
//! That is a programming error rather than a recoverable condition: the table
//! does not exist yet and there is no partial state to fall back on. The load
//! itself reports a missing file, a provider that does not export what the
//! header declares, a provider from a different mimalloc major version, a
//! request that cannot be honoured because a different provider already won, or
//! a reentrant call, as errors rather than as a different library being loaded
//! instead.
//!
//! The provider is reached, never guessed. `.path` names a file and `.system`
//! names a library for the platform loader; neither falls back to the other,
//! the module has no unload and no reset, and it keeps the handle and its own
//! copy of the request to the end of the process.
//!
//! `runtime/library.zig` states what a provider must be, including the mimalloc
//! v3 external ABI family this SDK supports and why a v2 or v1 provider is
//! refused rather than half used. Those v1 and v2 sources are published in the
//! *same* `v3.5.3` release beside the v3 one, so the spelling of `mi_malloc` on
//! its own does not identify a family.
//!
//! ## This package does not replace your allocator
//!
//! Nothing here is re-routed through mimalloc. No provider already loaded in
//! this workspace is redirected, `LD_PRELOAD` is not set by anything in this
//! package, and no executable built by this package links a library that
//! overrides the standard allocator. The core is compiled with upstream's
//! override macro **undefined** - `src/alloc-override.c` is guarded by
//! `#if defined(MI_MALLOC_OVERRIDE)` (`src/alloc-override.c:13`) and `build.zig`
//! never defines it - so the archive exports `mi_malloc`, `mi_free` and their
//! kin and *not* `malloc`, `free` or the C++ operators. `isRedirected` reports
//! what the provider itself says, which for a `dlopen`ed `libmimalloc.so` is
//! `false`.
//!
//! Making mimalloc *be* this process's allocator is a migration of whatever
//! would consume it - a link line, a preload, or a call site - and is a
//! separate piece of work with its own measurement. It is not something this
//! addition does, and nothing in this package should be read as claiming it
//! does.
//!
//! ## Errors, and what is left alone
//!
//! `Error` has exactly two members, and each is one condition this file
//! checked:
//!
//!   * `OutOfMemory` is upstream's NULL, and nothing else. For the
//!     count-times-size entry points it covers two upstream causes this code
//!     cannot tell apart: `mi_count_size_overflow` rejected the product
//!     (`src/alloc.c:371-375`) or the allocator could not satisfy a request
//!     that did not overflow. The taxonomy stops there rather than inventing a
//!     distinction upstream does not report.
//!   * `InvalidAlignment` is checked *here*, before the call. Upstream's rule is
//!     `alignment != 0 && is_power_of_two(alignment)`
//!     (`include/mimalloc/internal.h:537-539`) and it is reached only through
//!     `mi_assert_internal`, which `NDEBUG` compiles away. A release build would
//!     otherwise hand a nonsense alignment to the page allocator.
//!
//! When these fail, mimalloc has changed nothing the caller can see: a NULL
//! return means no block was created, and a rejected alignment never reached
//! the allocator. In particular `realloc` failing leaves `p` valid and still
//! owned by the caller - that is upstream's documented contract at
//! `src/alloc.c:463-468` ("returning NULL always indicates an error, and `p`
//! will not have been freed in that case") - which is why `reallocFree` exists
//! as a different function rather than as a flag on this one.
//!
//! ## What upstream does not promise, passed through
//!
//!   * **A zero-size request succeeds.** `mi_malloc(0)` returns a valid unique
//!     pointer, not NULL (`src/alloc.c:463-465` says so of `mi_realloc` to a
//!     zero size, in the same words: "just as `mi_malloc(0)`"), and so does
//!     `mi_realloc(p, 0)`. Nothing here turns that into an error or into null.
//!   * **`usableSize` is a rounding answer, not the request.** It reports the
//!     page's block size (`src/free.c:587-590`), which is at least what was
//!     asked for and usually more.
//!   * **`goodSize` is a size-class answer.** `src/page-queue.c:113-125` rounds
//!     up to the bin for a small request, to the OS page size for a large one,
//!     and returns the request unchanged above `MI_MAX_ALLOC_SIZE`.
//!   * **Argument order differs from POSIX.** Every `*_aligned` entry point here
//!     takes `(size, alignment)`, not `(alignment, size)`, because upstream
//!     chose to make alignment follow size (`include/mimalloc.h:149-151`).
//!     `alignedAlloc` is the POSIX-ordered spelling of the same request and is
//!     the one to reach for at a `posix_memalign` call site.
//!   * **A heap can be freed from any thread, and blocks in it too.** That is
//!     upstream's first-class-heap contract (`include/mimalloc.h:235-237`), not
//!     an accident of this binding.
const std = @import("std");

/// The translated `mimalloc.h`, i.e. upstream's ABI exactly as published.
///
/// This is the escape hatch for everything the facade does not name: the
/// POSIX- and Windows-shaped `mi_memalign`, `mi_valloc`, `mi_pvalloc`,
/// `mi_aligned_alloc`, `mi_reallocarray`, `mi_reallocarr`, `mi_dupenv_s`,
/// `mi_wdupenv_s`, `mi_wcsdup`, `mi_mbsdup` and `mi_cfree`
/// (`include/mimalloc.h:534-552`), the `mi_new*` family (`:561-574`), the
/// small-word-size entry points (`:586-589`), and the block-size-reporting
/// `mi_u*` family (`:222-231`). It is the same module the facade calls, on the
/// same library, so importing the facade is all a dependent needs to reach it;
/// it is not published under a name of its own.
///
/// In a runtime-loaded build this module is a generated dispatch instead of the
/// translation step's own output. It publishes the same namespace: every type
/// and constant is re-exported from the translation rather than restated, so
/// `mi_heap_t` is the same nominal type either way and nothing here needs a
/// cast.
///
/// ## Two names in here do not exist
///
/// `mi_collect_reduce` (`include/mimalloc.h:435`) and `mi_stats_merge`
/// (`include/mimalloc.h:438`) are declared in upstream's header and defined in
/// no translation unit of the v3.5.3 source. A dependent that calls either
/// fails to link in a linked build and stops the program by name in a
/// runtime-loaded one. They are listed in `provider_excluded` in
/// `runtime/graph.zig` precisely so that their absence does not fail every
/// *other* symbol's load. See `FORK-NOTES.md`.
pub const c = @import("c");

/// The loader core, which is where a linked build's two public types come
/// from.
///
/// It is imported only by the linked configuration. In a runtime-loading build
/// the dispatch carries its own copy of the same declarations, and this module
/// is never referenced, so it is never resolved and never compiled. Either way
/// there is exactly one `LoadSource` and one `LoadError` in a build, which is
/// what keeps them one type for a consumer that names them.
const rt = @import("rt");

/// Whether this module was configured to resolve its native symbols at run
/// time.
///
/// False for the ordinary build, where the C library is linked and `c` is the
/// translation of `include/mimalloc.h`. True when the build generated a
/// dispatch that resolves the same symbols through the platform loader, in
/// which case `load` is the call that makes the library usable.
///
/// It is a comptime constant, so a consumer can write two different code paths
/// and have only the one it chose analyzed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library `load` should open.
///
/// `.path` is an explicit file path and `.system` is an explicit name for the
/// platform loader. There is no path-to-system fallback and no implicit
/// fallback of any kind; a request that cannot be honoured is an error, not a
/// different library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way `load` can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside the
/// loader: the caller names the failure it is handling.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then
/// use this module as if it were linked. Calling it again with the same request
/// succeeds and changes nothing; calling it with a different request after a
/// success is `ProviderMismatch`, and the library already in use stays in use.
/// A failed attempt publishes nothing and can be retried explicitly, by
/// calling this again: there is no automatic retry and no implicit second
/// source.
///
/// It keeps the process handle and its own copy of the request to the end of
/// the process. There is no unload and no reset, because the table is
/// process-global state that other code may already have called through.
///
/// Safe to call from any thread. A thread that arrives while an attempt for the
/// same request is in flight waits for that attempt and gets its result,
/// whatever it was. A call from the thread that is running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve, so
/// this stops the program with a message saying so instead of quietly
/// succeeding. `runtime_loaded` is false there, so a consumer that supports
/// both configurations can tell the two apart at comptime instead of meeting
/// this at run time.
pub fn load(source: LoadSource) LoadError!void {
    // `c.load` exists only in a runtime-loading build. The condition is known
    // at comptime, so the branch this build does not take is never analyzed
    // and never names it.
    if (runtime_loaded) return c.load(source);
    std.debug.panic(
        "mimalloc: load was called on a linked build; this module is not " ++
            "runtime-loaded, so there is no library to load. Build with " ++
            "runtime loading configured, or do not call load.",
        .{},
    );
}

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The answer is the loader's own retained copy and stays valid for the life of
/// the process. Null in a linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (runtime_loaded) return c.loadedSource();
    return null;
}

/// Every way one of this module's own wrappers can decline.
///
/// `OutOfMemory` and `InvalidAlignment` are the only two, and each is one
/// condition this file actually checked; the module comment above says what
/// each covers and what it leaves alone.
pub const Error = error{
    /// The C returned NULL. Nothing was allocated and nothing was freed.
    ///
    /// For `calloc`, `mallocn`, `reallocn` and `recalloc` this also covers an
    /// upstream size-product overflow, which reports NULL rather than a
    /// distinct code (`src/alloc.c:371-375`).
    OutOfMemory,
    /// The alignment was zero or was not a power of two.
    ///
    /// Checked here before the call; upstream's own rule is an assertion that a
    /// release build compiles away (`include/mimalloc/internal.h:537-539`). No
    /// allocator state changed.
    InvalidAlignment,
};

/// `MI_MALLOC_VERSION` as this header's translation reads it
/// (`include/mimalloc.h:11`): major, then two digits of minor, then two of
/// patch. 30503 for v3.5.3.
///
/// This is the value `version` answers with in a linked build, the value
/// `runtime/library.zig` requires of a loaded provider, and the ABI family this
/// SDK claims. The three are one fact and are kept equal by reading the same
/// translation constant rather than by restating a number.
pub const version_num: c_int = c.MI_MALLOC_VERSION;

/// The version the *linked* library reports.
///
/// The same value as `version_num` in a linked build. In a runtime-loaded build
/// it is the loaded provider's own answer, which is what makes it a fact about
/// the provider rather than about this program; the loader has already refused
/// a provider that disagreed, so a `null`-free call cannot observe a mismatch.
pub fn version() c_int {
    return c.mi_version();
}

/// Whether this provider is the one serving the process's standard `malloc`.
///
/// Upstream's own predicate (`include/mimalloc.h:329`,
/// `src/init.c:510-512`). For this package the honest answer is `false`: the
/// core is compiled with `MI_MALLOC_OVERRIDE` undefined, so it exports
/// `mi_malloc` and not `malloc`, and nothing in this package preloads it or
/// links it in place of the system allocator. See the module comment, "This
/// package does not replace your allocator".
///
/// In a runtime-loaded build this is the provider's answer rather than this
/// build's, and a `dlopen`ed provider still answers `false` because the process
/// was not preloaded with it.
pub fn isRedirected() bool {
    return c.mi_is_redirected();
}

/// Upstream's rule for a valid alignment, as a function this module can ask.
///
/// `include/mimalloc/internal.h:537-539`: non-zero and a power of two. That is
/// upstream's *internal* spelling of the `posix_memalign` rule
/// (`https://en.cppreference.com/c/memory/aligned_alloc#Notes`, cited there),
/// and it is the rule every `*_aligned` entry point below is checked against.
fn checkedAlignment(alignment: usize) Error!usize {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;
    return alignment;
}

// ---------------------------------------------------------------------------
// The standard malloc interface
//
// `mi_malloc` and kin (`include/mimalloc.h:110-118`). Every pointer these
// return is mimalloc's and must go back to `free`; see the module comment.
// ---------------------------------------------------------------------------

/// `mi_malloc` (`include/mimalloc.h:110`, `src/alloc.c:338-340`).
///
/// `size == 0` is not an error and does not return null: upstream hands back a
/// valid unique pointer, and `src/alloc.c:463-465` says so in the same words it
/// uses for a zero-size `mi_realloc` ("just as `mi_malloc(0)`"). That pointer
/// still has to be freed.
///
/// `error.OutOfMemory` is upstream's NULL and nothing else, and it is the only
/// failure: no block was created and nothing was freed.
pub fn malloc(size: usize) Error!*anyopaque {
    return c.mi_malloc(size) orelse error.OutOfMemory;
}

/// `mi_zalloc` (`include/mimalloc.h:128`): `malloc` with the whole block zeroed.
///
/// The zeroing is a real guarantee and not a side effect of fresh pages:
/// `_mi_theap_malloc_zero` is called with `zero = true` for a small block
/// (`src/alloc.c:289-295`) and with `zero = true` on the generic path too, so a
/// block recycled from a freed one arrives zeroed as well.
pub fn zalloc(size: usize) Error!*anyopaque {
    return c.mi_zalloc(size) orelse error.OutOfMemory;
}

/// `mi_calloc` (`include/mimalloc.h:111`, `src/alloc.c:377-379`): `count *
/// size` bytes, zeroed.
///
/// Zeroed for the same reason as `zalloc`: `mi_theap_calloc` multiplies and then
/// calls the zeroing entry point (`src/alloc.c:371-375`), so a recycled block
/// is zeroed too.
///
/// An overflowing product is `error.OutOfMemory`. `mi_count_size_overflow`
/// rejects it and upstream returns NULL (`src/alloc.c:372-373`) with no code of
/// its own, so this cannot be told apart from a real out-of-memory and is not
/// invented as a separate tag.
pub fn calloc(count: usize, size: usize) Error!*anyopaque {
    return c.mi_calloc(count, size) orelse error.OutOfMemory;
}

/// `mi_mallocn` (`include/mimalloc.h:130`, `src/alloc.c:432-436`): `count *
/// size` bytes, **not** zeroed.
///
/// Upstream's own comment at `src/alloc.c:429` calls this an "uninitialized
/// `calloc`": it overflow-checks the product and then calls `mi_malloc`. Use
/// `calloc` for a zeroed product and this when the bytes do not matter.
pub fn mallocn(count: usize, size: usize) Error!*anyopaque {
    return c.mi_mallocn(count, size) orelse error.OutOfMemory;
}

/// `mi_malloc_small` (`include/mimalloc.h:126`, `src/alloc.c:246-248`): the
/// small-block fast path.
///
/// The request is not range-checked by this wrapper: upstream forwards it
/// straight to `mi_theap_xmalloc_small_zero` (`src/alloc.c:246-248`), so a size
/// above the small maximum is whatever that path decides, and only
/// `free_small` may be used to return it. `free` is always correct and is what
/// this module recommends; see `freeSmall` for the one case upstream singles
/// out.
pub fn mallocSmall(size: usize) Error!*anyopaque {
    return c.mi_malloc_small(size) orelse error.OutOfMemory;
}

/// `mi_zalloc_small` (`include/mimalloc.h:127`, `src/alloc.c:250-252`): the
/// small-block fast path with the block zeroed.
pub fn zallocSmall(size: usize) Error!*anyopaque {
    return c.mi_zalloc_small(size) orelse error.OutOfMemory;
}

/// `mi_realloc` (`include/mimalloc.h:112`, `src/alloc.c:554-556`).
///
/// * A null `block` behaves as `malloc(new_size)`.
/// * `new_size == 0` returns a valid zero-sized block, not null, exactly as
///   `mi_malloc(0)` does (`src/alloc.c:463-465`).
/// * A block that already fits is returned unchanged whenever
///   `new_size >= usable / 2` (`src/alloc.c:483`), so the pointer you get back
///   is not necessarily a new address.
/// * On failure `block` is **still valid and still the caller's**. Upstream
///   frees the original only after the new block exists
///   (`src/alloc.c:518-521`) and states the rule at `src/alloc.c:463-468`.
///
/// The zeroed variant is `rezalloc`.
pub fn realloc(block: ?*anyopaque, new_size: usize) Error!*anyopaque {
    return c.mi_realloc(block, new_size) orelse error.OutOfMemory;
}

/// `mi_reallocn` (`include/mimalloc.h:131`, `src/alloc.c:558-562`): `count *
/// size` bytes, not zeroed, with `realloc`'s ownership rule unchanged.
pub fn reallocn(block: ?*anyopaque, count: usize, size: usize) Error!*anyopaque {
    return c.mi_reallocn(block, count, size) orelse error.OutOfMemory;
}

/// `mi_reallocf` (`include/mimalloc.h:132`, `src/alloc.c:575-577`): like
/// `realloc`, but **`block` is freed when the call fails**.
///
/// `src/alloc.c:571-574` is the whole difference: a null result with a non-null
/// input is followed by `mi_free(p)`. That makes this the spelling to reach for
/// when a failure should not leave the old block behind - and the reason
/// `realloc` can promise that a failure leaves `block` valid is that these are
/// two functions rather than one with a flag.
pub fn reallocFree(block: ?*anyopaque, new_size: usize) Error!*anyopaque {
    return c.mi_reallocf(block, new_size) orelse error.OutOfMemory;
}

/// `mi_rezalloc` (`include/mimalloc.h:285`, `src/alloc.c:579-581`): `realloc`
/// where the growth is zeroed.
///
/// Upstream zeroes from the end of the preserved content onwards
/// (`src/alloc.c:506-517`), including the last word of the old allocation so
/// padding is zeroed too. It is only meaningful for a block that was itself
/// zeroed on allocation - `calloc`, `zalloc`, `zalloc_aligned` - as
/// `include/mimalloc.h:280-282` says.
///
/// `block` survives a failure, as for `realloc`.
pub fn rezalloc(block: ?*anyopaque, new_size: usize) Error!*anyopaque {
    return c.mi_rezalloc(block, new_size) orelse error.OutOfMemory;
}

/// `mi_recalloc` (`include/mimalloc.h:286`, `src/alloc.c:583-585`): `count *
/// size` bytes with the growth zeroed, on a block that was zeroed to begin with.
pub fn recalloc(block: ?*anyopaque, newcount: usize, size: usize) Error!*anyopaque {
    return c.mi_recalloc(block, newcount, size) orelse error.OutOfMemory;
}

/// `mi_expand` (`include/mimalloc.h:113`, `src/alloc.c:449-462`): grow a block
/// in place when its page already has room for more.
///
/// **The null answer is not an error, and this signature says so.** Upstream
/// returns the pointer it was given when the request fits and NULL when it does
/// not (`src/alloc.c:449-462`), and compiles the whole body to `return NULL`
/// when `MI_PADDING` is on (`src/alloc.c:449-452`) - which is the case in any
/// build where `MI_DEBUG` is (`include/mimalloc/types.h:116-122`). Every other
/// allocating entry point here turns NULL into `error.OutOfMemory` because NULL
/// there means "no block was created"; here it means "this block did not grow",
/// which is upstream's ordinary answer and not a failure of the caller. `realloc`
/// is the entry point that resizes.
pub fn expand(block: ?*anyopaque, new_size: usize) ?*anyopaque {
    return c.mi_expand(block, new_size);
}

///
/// A null `block` is a no-op: `mi_ptr_page_is_valid` is called with
/// `check_p_for_null = true` (`src/free.c:284-286`, `:251-254`).
///
/// This is the *only* correct way to return a pointer from `malloc`, `zalloc`,
/// `calloc`, the `Block` helpers and `strdup`. Passing a pointer that some other
/// allocator owns is a mismatched free; see the module comment.
pub fn free(block: ?*anyopaque) void {
    c.mi_free(block);
}

/// `mi_free_size` (`include/mimalloc.h:138`, `src/free.c:334-335`).
///
/// The size is a hint, not a contract: upstream's own comment at
/// `include/mimalloc.h:137` says it "can be more efficient", and this build
/// compiles the body with the size unused (`src/free.c:335`). A wrong size is
/// only diagnosed in a debug build (`src/free.c:336-345`). `free` is always
/// correct and costs the same here.
pub fn freeSize(block: ?*anyopaque, size: usize) void {
    c.mi_free_size(block, size);
}

/// `mi_free_small` (`include/mimalloc.h:142`, `src/free.c:307-312`): the
/// small-block fast free.
///
/// Only for a pointer from `mallocSmall` or `zallocSmall`, as
/// `include/mimalloc.h:140-141` says. A null pointer is accepted here, unlike
/// `freeSmallNonnull`.
pub fn freeSmall(block: ?*anyopaque) void {
    c.mi_free_small(block);
}

/// `mi_free_small_nonnull` (`include/mimalloc.h:145`, `src/free.c:314-319`).
///
/// As `freeSmall`, and it asserts that `block` is not null. This module takes a
/// non-nullable parameter for exactly that reason, so the assertion upstream
/// makes cannot be violated from here.
pub fn freeSmallNonnull(block: *anyopaque) void {
    c.mi_free_small_nonnull(block);
}

/// `mi_usable_size` (`include/mimalloc.h:134`, `src/free.c:587-590`): the number
/// of bytes the block actually has.
///
/// This is the page's block size (`_mi_page_usable_size`), so it is at least the
/// requested size and usually more. It is the honest answer to "how much may I
/// write", and using it is why a `mi_malloc(n)` block can be treated as an
/// `n`-to-`usableSize(n)` buffer.
///
/// `block` must be a pointer mimalloc returned. Upstream's validity check for
/// an unusable pointer is compiled out with `NDEBUG` (`src/free.c:217-226`), so
/// in a release build passing a foreign pointer is undefined rather than an
/// error. That is why the parameter is non-nullable and why this function does
/// not take a `?`.
pub fn usableSize(block: *const anyopaque) usize {
    return c.mi_usable_size(block);
}

/// `mi_good_size` (`include/mimalloc.h:135`, `src/page-queue.c:113-125`): the
/// size class a request would be served at.
///
/// Rounds a small request up to its bin, rounds a large one up to the OS page
/// size, and returns the request unchanged above `MI_MAX_ALLOC_SIZE`. Asking for
/// this before allocating is how a caller sizes a request so that it does not
/// straddle two size classes.
pub fn goodSize(size: usize) usize {
    return c.mi_good_size(size);
}

/// `mi_strdup` (`include/mimalloc.h:116`, `src/alloc.c:627-629`).
///
/// The returned bytes are **mimalloc's**: `mi_theap_strdup` allocates with
/// `mi_theap_malloc` (`src/alloc.c:616-626`) and the header says to return them
/// with `mi_free` (`include/mimalloc.h:116`). `free(result.ptr)` is that call.
/// The copy is NUL-terminated and owns its bytes; nothing here borrows.
///
/// Upstream returns NULL for a null input as well as for an allocation failure
/// (`src/alloc.c:617`). Zig's `[:0]const u8` cannot be null, so this takes a
/// non-nullable slice and the only remaining NULL is `error.OutOfMemory`.
pub fn strdup(s: [:0]const u8) Error![*:0]u8 {
    return c.mi_strdup(s.ptr) orelse error.OutOfMemory;
}

/// `mi_strndup` (`include/mimalloc.h:117`, `src/alloc.c:647-649`): at most `n`
/// bytes of `s`, stopping early at a NUL, NUL-terminated.
///
/// Owned by mimalloc, exactly as `strdup` is. `src/alloc.c:636-646` is the
/// whole body: `_mi_strnlen(s, n)` then a `len + 1` allocation and a copy.
pub fn strndup(s: [:0]const u8, n: usize) Error![*:0]u8 {
    return c.mi_strndup(s.ptr, n) orelse error.OutOfMemory;
}

/// `mi_realpath` with a null `resolved_name` (`include/mimalloc.h:118`,
/// `src/alloc.c:718-741`): resolve `fname` into memory mimalloc owns.
///
/// The returned bytes are **mimalloc's** and must be returned with `free`.
/// That is not a guess about the argument: on POSIX the null-buffer path
/// allocates with `mi_theap_zalloc`, copies, and frees its own scratch buffer
/// (`src/alloc.c:725-739`), and on Windows it copies its stack buffer with
/// `mi_theap_strndup` (`src/alloc.c:688-691`). Both return mimalloc's memory.
///
/// Null means the path could not be resolved; upstream sets `errno` on the
/// Windows path (`src/alloc.c:669-687`) and libc sets it on the POSIX one.
pub fn realpath(fname: [:0]const u8) Error![*:0]u8 {
    return c.mi_realpath(fname.ptr, null) orelse error.OutOfMemory;
}

/// `mi_realpath` with a caller's buffer (`include/mimalloc.h:118`,
/// `src/alloc.c:662-697`): resolve `fname` into `buffer`.
///
/// When this returns non-null the bytes are **in `buffer` and are yours**: on
/// POSIX it is libc's `realpath` writing there (`src/alloc.c:719-720`) and on
/// Windows it is `GetFullPathNameA` writing there and then returning that same
/// pointer (`src/alloc.c:668`, `:694-695`). Nothing is allocated and nothing
/// needs freeing. That is the opposite ownership from `realpath` above, which is
/// why they are two functions and not one.
///
/// `buffer` must have room for a `PATH_MAX` path. Upstream passes `PATH_MAX` as
/// the size on Windows whatever the real buffer is (`src/alloc.c:668`), and
/// POSIX's `realpath` makes the same assumption. `PATH_MAX` is not in this
/// package's translation - `mimalloc.h` never includes `<limits.h>` - so it
/// cannot be read from here; upstream's own floor for it is 256 bytes and its
/// own guess when `pathconf` is unhelpful is 4096 (`src/alloc.c:706-711`).
///
/// This is the form to use when a path must not allocate.
pub fn realpathInto(fname: [:0]const u8, buffer: []u8) ?[]u8 {
    // Both platform paths return the caller's own buffer when it is non-null
    // (`src/alloc.c:719-720` on POSIX, `src/alloc.c:694-695` on Windows), so the
    // written path is always `buffer`. The length is measured rather than
    // assumed, because a caller that passed a buffer larger than the path would
    // otherwise get its trailing bytes reported as part of the path.
    // `@ptrCast` to a sentinel-terminated pointer because `mi_realpath`'s second
    // parameter is `char *`, which the translation spells `[*:0]u8`. The buffer
    // is not NUL-terminated by the caller, and upstream writes the terminator:
    // both platform paths end by returning a path with one
    // (`src/alloc.c:719-720`, `:694-695`).
    if (c.mi_realpath(fname.ptr, @ptrCast(buffer.ptr)) == null) return null;
    return buffer[0..std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}

// ---------------------------------------------------------------------------
// Aligned allocation
//
// `include/mimalloc.h:149-161`. Argument order is `(size, alignment)` on every
// one of them, because upstream chose to make alignment follow size
// (`include/mimalloc.h:149-151`); that is the opposite of `posix_memalign` and
// of `aligned_alloc`, and `alignedAlloc` below is the POSIX-ordered spelling of
// the same request.
//
// Every alignment here is checked against upstream's own rule - non-zero and a
// power of two (`include/mimalloc/internal.h:537-539`) - before the call,
// because upstream reaches that rule only through `mi_assert_internal`, which
// `NDEBUG` removes.
// ---------------------------------------------------------------------------

/// `mi_malloc_aligned` (`include/mimalloc.h:154`): `size` bytes at `alignment`.
///
/// `error.InvalidAlignment` is decided here and never reaches mimalloc.
pub fn mallocAligned(size: usize, alignment: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_malloc_aligned(size, alignment) orelse error.OutOfMemory;
}

/// `mi_zalloc_aligned` (`include/mimalloc.h:156`): as `mallocAligned`, zeroed.
pub fn zallocAligned(size: usize, alignment: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_zalloc_aligned(size, alignment) orelse error.OutOfMemory;
}

/// `mi_calloc_aligned` (`include/mimalloc.h:158`): `count * size` zeroed bytes
/// at `alignment`.
pub fn callocAligned(count: usize, size: usize, alignment: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_calloc_aligned(count, size, alignment) orelse error.OutOfMemory;
}

/// `mi_malloc_aligned_at` (`include/mimalloc.h:155`): place the block so that
/// `offset` bytes into it sit on an `alignment` boundary.
///
/// `offset` is what makes this different from every POSIX spelling, and it is
/// why this entry point exists: a header can be placed at a chosen address
/// inside the block, which is how a caller aligns a field rather than the
/// allocation itself.
pub fn mallocAlignedAt(size: usize, alignment: usize, offset: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_malloc_aligned_at(size, alignment, offset) orelse error.OutOfMemory;
}

/// `mi_zalloc_aligned_at` (`include/mimalloc.h:157`): as `mallocAlignedAt`,
/// zeroed.
pub fn zallocAlignedAt(size: usize, alignment: usize, offset: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_zalloc_aligned_at(size, alignment, offset) orelse error.OutOfMemory;
}

/// `mi_calloc_aligned_at` (`include/mimalloc.h:159`): `count * size` zeroed
/// bytes with `offset` on an `alignment` boundary.
pub fn callocAlignedAt(count: usize, size: usize, alignment: usize, offset: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_calloc_aligned_at(count, size, alignment, offset) orelse error.OutOfMemory;
}

/// `mi_realloc_aligned` (`include/mimalloc.h:160`).
///
/// Ownership on failure is `realloc`'s: the old block survives
/// (`src/alloc-aligned.c`'s `mi_heap_realloc_aligned` routes through
/// `mi_theap_realloc`). `mi_reallocf` has no aligned counterpart in v3, so there
/// is deliberately no aligned free-on-failure function to name here.
pub fn reallocAligned(block: ?*anyopaque, new_size: usize, alignment: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_realloc_aligned(block, new_size, alignment) orelse error.OutOfMemory;
}

/// `mi_realloc_aligned_at` (`include/mimalloc.h:161`).
pub fn reallocAlignedAt(block: ?*anyopaque, new_size: usize, alignment: usize, offset: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_realloc_aligned_at(block, new_size, alignment, offset) orelse error.OutOfMemory;
}

/// `mi_rezalloc_aligned` (`include/mimalloc.h:288`): `reallocAligned` where the
/// growth is zeroed, on a block that was zeroed to begin with.
pub fn rezallocAligned(block: ?*anyopaque, new_size: usize, alignment: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_rezalloc_aligned(block, new_size, alignment) orelse error.OutOfMemory;
}

/// `mi_rezalloc_aligned_at` (`include/mimalloc.h:289`).
pub fn rezallocAlignedAt(block: ?*anyopaque, new_size: usize, alignment: usize, offset: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_rezalloc_aligned_at(block, new_size, alignment, offset) orelse error.OutOfMemory;
}

/// `mi_recalloc_aligned` (`include/mimalloc.h:290`): `count * size` zeroed
/// growth at `alignment`.
pub fn recallocAligned(block: ?*anyopaque, newcount: usize, size: usize, alignment: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_recalloc_aligned(block, newcount, size, alignment) orelse error.OutOfMemory;
}

/// `mi_recalloc_aligned_at` (`include/mimalloc.h:291`).
pub fn recallocAlignedAt(block: ?*anyopaque, newcount: usize, size: usize, alignment: usize, offset: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_recalloc_aligned_at(block, newcount, size, alignment, offset) orelse error.OutOfMemory;
}

/// `mi_free_aligned` (`include/mimalloc.h:546`): return an aligned block.
///
/// The alignment is an argument so the free can take the aligned fast path.
/// `free` accepts the same pointer without it, which is why this is here for
/// completeness rather than out of necessity.
pub fn freeAligned(block: ?*anyopaque, alignment: usize) void {
    c.mi_free_aligned(block, alignment);
}

/// `mi_free_size_aligned` (`include/mimalloc.h:545`): `freeAligned` with a size
/// hint, with `freeSize`'s caveat that the size is not a contract.
pub fn freeSizeAligned(block: ?*anyopaque, size: usize, alignment: usize) void {
    c.mi_free_size_aligned(block, size, alignment);
}

/// `mi_aligned_alloc` (`include/mimalloc.h:538`): the POSIX spelling, with the
/// arguments the other way round.
///
/// `src/alloc-posix.c:68` is the body, and it forwards to the same
/// `mi_malloc_aligned` this module wraps. Use it where a POSIX interface is
/// being satisfied, and `mallocAligned` everywhere else, so that reading the
/// call tells you which convention it is.
pub fn alignedAlloc(alignment: usize, size: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_aligned_alloc(alignment, size) orelse error.OutOfMemory;
}

/// `mi_memalign` (`include/mimalloc.h:535`): the historical POSIX spelling.
///
/// `src/alloc-posix.c:51-53` is the body. `alignedAlloc` is the same request
/// with the same argument order; this name is kept because the historical one
/// appears in older sources.
pub fn memalign(alignment: usize, size: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_memalign(alignment, size) orelse error.OutOfMemory;
}

/// `mi_valloc` (`include/mimalloc.h:536`, `src/alloc-posix.c:57-59`): `size`
/// bytes at the platform's page alignment.
pub fn valloc(size: usize) Error!*anyopaque {
    return c.mi_valloc(size) orelse error.OutOfMemory;
}

/// `mi_pvalloc` (`include/mimalloc.h:537`, `src/alloc-posix.c:61-63`): `valloc`
/// with the size rounded up to a multiple of the page size, as POSIX requires.
pub fn pvalloc(size: usize) Error!*anyopaque {
    return c.mi_pvalloc(size) orelse error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Typed and slice-shaped views of the same blocks
//
// These do not allocate anything of their own: each is one call to an entry
// point above plus a cast. The slice it returns is a *view* of a mimalloc
// block, its length is the length that was asked for and not the usable size,
// and `free` returns the block.
// ---------------------------------------------------------------------------

/// `n` elements of `T`, not zeroed. The product is overflow-checked here.
///
/// mimalloc aligns every block to at least `MI_MAX_ALIGN_SIZE`
/// (`include/mimalloc/types.h:38-40`, 16 bytes where a word is 8), so any `T`
/// whose alignment is at most that needs nothing extra. A more strictly aligned
/// `T` needs `allocSliceAligned`, which asks for the alignment rather than
/// hoping for it.
pub fn allocSlice(comptime T: type, n: usize) Error![]T {
    const total = std.math.mul(usize, n, @sizeOf(T)) catch return error.OutOfMemory;
    const raw = try malloc(total);
    return (@as([*]T, @ptrCast(@alignCast(raw))))[0..n];
}

/// `n` elements of `T`, zeroed. The product is overflow-checked here, and the
/// alignment caveat is `allocSlice`'s.
pub fn allocSliceZeroed(comptime T: type, n: usize) Error![]T {
    const total = std.math.mul(usize, n, @sizeOf(T)) catch return error.OutOfMemory;
    const raw = try zalloc(total);
    return (@as([*]T, @ptrCast(@alignCast(raw))))[0..n];
}

/// `n` elements of `T` at `alignment`, not zeroed.
///
/// `alignment` is comptime because the returned slice's alignment is part of its
/// type: `[]align(alignment) T` says the alignment to the compiler, and
/// `@alignCast` checks at run time in a safe build that mimalloc really
/// honoured it. That check is the point - `mi_malloc_aligned` returns an
/// interior address into its own arena, and the alignment is the one thing
/// about that address worth proving.
pub fn allocSliceAligned(comptime T: type, comptime alignment: usize, n: usize) Error![]align(alignment) T {
    const total = std.math.mul(usize, n, @sizeOf(T)) catch return error.OutOfMemory;
    const raw = try mallocAligned(total, alignment);
    const bytes: [*]align(alignment) u8 = @ptrCast(@alignCast(raw));
    const typed: [*]align(alignment) T = @ptrCast(bytes);
    return typed[0..n];
}

/// The file-scope entry points that `Block`'s same-named methods reach.
///
/// `Block` below declares `zalloc`, `calloc`, `usableSize` and `realloc` of
/// its own, each returning a `Block` rather than a bare pointer. A bare call
/// to one of those names from inside `Block` names both declarations and is
/// ambiguous, so each call reaches the file-scope function through one of the
/// aliases here, which names exactly one.
const block_zalloc = zalloc;
const block_calloc = calloc;
const block_usable_size = usableSize;
const block_realloc = realloc;

/// A mimalloc block, named so that it is obvious at the call site that `free`
/// and not a Zig allocator's `free` is what has to be called.
///
/// This is a marker, not a manager: it adds no bookkeeping, and its only
/// advantage over carrying a `*anyopaque` is that `deinit` exists. `Block`
/// exists because the mistake this package's module comment describes - handing
/// a mimalloc pointer to `std.heap.page_allocator` or to a `defer
/// testing.allocator.free(...)` - is a mismatched free rather than a
/// diagnosable one, and a type name is cheaper than a comment at every site.
pub const Block = struct {
    /// The pointer mimalloc returned.
    ptr: *anyopaque,

    /// Adopt a pointer that already exists. Free it with `deinit` or `free`.
    pub fn from(raw: *anyopaque) Block {
        return .{ .ptr = raw };
    }

    /// `size` bytes, not zeroed.
    pub fn alloc(size: usize) Error!Block {
        return .{ .ptr = try malloc(size) };
    }

    /// `size` bytes, zeroed.
    pub fn zalloc(size: usize) Error!Block {
        return .{ .ptr = try block_zalloc(size) };
    }

    /// `count * size` bytes, zeroed.
    pub fn calloc(count: usize, size: usize) Error!Block {
        return .{ .ptr = try block_calloc(count, size) };
    }

    /// `len` writable bytes. The length is the caller's, because the usable
    /// size is a different number and guessing it would be re-deriving what
    /// `usableSize` reports.
    pub fn bytes(self: Block, len: usize) []u8 {
        return (@as([*]u8, @ptrCast(self.ptr)))[0..len];
    }

    /// `len` writable elements of `T`.
    ///
    /// The alignment caveat is `allocSlice`'s: every block is aligned to at
    /// least `MI_MAX_ALIGN_SIZE`, and `@alignCast` checks that at run time in a
    /// safe build rather than assuming it.
    pub fn bytesAs(self: Block, comptime T: type, len: usize) []T {
        return (@as([*]T, @ptrCast(@alignCast(self.ptr))))[0..len];
    }

    /// How many bytes this block really has, as `usableSize` reports it.
    pub fn usableSize(self: Block) usize {
        return block_usable_size(self.ptr);
    }

    /// Resize, returning the block that now holds it.
    ///
    /// On failure `self` is still valid, as `realloc` promises.
    pub fn realloc(self: Block, new_size: usize) Error!Block {
        return .{ .ptr = try block_realloc(self.ptr, new_size) };
    }

    /// Give the block back to mimalloc. A second `deinit` on the same value is
    /// a double free and is not guarded here: `Block` is a copyable `*anyopaque`
    /// and copying one is exactly the mistake this type documents.
    pub fn deinit(self: Block) void {
        free(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// Heaps
//
// `include/mimalloc.h:235-275`. A heap is first-class: it can be allocated
// from any thread and its blocks can be freed from any thread
// (`include/mimalloc.h:235-237`), and it keeps its blocks in pages of its own
// while sharing its arena's and its freed pages.
//
// Closing a heap is two different operations and this module does not merge
// them:
//
//   `deinit`  is `mi_heap_delete` (`src/heap.c:236-244`): the heap object goes
//             away and its **live blocks are moved to the main heap**. They are
//             not freed; the caller still owns them and must still `free` them,
//             which now succeeds through the main heap.
//   `destroy` is `mi_heap_destroy` (`src/heap.c:261-268`): the heap object goes
//             away and **every live block in it is freed**, without the caller
//             freeing any of them.
//
// Both refuse the main heap, with a warning rather than a failure
// (`src/heap.c:239-242`, `:263-266`), so neither is a way to shut the process's
// allocator down.
// ---------------------------------------------------------------------------

/// A mimalloc heap: the one owning type in this module.
///
/// `raw` is null after `deinit`, which makes a second `deinit` on the same
/// variable a no-op rather than a second delete. `handle` stops the program if
/// the heap is already closed, because every other method here needs a live
/// heap and silently allocating from the main one instead would be a different
/// program.
pub const Heap = struct {
    raw: ?*c.mi_heap_t = null,

    /// A fresh heap. `error.OutOfMemory` is upstream's NULL from
    /// `mi_heap_new` (`src/heap.c:158-160`).
    pub fn init() Error!Heap {
        return .{ .raw = c.mi_heap_new() orelse return error.OutOfMemory };
    }

    /// A fresh heap that allocates only in `arena_id`. `include/mimalloc.h:350`
    /// is the declaration; a null `arena_id` means the process's default arena,
    /// which is what `init` does.
    pub fn initInArena(arena_id: ArenaId) Error!Heap {
        return .{ .raw = c.mi_heap_new_in_arena(arena_id) orelse return error.OutOfMemory };
    }

    /// Close this heap, moving its live blocks to the main heap.
    ///
    /// The blocks are **not** freed. A caller that wanted them gone wanted
    /// `destroy`. Upstream's own comment at `include/mimalloc.h:243` is "move
    /// live blocks to the main heap", and `src/heap.c:243-244` is the move.
    pub fn deinit(self: *Heap) void {
        const raw = self.raw orelse return;
        self.raw = null;
        c.mi_heap_delete(raw);
    }

    /// Close this heap and free every live block in it.
    ///
    /// No block from this heap may be freed afterwards. This is the only way to
    /// release a heap's contents in one operation, and it is why a heap that
    /// owns its blocks should be closed this way rather than with `deinit`.
    pub fn destroy(self: *Heap) void {
        const raw = self.raw orelse return;
        self.raw = null;
        c.mi_heap_destroy(raw);
    }

    /// The live heap, or a stop.
    ///
    /// An ordinary panic in every optimization mode: calling a heap method on a
    /// closed heap would otherwise fall through to a null pointer and read
    /// whatever the allocator found there.
    ///
    /// Public because `TheapRef` resolves its provider-owned theap through it,
    /// and because it is the one raw handle a caller needs for a declaration
    /// this module does not wrap. It is upstream's own `mi_heap_t *`, not a copy
    /// of it.
    pub fn handle(self: *const Heap) *c.mi_heap_t {
        return self.raw orelse std.debug.panic(
            "mimalloc: this Heap was used after deinit or destroy; there is no " ++
                "heap to allocate from",
            .{},
        );
    }

    /// Whether this heap is still open.
    pub fn isOpen(self: *const Heap) bool {
        return self.raw != null;
    }

    /// `mi_heap_main` (`include/mimalloc.h:248`): the process's main heap.
    ///
    /// A borrowed reference to a heap this package does not own and must not
    /// close; `mi_heap_delete` and `mi_heap_destroy` both refuse it
    /// (`src/heap.c:239-242`, `:263-266`).
    pub fn main() MainHeapRef {
        return .{ .raw = c.mi_heap_main() };
    }

    /// `mi_heap_of` (`include/mimalloc.h:249`): the heap that owns `block`.
    ///
    /// Null when the pointer is not in any heap - which includes every pointer
    /// some other allocator returned. That is the one honest way to ask the
    /// question, because upstream's own `mi_heap_of` is what answers it.
    pub fn of(block: *const anyopaque) ?HeapRef {
        return .{ .raw = c.mi_heap_of(block) };
    }

    /// `mi_heap_contains` (`include/mimalloc.h:250`): whether this heap owns
    /// `block`. A null `block` is checked as the main heap
    /// (`src/heap.c:281-284`), so pass a pointer.
    pub fn contains(self: *const Heap, block: *const anyopaque) bool {
        return c.mi_heap_contains(self.handle(), block);
    }

    /// `mi_heap_collect` (`include/mimalloc.h:246`, `src/theap.c:166-169`).
    ///
    /// Upstream's own comment says what it does not do: "cannot really collect
    /// a heap, just a theap". It releases free pages of the heap's thread-local
    /// heap; blocks that are still live are untouched.
    pub fn collect(self: *const Heap, force: bool) void {
        c.mi_heap_collect(self.handle(), force);
    }

    /// `mi_heap_set_numa_affinity` (`include/mimalloc.h:245`): associate this
    /// heap with a NUMA node.
    pub fn setNumaAffinity(self: *const Heap, numa_node: c_int) void {
        c.mi_heap_set_numa_affinity(self.handle(), numa_node);
    }

    /// `mi_heap_malloc` (`include/mimalloc.h:253`): `size` bytes from this heap.
    pub fn malloc(self: *const Heap, size: usize) Error!*anyopaque {
        return c.mi_heap_malloc(self.handle(), size) orelse error.OutOfMemory;
    }

    /// `mi_heap_zalloc` (`include/mimalloc.h:254`): as `malloc`, zeroed.
    pub fn zalloc(self: *const Heap, size: usize) Error!*anyopaque {
        return c.mi_heap_zalloc(self.handle(), size) orelse error.OutOfMemory;
    }

    /// `mi_heap_calloc` (`include/mimalloc.h:255`): `count * size` zeroed bytes
    /// from this heap.
    pub fn calloc(self: *const Heap, count: usize, size: usize) Error!*anyopaque {
        return c.mi_heap_calloc(self.handle(), count, size) orelse error.OutOfMemory;
    }

    /// `mi_heap_mallocn` (`include/mimalloc.h:256`): `count * size` bytes from
    /// this heap, not zeroed.
    pub fn mallocn(self: *const Heap, count: usize, size: usize) Error!*anyopaque {
        return c.mi_heap_mallocn(self.handle(), count, size) orelse error.OutOfMemory;
    }

    /// `mi_heap_malloc_small` (`include/mimalloc.h:257`).
    pub fn mallocSmall(self: *const Heap, size: usize) Error!*anyopaque {
        return c.mi_heap_malloc_small(self.handle(), size) orelse error.OutOfMemory;
    }

    /// `mi_heap_zalloc_small` (`include/mimalloc.h:258`).
    pub fn zallocSmall(self: *const Heap, size: usize) Error!*anyopaque {
        return c.mi_heap_zalloc_small(self.handle(), size) orelse error.OutOfMemory;
    }

    /// `mi_heap_malloc_aligned` (`include/mimalloc.h:268`): `(size, alignment)`,
    /// as everywhere else in this module.
    pub fn mallocAligned(self: *const Heap, size: usize, alignment: usize) Error!*anyopaque {
        _ = try checkedAlignment(alignment);
        return c.mi_heap_malloc_aligned(self.handle(), size, alignment) orelse error.OutOfMemory;
    }

    /// `mi_heap_zalloc_aligned` (`include/mimalloc.h:270`).
    pub fn zallocAligned(self: *const Heap, size: usize, alignment: usize) Error!*anyopaque {
        _ = try checkedAlignment(alignment);
        return c.mi_heap_zalloc_aligned(self.handle(), size, alignment) orelse error.OutOfMemory;
    }

    /// `mi_heap_malloc_aligned_at` (`include/mimalloc.h:269`).
    pub fn mallocAlignedAt(self: *const Heap, size: usize, alignment: usize, offset: usize) Error!*anyopaque {
        _ = try checkedAlignment(alignment);
        return c.mi_heap_malloc_aligned_at(self.handle(), size, alignment, offset) orelse error.OutOfMemory;
    }

    /// `mi_heap_zalloc_aligned_at` (`include/mimalloc.h:271`).
    pub fn zallocAlignedAt(self: *const Heap, size: usize, alignment: usize, offset: usize) Error!*anyopaque {
        _ = try checkedAlignment(alignment);
        return c.mi_heap_zalloc_aligned_at(self.handle(), size, alignment, offset) orelse error.OutOfMemory;
    }

    /// `mi_heap_realloc` (`include/mimalloc.h:260`).
    ///
    /// Upstream routes it through the heap's thread-local heap
    /// (`src/alloc.c:587-589`), so `block` must belong to this heap or to one
    /// whose arena it shares. On failure `block` survives, as for `realloc`.
    pub fn realloc(self: *const Heap, block: ?*anyopaque, new_size: usize) Error!*anyopaque {
        return c.mi_heap_realloc(self.handle(), block, new_size) orelse error.OutOfMemory;
    }

    /// `mi_heap_reallocn` (`include/mimalloc.h:261`): `count * size`, not zeroed.
    pub fn reallocn(self: *const Heap, block: ?*anyopaque, count: usize, size: usize) Error!*anyopaque {
        return c.mi_heap_reallocn(self.handle(), block, count, size) orelse error.OutOfMemory;
    }

    /// `mi_heap_reallocf` (`include/mimalloc.h:262`): as `realloc`, but frees
    /// `block` when the call fails (`src/alloc.c:596-600`).
    pub fn reallocFree(self: *const Heap, block: ?*anyopaque, new_size: usize) Error!*anyopaque {
        return c.mi_heap_reallocf(self.handle(), block, new_size) orelse error.OutOfMemory;
    }

    /// `mi_heap_rezalloc` (`include/mimalloc.h:293`): `realloc` with the growth
    /// zeroed, on a block that was zeroed to begin with.
    pub fn rezalloc(self: *const Heap, block: ?*anyopaque, new_size: usize) Error!*anyopaque {
        return c.mi_heap_rezalloc(self.handle(), block, new_size) orelse error.OutOfMemory;
    }

    /// `mi_heap_recalloc` (`include/mimalloc.h:294`).
    pub fn recalloc(self: *const Heap, block: ?*anyopaque, newcount: usize, size: usize) Error!*anyopaque {
        return c.mi_heap_recalloc(self.handle(), block, newcount, size) orelse error.OutOfMemory;
    }

    /// `mi_heap_rezalloc_aligned` (`include/mimalloc.h:296`).
    pub fn rezallocAligned(self: *const Heap, block: ?*anyopaque, new_size: usize, alignment: usize) Error!*anyopaque {
        _ = try checkedAlignment(alignment);
        return c.mi_heap_rezalloc_aligned(self.handle(), block, new_size, alignment) orelse error.OutOfMemory;
    }

    /// `mi_heap_recalloc_aligned` (`include/mimalloc.h:298`).
    pub fn recallocAligned(self: *const Heap, block: ?*anyopaque, newcount: usize, size: usize, alignment: usize) Error!*anyopaque {
        _ = try checkedAlignment(alignment);
        return c.mi_heap_recalloc_aligned(self.handle(), block, newcount, size, alignment) orelse error.OutOfMemory;
    }

    /// `mi_heap_strdup` (`include/mimalloc.h:264`): a copy of `s` allocated from
    /// this heap. Owned by mimalloc; return it with `free`.
    pub fn strdup(self: *const Heap, s: [:0]const u8) Error![*:0]u8 {
        return c.mi_heap_strdup(self.handle(), s.ptr) orelse error.OutOfMemory;
    }

    /// `mi_heap_strndup` (`include/mimalloc.h:265`): at most `n` bytes of `s`.
    /// Owned by mimalloc; return it with `free`.
    pub fn strndup(self: *const Heap, s: [:0]const u8, n: usize) Error![*:0]u8 {
        return c.mi_heap_strndup(self.handle(), s.ptr, n) orelse error.OutOfMemory;
    }

    /// `mi_heap_realpath` (`include/mimalloc.h:266`) into a caller's buffer.
    ///
    /// `buffer` must have room for a `PATH_MAX` path, for the reason
    /// `realpathInto` gives. The result is in `buffer` and is the caller's.
    pub fn realpathInto(self: *const Heap, fname: [:0]const u8, buffer: []u8) ?[]u8 {
        if (c.mi_heap_realpath(self.handle(), fname.ptr, @ptrCast(buffer.ptr)) == null) return null;
        return buffer[0..std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
    }

    /// `mi_heap_visit_blocks` (`include/mimalloc.h:320`, `src/arena.c:2538-2540`).
    ///
    /// `visitor` is called once per page, and once per block within a page when
    /// `visit_blocks` is true. The answer is `false` when the visitor asked to
    /// stop - `src/arena.c:2503` short-circuits every remaining page on it - and
    /// `false` for a null visitor (`src/arena.c:2497-2498`), which Zig cannot
    /// express here.
    ///
    /// Upstream's own comment above `src/arena.c:2501-2502` is that this assumes
    /// the calling thread is the only one running with this heap.
    pub fn visitBlocks(self: *const Heap, visit_blocks: bool, visitor: BlockVisitFn, arg: ?*anyopaque) bool {
        return c.mi_heap_visit_blocks(self.handle(), visit_blocks, visitor, arg);
    }

    /// `mi_heap_visit_abandoned_blocks` (`include/mimalloc.h:321`,
    /// `src/arena.c:2542-2544`): only the pages abandoned by a terminated
    /// thread. The answer means the same as `visitBlocks`.
    pub fn visitAbandonedBlocks(self: *const Heap, visit_blocks: bool, visitor: BlockVisitFn, arg: ?*anyopaque) bool {
        return c.mi_heap_visit_abandoned_blocks(self.handle(), visit_blocks, visitor, arg);
    }

    /// `mi_unsafe_heap_page_is_under_utilized` (`include/mimalloc.h:422`,
    /// `src/heap.c:293`).
    ///
    /// The name says what it means: upstream's comment at `src/heap.c:290` is
    /// "unsafe in general as it assumes we are the only thread accessing the
    /// page". It is for a platform-specific reclamation policy, and it is
    /// exposed because it is in the public header, not because it is safe to
    /// call while other threads run.
    pub fn unsafePageIsUnderUtilized(self: *const Heap, block: ?*anyopaque, perc_threshold: usize) bool {
        return c.mi_unsafe_heap_page_is_under_utilized(self.handle(), block, perc_threshold);
    }

    /// `mi_theap_collect` on this heap's thread-local heap, which is what
    /// `mi_heap_collect` itself is (`src/theap.c:166-169`).
    pub fn theap(self: *const Heap) TheapRef {
        return .{ .heap = self };
    }
};

/// A borrowed heap reference: something that owns no heap and must not close
/// one.
///
/// This is the type `Heap.of` and `Heap.main` answer with, and the deliberate
/// contrast with `Heap`: it has no `deinit` and no `destroy`, because the heap
/// behind it belongs to somebody else.
pub const HeapRef = struct {
    raw: ?*c.mi_heap_t,

    /// Whether the heap is still known to exist. Upstream never returns null
    /// from `mi_heap_main`, so this is true except for a heap that was closed
    /// behind the reference's back.
    pub fn isOpen(self: HeapRef) bool {
        return self.raw != null;
    }

    /// `mi_heap_contains` on a borrowed heap.
    pub fn contains(self: HeapRef, block: *const anyopaque) bool {
        return c.mi_heap_contains(self.raw, block);
    }

    /// `mi_heap_malloc` on a borrowed heap.
    pub fn malloc(self: HeapRef, size: usize) Error!*anyopaque {
        return c.mi_heap_malloc(self.raw, size) orelse error.OutOfMemory;
    }

    /// `mi_heap_zalloc` on a borrowed heap.
    pub fn zalloc(self: HeapRef, size: usize) Error!*anyopaque {
        return c.mi_heap_zalloc(self.raw, size) orelse error.OutOfMemory;
    }
};

/// The main heap, borrowed. `Heap.main` answers this and there is deliberately
/// no way to close it.
pub const MainHeapRef = struct {
    raw: ?*c.mi_heap_t,

    /// `mi_heap_contains` on the main heap.
    pub fn contains(self: MainHeapRef, block: *const anyopaque) bool {
        return c.mi_heap_contains(self.raw, block);
    }

    /// `mi_heap_malloc` on the main heap.
    pub fn malloc(self: MainHeapRef, size: usize) Error!*anyopaque {
        return c.mi_heap_malloc(self.raw, size) orelse error.OutOfMemory;
    }

    /// `mi_heap_zalloc` on the main heap.
    pub fn zalloc(self: MainHeapRef, size: usize) Error!*anyopaque {
        return c.mi_heap_zalloc(self.raw, size) orelse error.OutOfMemory;
    }
};

// ---------------------------------------------------------------------------
// Thread-local heaps ("theaps")
//
// `include/mimalloc.h:371-397`. A theap is a thread's own fast path onto a
// heap: it can only allocate from the thread that created it, and it is
// provider-owned. There is deliberately no `deinit` on any type here.
// ---------------------------------------------------------------------------

/// A theap, borrowed. There is no way to create or destroy one: `mi_heap_theap`
/// (`include/mimalloc.h:384`) is the only way to reach it, and the provider owns
/// it for the life of the heap.
pub const TheapRef = struct {
    /// The heap this theap belongs to. It is held as a reference rather than a
    /// raw pointer so that closing the heap is the only way to invalidate it,
    /// and that is visible at the call site.
    heap: *const Heap,

    /// The provider's own theap pointer.
    ///
    /// Resolved per call, because `mi_heap_theap` (`include/mimalloc.h:384`) is
    /// not a field access and a theap is created on first use. Public because
    /// `theapSetDefault` needs it: making a theap the thread's default requires
    /// the pointer, and there is no other route to it.
    pub fn handle(self: TheapRef) ?*c.mi_theap_t {
        return c.mi_heap_theap(self.heap.handle());
    }

    /// `mi_theap_malloc` (`include/mimalloc.h:389`): `size` bytes from this
    /// thread's theap.
    pub fn malloc(self: TheapRef, size: usize) Error!*anyopaque {
        return c.mi_theap_malloc(self.handle(), size) orelse error.OutOfMemory;
    }

    /// `mi_theap_zalloc` (`include/mimalloc.h:390`): as `malloc`, zeroed.
    pub fn zalloc(self: TheapRef, size: usize) Error!*anyopaque {
        return c.mi_theap_zalloc(self.handle(), size) orelse error.OutOfMemory;
    }

    /// `mi_theap_calloc` (`include/mimalloc.h:391`): `count * size` zeroed bytes.
    pub fn calloc(self: TheapRef, count: usize, size: usize) Error!*anyopaque {
        return c.mi_theap_calloc(self.handle(), count, size) orelse error.OutOfMemory;
    }

    /// `mi_theap_malloc_small` (`include/mimalloc.h:392`).
    pub fn mallocSmall(self: TheapRef, size: usize) Error!*anyopaque {
        return c.mi_theap_malloc_small(self.handle(), size) orelse error.OutOfMemory;
    }

    /// `mi_theap_zalloc_small` (`include/mimalloc.h:393`).
    pub fn zallocSmall(self: TheapRef, size: usize) Error!*anyopaque {
        return c.mi_theap_zalloc_small(self.handle(), size) orelse error.OutOfMemory;
    }

    /// `mi_theap_malloc_aligned` (`include/mimalloc.h:394`).
    pub fn mallocAligned(self: TheapRef, size: usize, alignment: usize) Error!*anyopaque {
        _ = try checkedAlignment(alignment);
        return c.mi_theap_malloc_aligned(self.handle(), size, alignment) orelse error.OutOfMemory;
    }

    /// `mi_theap_zalloc_aligned` (`include/mimalloc.h:395`).
    pub fn zallocAligned(self: TheapRef, size: usize, alignment: usize) Error!*anyopaque {
        _ = try checkedAlignment(alignment);
        return c.mi_theap_zalloc_aligned(self.handle(), size, alignment) orelse error.OutOfMemory;
    }

    /// `mi_theap_realloc` (`include/mimalloc.h:396`).
    pub fn realloc(self: TheapRef, block: ?*anyopaque, new_size: usize) Error!*anyopaque {
        return c.mi_theap_realloc(self.handle(), block, new_size) orelse error.OutOfMemory;
    }

    /// `mi_theap_rezalloc` (`include/mimalloc.h:397`): `realloc` with the growth
    /// zeroed, on a block that was zeroed to begin with.
    pub fn rezalloc(self: TheapRef, block: ?*anyopaque, new_size: usize) Error!*anyopaque {
        return c.mi_theap_rezalloc(self.handle(), block, new_size) orelse error.OutOfMemory;
    }

    /// `mi_theap_collect` (`include/mimalloc.h:387`): release this thread's free
    /// pages. Live blocks are untouched.
    pub fn collect(self: TheapRef, force: bool) void {
        c.mi_theap_collect(self.handle(), force);
    }

    /// `mi_theap_guarded_set_sample_rate` (`include/mimalloc.h:408`).
    ///
    /// Experimental, and marked as such at `include/mimalloc.h:402-407`: it
    /// puts a guard page after a sampled fraction of this theap's objects, so a
    /// buffer overrun faults instead of corrupting the next object. A rate of 0
    /// disables them and 1 guards every object.
    pub fn guardedSetSampleRate(self: TheapRef, sample_rate: usize, seed: usize) void {
        c.mi_theap_guarded_set_sample_rate(self.handle(), sample_rate, seed);
    }

    /// `mi_theap_guarded_set_size_bound` (`include/mimalloc.h:409`): only objects
    /// whose rounded size is within `min .. max` are eligible for a guard page.
    pub fn guardedSetSizeBound(self: TheapRef, min: usize, max: usize) void {
        c.mi_theap_guarded_set_size_bound(self.handle(), min, max);
    }
};

/// `mi_theap_set_default` (`include/mimalloc.h:385`): make this theap the one
/// plain `mi_malloc` and friends allocate from on this thread.
///
/// Returns the previous default, or null when there was none. Passing null is
/// how the default is cleared, and upstream accepts it
/// (`include/mimalloc.h:385`).
pub fn theapSetDefault(theap: ?*c.mi_theap_t) ?*c.mi_theap_t {
    return c.mi_theap_set_default(theap);
}

/// `mi_theap_get_default` (`include/mimalloc.h:386`): the thread's current
/// default theap.
pub fn theapDefault() ?*c.mi_theap_t {
    return c.mi_theap_get_default();
}

// ---------------------------------------------------------------------------
// Arenas
//
// `include/mimalloc.h:324-352`. An arena is a large region of OS memory,
// reserved or handed in by the user, out of which pages - and therefore blocks -
// are carved. An arena id is an opaque handle: it is created by one of the
// `*_ex` reservation calls below and is meaningful only to the process that
// created it.
// ---------------------------------------------------------------------------

/// An arena handle: upstream's own `mi_arena_id_t`, which is `void*`
/// (`include/mimalloc.h:343`). Not restated, so the handle this module passes is
/// the one the header declares.
pub const ArenaId = c.mi_arena_id_t;

/// The reserved region an arena owns, as `mi_arena_area` reports it.
pub const ArenaArea = struct {
    /// The first byte of the arena's region. Provider-owned memory that must not
    /// be freed: an arena is released by the provider, not by a caller.
    start: [*]u8,
    /// The arena's total size in bytes (`src/arena.c:193`).
    size: usize,
};

/// `mi_arena_area` (`include/mimalloc.h:344`, `src/arena.c:187-196`): the
/// region an arena reserves.
///
/// Null for an unknown arena, and `src/arena.c:188` zeroes the size before
/// looking anything up, so nothing stale is reported. The memory is the
/// provider's: do not free it, and do not write to it - it is an arena, and the
/// allocator places its own metadata at the start of each chunk.
pub fn arenaArea(arena_id: ArenaId) ?ArenaArea {
    var size: usize = 0;
    const start = c.mi_arena_area(arena_id, &size) orelse return null;
    return .{ .start = @ptrCast(start), .size = size };
}

/// `mi_arena_min_alignment` (`include/mimalloc.h:339`, `src/arena.c:89-91`): the
/// alignment every arena's region has.
pub fn arenaMinAlignment() usize {
    return c.mi_arena_min_alignment();
}

/// `mi_arena_min_size` (`include/mimalloc.h:340`, `src/arena.c:93-95`): the
/// smallest arena a reservation will produce.
pub fn arenaMinSize() usize {
    return c.mi_arena_min_size();
}

/// `mi_arena_max_object_size` (`include/mimalloc.h:341`, `src/arena.c:116-124`):
/// the largest single object an arena will hold.
///
/// This is derived from the `arena_max_object_size` **option** at the moment it
/// is asked (`src/arena.c:117`), so setting that option changes it. It is a
/// policy answer, not a constant.
pub fn arenaMaxObjectSize() usize {
    return c.mi_arena_max_object_size();
}

/// `mi_arena_contains` (`include/mimalloc.h:348`): whether `block` lies inside
/// this arena's region.
pub fn arenaContains(arena_id: ArenaId, block: *const anyopaque) bool {
    return c.mi_arena_contains(arena_id, block);
}

/// `mi_reserve_os_memory` (`include/mimalloc.h:334`, `src/arena.c:1944-1946`):
/// reserve `size` bytes of OS memory for the allocator to use.
///
/// The answer is an errno: 0 on success, and on failure whatever the platform
/// reported. This is not folded into `Error`, because it is a system call's
/// status rather than a condition this file checks.
pub fn reserveOsMemory(size: usize, commit: bool, allow_large: bool) c_int {
    return c.mi_reserve_os_memory(size, commit, allow_large);
}

/// `mi_reserve_os_memory_ex` (`include/mimalloc.h:346`): as `reserveOsMemory`,
/// and additionally writes an arena id for the reservation and can make it
/// exclusive - one no other arena shares.
pub fn reserveOsMemoryEx(size: usize, commit: bool, allow_large: bool, exclusive: bool, arena_id: *ArenaId) c_int {
    return c.mi_reserve_os_memory_ex(size, commit, allow_large, exclusive, arena_id);
}

/// `mi_reserve_huge_os_pages_at` (`include/mimalloc.h:332`): reserve `pages`
/// 1 GiB pages at one NUMA node.
pub fn reserveHugeOsPagesAt(pages: usize, numa_node: c_int, timeout_msecs: usize) c_int {
    return c.mi_reserve_huge_os_pages_at(pages, numa_node, timeout_msecs);
}

/// `mi_reserve_huge_os_pages_at_ex` (`include/mimalloc.h:345`): as above, and
/// additionally writes an arena id and can make it exclusive.
pub fn reserveHugeOsPagesAtEx(pages: usize, numa_node: c_int, timeout_msecs: usize, exclusive: bool, arena_id: *ArenaId) c_int {
    return c.mi_reserve_huge_os_pages_at_ex(pages, numa_node, timeout_msecs, exclusive, arena_id);
}

/// `mi_reserve_huge_os_pages_interleave` (`include/mimalloc.h:331`): reserve
/// `pages` 1 GiB pages spread across `numa_nodes` nodes.
pub fn reserveHugeOsPagesInterleave(pages: usize, numa_nodes: usize, timeout_msecs: usize) c_int {
    return c.mi_reserve_huge_os_pages_interleave(pages, numa_nodes, timeout_msecs);
}

/// `mi_reserve_huge_os_pages` (`include/mimalloc.h:434`): the deprecated
/// spelling, kept by upstream with a `double` timeout and a count written back.
///
/// Deprecated at `include/mimalloc.h:434`; `reserveHugeOsPagesAtEx` is what to
/// write instead.
pub fn reserveHugeOsPages(pages: usize, max_secs: f64, pages_reserved: *usize) c_int {
    return c.mi_reserve_huge_os_pages(pages, max_secs, pages_reserved);
}

/// `mi_manage_os_memory` (`include/mimalloc.h:335`): hand a region the caller
/// already owns to the allocator.
///
/// `start` and `size` must be page aligned and page sized, which
/// `include/mimalloc/prim.h:18-23` states is a precondition of every primitive
/// the allocator builds on. The memory is not freed when the process exits by
/// default; that is what the `destroy_on_exit` option governs
/// (`include/mimalloc.h:473`).
pub fn manageOsMemory(start: ?*anyopaque, size: usize, is_committed: bool, is_pinned: bool, is_zero: bool, numa_node: c_int) bool {
    return c.mi_manage_os_memory(start, size, is_committed, is_pinned, is_zero, numa_node);
}

/// `mi_manage_os_memory_ex` (`include/mimalloc.h:347`): as `manageOsMemory`, and
/// additionally writes an arena id and can make it exclusive.
pub fn manageOsMemoryEx(start: ?*anyopaque, size: usize, is_committed: bool, is_pinned: bool, is_zero: bool, numa_node: c_int, exclusive: bool, arena_id: *ArenaId) bool {
    return c.mi_manage_os_memory_ex(start, size, is_committed, is_pinned, is_zero, numa_node, exclusive, arena_id);
}

/// `mi_manage_memory` (`include/mimalloc.h:413`): `manageOsMemory` with a
/// callback for the allocator to ask for memory to be committed or reset.
///
/// Upstream's own comment at `include/mimalloc.h:411` is "very experimental",
/// and the callback is called on the allocator's own thread with the allocator's
/// own locking in place; a callback that blocks on another thread that
/// allocates deadlocks. `is_zero` is an out-parameter the callback must write.
pub fn manageMemory(start: ?*anyopaque, size: usize, is_committed: bool, is_pinned: bool, is_zero: bool, numa_node: c_int, exclusive: bool, commit_fun: ?CommitFn, commit_fun_arg: ?*anyopaque, arena_id: *ArenaId) bool {
    return c.mi_manage_memory(start, size, is_committed, is_pinned, is_zero, numa_node, exclusive, commit_fun, commit_fun_arg, arena_id);
}

/// `mi_debug_show_arenas` (`include/mimalloc.h:337`): print arena debug
/// information through the registered output.
pub fn debugShowArenas() void {
    c.mi_debug_show_arenas();
}

/// `mi_arenas_print` (`include/mimalloc.h:338`): print the arena summary.
pub fn arenasPrint() void {
    c.mi_arenas_print();
}

// ---------------------------------------------------------------------------
// Sub-processes
//
// `include/mimalloc.h:354-368`. A sub-process is a set of arenas that stay
// separated with no reclamation between them - upstream's use case is several
// interpreters in one process. It is not an OS process and does not isolate
// anything a fork would.
// ---------------------------------------------------------------------------

/// A sub-process id. Upstream's own struct (`include/mimalloc.h:360`), passed by
/// value, so this is one nominal type on both routes.
pub const Subproc = struct {
    raw: c.mi_subproc_id_t,

    /// `mi_subproc_main` (`include/mimalloc.h:361`, `src/subproc.c:127-129`):
    /// the sub-process this process started in.
    pub fn main() Subproc {
        return .{ .raw = c.mi_subproc_main() };
    }

    /// `mi_subproc_current` (`include/mimalloc.h:362`, `src/subproc.c:131-133`):
    /// the sub-process the calling thread is in.
    pub fn current() Subproc {
        return .{ .raw = c.mi_subproc_current() };
    }

    /// `mi_subproc_new` (`include/mimalloc.h:363`): a fresh, empty sub-process.
    pub fn create() Subproc {
        return .{ .raw = c.mi_subproc_new() };
    }

    /// `mi_subproc_destroy` (`include/mimalloc.h:364`): release this
    /// sub-process. Blocks still allocated from it are not usable afterwards.
    pub fn destroy(self: Subproc) void {
        c.mi_subproc_destroy(self.raw);
    }

    /// `mi_subproc_add_current_thread` (`include/mimalloc.h:365`).
    ///
    /// Upstream's comment is precise about when this is called: "right after a
    /// thread is created (and no allocation has taken place yet)". Calling it
    /// later leaves whatever the thread already allocated where it was.
    pub fn addCurrentThread(self: Subproc) void {
        c.mi_subproc_add_current_thread(self.raw);
    }

    /// `mi_subproc_visit_heaps` (`include/mimalloc.h:368`): call `visitor` for
    /// each heap in this sub-process.
    ///
    /// The answer is `false` when the visitor asked to stop. Every heap handed to
    /// the visitor is borrowed: `Heap` is not one of them, because the visitor
    /// signature carries a raw pointer and closing a heap from inside this walk
    /// would be freeing the thing being walked.
    pub fn visitHeaps(self: Subproc, visitor: HeapVisitFn, arg: ?*anyopaque) bool {
        return c.mi_subproc_visit_heaps(self.raw, visitor, arg);
    }
};

// ---------------------------------------------------------------------------
// Options
//
// `include/mimalloc.h:444-519`. Every option is process-wide and most are read
// once, at first use: upstream's own note at `src/init.c` is that changing an
// option after the first allocation has limited effect. That is why the setters
// here say nothing about ordering - upstream does not promise one - and why
// `optionSetDefault` exists separately from `optionSet`.
//
// An option can also be set from the environment as `MIMALLOC_<OPTION>`, read by
// upstream itself (`src/options.c`), before any of this is called.
// ---------------------------------------------------------------------------

/// One of mimalloc's runtime options.
///
/// The tag type is upstream's own `mi_option_e`
/// (`include/mimalloc.h:448-506`), so this is one nominal type with the header
/// rather than a copy of it, and no value is restated: every tag below is the
/// translated enumerator.
///
/// Three names from that enumerator list are deliberately absent:
/// `_mi_option_last`, which is upstream's own end marker rather than an option,
/// and the five legacy aliases at `include/mimalloc.h:501-505`
/// (`large_os_pages`, `eager_region_commit`, `reset_decommits`, `reset_delay`,
/// `limit_os_alloc`), which repeat the value of an option that is already here
/// under its current name. A Zig enum cannot carry two fields with one value.
pub const Option = enum(c.mi_option_e) {
    /// `mi_option_show_errors`: print error messages.
    show_errors = c.mi_option_show_errors,
    /// `mi_option_show_stats`: print statistics on termination.
    show_stats = c.mi_option_show_stats,
    /// `mi_option_verbose`: print verbose messages.
    verbose = c.mi_option_verbose,
    /// `mi_option_arena_eager_commit`: commit arena memory eagerly. 2 means
    /// only on an overcommit system.
    arena_eager_commit = c.mi_option_arena_eager_commit,
    /// `mi_option_purge_decommits`: 1 decommits a purge, 0 resets instead.
    purge_decommits = c.mi_option_purge_decommits,
    /// `mi_option_allow_large_os_pages`: allow 2 or 4 MiB OS pages.
    allow_large_os_pages = c.mi_option_allow_large_os_pages,
    /// `mi_option_reserve_huge_os_pages`: reserve N 1 GiB pages at startup.
    reserve_huge_os_pages = c.mi_option_reserve_huge_os_pages,
    /// `mi_option_reserve_huge_os_pages_at`: reserve them at one NUMA node.
    reserve_huge_os_pages_at = c.mi_option_reserve_huge_os_pages_at,
    /// `mi_option_reserve_os_memory`: reserve this much OS memory at startup.
    /// Read it with `optionGetSize`, which converts the internal KiB.
    reserve_os_memory = c.mi_option_reserve_os_memory,
    /// `mi_option_purge_delay`: delay a purge by N milliseconds; -1 never
    /// purges, 0 purges immediately.
    purge_delay = c.mi_option_purge_delay,
    /// `mi_option_use_numa_nodes`: 0 uses every node, N uses at most N.
    use_numa_nodes = c.mi_option_use_numa_nodes,
    /// `mi_option_disallow_os_alloc`: take no OS memory for allocation.
    disallow_os_alloc = c.mi_option_disallow_os_alloc,
    /// `mi_option_os_tag`: the tag used for OS logging.
    os_tag = c.mi_option_os_tag,
    /// `mi_option_max_errors`: issue at most N error messages.
    max_errors = c.mi_option_max_errors,
    /// `mi_option_max_warnings`: issue at most N warning messages.
    max_warnings = c.mi_option_max_warnings,
    /// `mi_option_destroy_on_exit`: release all memory on exit. Upstream's own
    /// comment at `include/mimalloc.h:473` calls this "sometimes used for
    /// dynamic unloading but can be unsafe".
    destroy_on_exit = c.mi_option_destroy_on_exit,
    /// `mi_option_arena_reserve`: the initial arena reservation size. Read it
    /// with `optionGetSize`.
    arena_reserve = c.mi_option_arena_reserve,
    /// `mi_option_arena_purge_mult`: the multiplier on `purge_delay` for
    /// arenas.
    arena_purge_mult = c.mi_option_arena_purge_mult,
    /// `mi_option_disallow_arena_alloc`: take no arena memory for allocation.
    disallow_arena_alloc = c.mi_option_disallow_arena_alloc,
    /// `mi_option_retry_on_oom`: retry out-of-memory for N milliseconds; 0
    /// disables the retry. Windows only, per `include/mimalloc.h:478`.
    retry_on_oom = c.mi_option_retry_on_oom,
    /// `mi_option_guarded_min`: smallest rounded object size eligible for a
    /// guard page, in a `MI_GUARDED` build.
    guarded_min = c.mi_option_guarded_min,
    /// `mi_option_guarded_max`: largest, likewise.
    guarded_max = c.mi_option_guarded_max,
    /// `mi_option_guarded_precise`: place a guarded block immediately before its
    /// guard page rather than at any offset that satisfies the alignment.
    guarded_precise = c.mi_option_guarded_precise,
    /// `mi_option_guarded_sample_rate`: guard one object in N within the size
    /// bound.
    guarded_sample_rate = c.mi_option_guarded_sample_rate,
    /// `mi_option_guarded_sample_seed`: fix the sample for a reproducible run.
    guarded_sample_seed = c.mi_option_guarded_sample_seed,
    /// `mi_option_generic_collect`: collect theaps every N generic allocations.
    generic_collect = c.mi_option_generic_collect,
    /// `mi_option_page_reclaim_on_free`: -1 never, 0 only from the current
    /// theap, 1 always.
    page_reclaim_on_free = c.mi_option_page_reclaim_on_free,
    /// `mi_option_page_full_retain`: keep N full pages per size class.
    page_full_retain = c.mi_option_page_full_retain,
    /// `mi_option_page_max_candidates`: candidate pages to consider.
    page_max_candidates = c.mi_option_page_max_candidates,
    /// `mi_option_max_vabits`: the largest user virtual-address width to
    /// consider.
    max_vabits = c.mi_option_max_vabits,
    /// `mi_option_pagemap_commit`: commit the whole page map, to catch an
    /// invalid pointer inside it.
    pagemap_commit = c.mi_option_pagemap_commit,
    /// `mi_option_page_commit_on_demand`: commit page memory on demand.
    page_commit_on_demand = c.mi_option_page_commit_on_demand,
    /// `mi_option_page_max_reclaim`: do not reclaim a page of the originating
    /// theap once N of that size class are already owned.
    page_max_reclaim = c.mi_option_page_max_reclaim,
    /// `mi_option_page_cross_thread_max_reclaim`: the same limit across
    /// threads.
    page_cross_thread_max_reclaim = c.mi_option_page_cross_thread_max_reclaim,
    /// `mi_option_allow_thp`: allow transparent huge pages. 0 disables them for
    /// the process.
    allow_thp = c.mi_option_allow_thp,
    /// `mi_option_minimal_purge_size`: the smallest purge, in KiB.
    minimal_purge_size = c.mi_option_minimal_purge_size,
    /// `mi_option_arena_max_object_size`: the largest object an arena holds, in
    /// KiB. Read it with `optionGetSize`; `arenaMaxObjectSize` derives from it.
    arena_max_object_size = c.mi_option_arena_max_object_size,
    /// `mi_option_arena_is_numa_local`: experimental; associate a local NUMA
    /// node with an initial arena allocation.
    arena_is_numa_local = c.mi_option_arena_is_numa_local,
    /// `mi_option_collect_merges_stats`: merge a theap's statistics into its
    /// parent heap on every collection.
    collect_merges_stats = c.mi_option_collect_merges_stats,
};

/// `mi_option_is_enabled` (`include/mimalloc.h:509`): whether this option is on.
pub fn optionIsEnabled(option: Option) bool {
    return c.mi_option_is_enabled(@intFromEnum(option));
}

/// `mi_option_enable` (`include/mimalloc.h:510`).
pub fn optionEnable(option: Option) void {
    c.mi_option_enable(@intFromEnum(option));
}

/// `mi_option_disable` (`include/mimalloc.h:511`).
pub fn optionDisable(option: Option) void {
    c.mi_option_disable(@intFromEnum(option));
}

/// `mi_option_set_enabled` (`include/mimalloc.h:512`): enable or disable.
pub fn optionSetEnabled(option: Option, enable: bool) void {
    c.mi_option_set_enabled(@intFromEnum(option), enable);
}

/// `mi_option_set_enabled_default` (`include/mimalloc.h:513`): change the
/// built-in default rather than the current value.
pub fn optionSetEnabledDefault(option: Option, enable: bool) void {
    c.mi_option_set_enabled_default(@intFromEnum(option), enable);
}

/// `mi_option_get` (`include/mimalloc.h:515`): this option's current value.
///
/// A `long` upstream and a `c_long` here, which is 32-bit on
/// `x86_64-windows-gnu` and 64-bit elsewhere. The `c_long` is what keeps that
/// correct rather than a hard-coded `i64`.
pub fn optionGet(option: Option) c_long {
    return c.mi_option_get(@intFromEnum(option));
}

/// `mi_option_get_clamp` (`include/mimalloc.h:516`): the value, narrowed into
/// `min .. max`. An option that is not a number clamps to `min`.
pub fn optionGetClamp(option: Option, min: c_long, max: c_long) c_long {
    return c.mi_option_get_clamp(@intFromEnum(option), min, max);
}

/// `mi_option_get_size` (`include/mimalloc.h:517`): the value of a size-valued
/// option, in bytes.
///
/// This is not `optionGet` with a different type. Upstream stores the
/// size-valued options internally in KiB and converts here
/// (`include/mimalloc.h:460`, `:474`), so reading one with `optionGet` gives a
/// number 1024 times too small.
pub fn optionGetSize(option: Option) usize {
    return c.mi_option_get_size(@intFromEnum(option));
}

/// `mi_option_set` (`include/migalloc.h:518`): set this option's value.
pub fn optionSet(option: Option, value: c_long) void {
    c.mi_option_set(@intFromEnum(option), value);
}

/// `mi_option_set_default` (`include/mimalloc.h:519`): set the built-in default
/// rather than the current value.
pub fn optionSetDefault(option: Option, value: c_long) void {
    c.mi_option_set_default(@intFromEnum(option), value);
}

// ---------------------------------------------------------------------------
// Process and thread lifecycle
//
// `include/mimalloc.h:189-215`. Every one of these is normally called for you:
// the first `mi_malloc` initializes the process and the calling thread
// (`src/alloc.c:338` -> `src/init.c:200`), and a thread's own teardown is
// arranged by the primitives layer (`include/mimalloc/prim.h:110-114`). They
// are named because upstream names them and because a runtime that embeds
// mimalloc needs to control when they happen.
// ---------------------------------------------------------------------------

/// `mi_process_init` (`include/mimalloc.h:211`): initialize the process.
///
/// Idempotent, and unnecessary: the first allocation does it. Calling it early
/// is how a runtime that wants mimalloc's options parsed before its own first
/// allocation gets them parsed.
pub fn processInit() void {
    c.mi_process_init();
}

/// `mi_process_done` (`include/mimalloc.h:212`): release the process's memory.
///
/// Only safe once every thread that allocated is gone; upstream's own
/// documentation for `mi_process_done` is "not for normal use" and it exists
/// for dynamic unloading. See the `destroy_on_exit` option
/// (`include/mimalloc.h:473`) for the ordinary way to get this at exit.
pub fn processDone() void {
    c.mi_process_done();
}

/// `mi_thread_init` (`include/mimalloc.h:213`): initialize the calling thread.
pub fn threadInit() void {
    c.mi_thread_init();
}

/// `mi_thread_done` (`include/mimalloc.h:214`): release the calling thread's
/// memory.
pub fn threadDone() void {
    c.mi_thread_done();
}

/// `mi_thread_set_in_threadpool` (`include/mimalloc.h:215`): tell mimalloc the
/// calling thread belongs to a pool, so it does not free the pool's memory when
/// the thread ends.
pub fn threadSetInThreadpool() void {
    c.mi_thread_set_in_threadpool();
}

/// `mi_collect` (`include/mimalloc.h:198`, `src/theap.c:161-164`): release this
/// thread's free pages.
///
/// Upstream's comment is exact about the scope: "cannot really collect process
/// wide, just a theap". Live blocks are untouched, and nothing is freed that the
/// caller still holds.
pub fn collect(force: bool) void {
    c.mi_collect(force);
}

// ---------------------------------------------------------------------------
// Ownership questions
//
// These are the only ways this module asks whether a pointer is mimalloc's.
// None of them is a range test, and none of them can answer for a pointer some
// other allocator owns except by saying no.
// ---------------------------------------------------------------------------

/// `mi_any_heap_contains` (`include/mimalloc.h:251`, `src/heap.c:276-279`):
/// whether **any** heap owns `block`.
pub fn anyHeapContains(block: *const anyopaque) bool {
    return c.mi_any_heap_contains(block);
}

/// `mi_check_owned` (`include/mimalloc.h:428`, `src/heap.c:287-289`): the same
/// question, deprecated.
///
/// Deprecated at `include/mimalloc.h:428`; its own body says "// deprecated" and
/// forwards to `mi_any_heap_contains`. `anyHeapContains` is what to write.
pub fn checkOwned(block: *const anyopaque) bool {
    return c.mi_check_owned(block);
}

/// `mi_is_in_heap_region` (`include/mimalloc.h:431`): whether `block` is an
/// address mimalloc manages, whether or not it is a live block.
///
/// Deprecated at `include/mimalloc.h:431`. It answers a weaker question than
/// `anyHeapContains` - an address inside an arena but not inside a block still
/// counts - which is why it is not the ownership question and is not used for
/// one.
pub fn isInHeapRegion(block: *const anyopaque) bool {
    return c.mi_is_in_heap_region(block);
}

// ---------------------------------------------------------------------------
// Callbacks
//
// Every one of these crosses the boundary *inward*: the provider's own C calls a
// function this program wrote, with the provider's calling convention and the
// provider's thread. Upstream declares them with `mi_cdecl`
// (`include/mimalloc.h:189`, `:192`, `:195`, `:318`, `:367`, `:412`), which is
// `__cdecl` on Windows and nothing on every other target
// (`include/mimalloc.h:68`), so `callconv(.c)` is the right spelling for all six
// of this package's targets.
//
// `arg` is passed back unchanged. Nothing here is called while a lock this
// package holds is held, because this package holds no lock while any of these
// runs.
// ---------------------------------------------------------------------------

/// `mi_deferred_free_fun` (`include/mimalloc.h:189`).
pub const DeferredFreeFn = *const fn (force: bool, heartbeat: u64, arg: ?*anyopaque) callconv(.c) void;

/// `mi_output_fun` (`include/mimalloc.h:192`): where mimalloc's messages go.
///
/// `msg` is NUL-terminated and owned by the provider; copy it if it has to
/// outlive the call. Its type is `[*c]const u8` because that is what the
/// translation declares for `const char* msg` (`translate.zig`'s
/// `mi_output_fun`), and a callback type has to match the declaration it is
/// passed to exactly - Zig refuses a function pointer whose parameter types
/// differ at all.
pub const OutputFn = *const fn (msg: [*c]const u8, arg: ?*anyopaque) callconv(.c) void;

/// `mi_error_fun` (`include/mimalloc.h:195`): receives an errno.
///
/// With no handler registered upstream calls `mi_error_default`
/// (`src/options.c:620-625`), which aborts. Registering one here replaces that
/// abort with a return, which is the only reason to register it.
pub const ErrorFn = *const fn (err: c_int, arg: ?*anyopaque) callconv(.c) void;

/// `mi_block_visit_fun` (`include/mimalloc.h:318`): one page or one block.
///
/// Returning false stops the walk; every remaining page is skipped
/// (`src/arena.c:2503`, `:2512`).
///
/// The first two parameters are spelled as the translation spells them -
/// `?*const mi_heap_t` and `[*c]const mi_heap_area_t`, a borrowed heap and a
/// borrowed non-null area pointer - because a callback type either matches the
/// C declaration exactly or is not a callback for it. `mi_heap_visit_blocks`
/// takes `?*const mi_block_visit_fun`
/// (`include/mimalloc.h:318`), so passing a callback of this type is the only
/// way it compiles at all.
pub const BlockVisitFn = *const fn (
    heap: ?*const c.mi_heap_t,
    area: [*c]const c.mi_heap_area_t,
    block: ?*anyopaque,
    block_size: usize,
    arg: ?*anyopaque,
) callconv(.c) bool;

/// `mi_heap_visit_fun` (`include/mimalloc.h:367`): one heap, borrowed.
pub const HeapVisitFn = *const fn (heap: ?*c.mi_heap_t, arg: ?*anyopaque) callconv(.c) bool;

/// `mi_commit_fun_t` (`include/mimalloc.h:412`): commit or reset memory on the
/// allocator's behalf. Experimental; see `manageMemory`.
///
/// `is_zero` is upstream's out-parameter, `bool* is_zero`
/// (`include/mimalloc.h:412`), which the translation spells `[*c]bool`: a
/// non-optional pointer the callback writes through, and therefore a different
/// thing from the `is_zero: bool` input that `manageMemory` itself takes.
pub const CommitFn = *const fn (
    commit: bool,
    start: ?*anyopaque,
    size: usize,
    is_zero: [*c]bool,
    user_arg: ?*anyopaque,
) callconv(.c) bool;

/// `mi_register_deferred_free` (`include/mimalloc.h:190`): ask mimalloc to call
/// back when it is about to collect, so a runtime can free its own objects
/// first.
///
/// `heartbeat` counts the callbacks, which is what upstream's own
/// documentation at `include/mimalloc.h:189` means by it. `force` is upstream's
/// own argument, passed through unchanged.
pub fn registerDeferredFree(deferred_free: DeferredFreeFn, arg: ?*anyopaque) void {
    c.mi_register_deferred_free(deferred_free, arg);
}

/// `mi_register_output` (`include/mimalloc.h:193`): send mimalloc's messages
/// somewhere other than the default output.
///
/// `out` is nullable because upstream's is: a null `out` restores the default
/// output, which is what `mi_register_output` itself does with it
/// (`src/options.c:441-442`). The translation declares the parameter
/// `?*const mi_output_fun` (`zig/translate.h`'s translation of
/// `mi_output_fun* out`, `include/mimalloc.h:193`); narrowing it to non-null
/// here would be this file refusing a call upstream accepts.
pub fn registerOutput(out: ?OutputFn, arg: ?*anyopaque) void {
    c.mi_register_output(out, arg);
}

/// `mi_register_error` (`include/mimalloc.h:196`): replace the abort that
/// follows an error message.
pub fn registerError(fun: ErrorFn, arg: ?*anyopaque) void {
    c.mi_register_error(fun, arg);
}

// ---------------------------------------------------------------------------
// Reporting
//
// These print through the registered output, or to the default output when none
// is registered. They allocate nothing this module can see and return nothing
// that has to be freed.
// ---------------------------------------------------------------------------

/// The eight numbers `mi_process_info` reports
/// (`include/mimalloc.h:204-206`, `src/stats.c:573-597`).
///
/// Gathered here into one struct because upstream takes eight out-parameters,
/// every one of which it checks for null before writing
/// (`src/stats.c:587-594`) and every one of which it clamps to `PTRDIFF_MAX`.
/// The values are upstream's; nothing here recomputes one.
pub const ProcessInfo = struct {
    elapsed_msecs: usize = 0,
    user_msecs: usize = 0,
    system_msecs: usize = 0,
    current_rss: usize = 0,
    peak_rss: usize = 0,
    current_commit: usize = 0,
    peak_commit: usize = 0,
    page_faults: usize = 0,
};

/// `mi_process_info` (`include/mimalloc.h:204`): the eight numbers, read at
/// once so that they describe the same instant.
pub fn processInfo() ProcessInfo {
    var info: ProcessInfo = .{};
    c.mi_process_info(
        &info.elapsed_msecs,
        &info.user_msecs,
        &info.system_msecs,
        &info.current_rss,
        &info.peak_rss,
        &info.current_commit,
        &info.peak_commit,
        &info.page_faults,
    );
    return info;
}

/// `mi_options_print` (`include/mimalloc.h:200`): print every option and its
/// value.
pub fn optionsPrint() void {
    c.mi_options_print();
}

/// `mi_options_print_out` (`include/mimalloc.h:202`): as `optionsPrint`, to a
/// given output.
///
/// `out` is nullable, as it is upstream: `mi_out_stderr` is chosen for a null
/// `out` (`src/options.c:438`), so passing null means "the default output".
pub fn optionsPrintTo(out: ?OutputFn, arg: ?*anyopaque) void {
    c.mi_options_print_out(out, arg);
}

/// `mi_process_info_print` (`include/mimalloc.h:201`): print `processInfo`.
pub fn processInfoPrint() void {
    c.mi_process_info_print();
}

/// `mi_process_info_print_out` (`include/mimalloc.h:203`): as
/// `processInfoPrint`, to a given output. `out` is nullable for the reason
/// `optionsPrintTo` gives.
pub fn processInfoPrintTo(out: ?OutputFn, arg: ?*anyopaque) void {
    c.mi_process_info_print_out(out, arg);
}

/// `mi_stats_print_out` (`include/mimalloc.h:441`): print the statistics
/// upstream's stats header documents.
///
/// This is the entry point that reaches `mimalloc-stats.h`'s machinery without
/// this package's translation having included that header; see
/// `zig/translate.h` for why. It prints, and returns nothing: the structured
/// `mi_stats_t` and its JSON form are reachable through `c` for a caller that
/// needs them.
pub fn statsPrintTo(out: ?OutputFn, arg: ?*anyopaque) void {
    c.mi_stats_print_out(out, arg);
}

/// `mi_thread_stats_print_out` (`include/mimalloc.h:430`): the same, for the
/// calling thread only. Deprecated at `include/mimalloc.h:430`.
pub fn threadStatsPrintTo(out: ?OutputFn, arg: ?*anyopaque) void {
    c.mi_thread_stats_print_out(out, arg);
}

/// `mi_stats_reset` (`include/mimalloc.h:437`): reset this process's statistics.
pub fn statsReset() void {
    c.mi_stats_reset();
}
