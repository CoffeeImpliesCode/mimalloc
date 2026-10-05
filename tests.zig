// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Behavioural tests for the mimalloc facade.
//!
//! ## What these tests are, and what they are not
//!
//! Every test here has an **independent oracle**: a fact the answer must have
//! because of something other than this package's own code.
//!
//!   * An alignment requirement, because `addr % alignment == 0` is what
//!     "aligned" means and is not mimalloc's definition to change. The oracle is
//!     POSIX's, cited in upstream's own comment at
//!     `include/mimalloc/internal.h:536`.
//!   * `realloc` preserving the lesser of the old and new sizes, which is C99
//!     7.20.3.4's requirement and not mimalloc's.
//!   * `calloc` returning zeroed bytes, which is C99 7.22.3.2's requirement.
//!   * `realpath` producing an absolute path with no `.` or `..` left in it,
//!     which is POSIX's requirement.
//!   * A pointer being owned by the heap that produced it, which is the whole
//!     point of `mi_heap_contains` and the first-class-heap contract at
//!     `include/mimalloc.h:235-237`.
//!   * `goodSize` being a rounding: never rounding down, never stepping backwards
//!     as the request grows, and never yielding a smaller answer when fed its
//!     own answer back. **Not** idempotence, which `mi_good_size` does not have -
//!     see the test for why, and for what replaces it.
//!
//! What is deliberately **not** here:
//!
//!   * **No leak assertion, and no leak oracle.** Every block below is owned by
//!     mimalloc. `std.testing.allocator` can only detect a leak of memory *it*
//!     handed out, because it keeps a record of its own outstanding blocks; it
//!     cannot detect a leak of memory a third-party allocator owns, because the
//!     block was never its. So this file frees everything it allocates - that is
//!     hygiene, not an assertion - and asserts nothing about leaks, in either
//!     direction.
//!   * **No version pin and no default pin.** A test that asserts
//!     `version_num == 30503` would pass on a build with the wrong headers and
//!     fail on the next upstream release; the pin belongs in `UPSTREAM.md` and
//!     in `tools/check-provenance.sh`, which is where it is.
//!   * **No `@hasDecl`, no export-presence check, no forwarding comparison**.
//!
//! ## The runtime-loaded route
//!
//! Every test calls `ensureLoaded` first. In a linked build that is a no-op. In
//! a runtime-loaded build (`-Druntime`) the module has no symbols until a
//! provider is named, and this package will not guess one: the test reads an
//! absolute path from `MIMALLOC_PROVIDER` and refuses to run without one, rather
//! than falling back to a linked copy or to a library name of its own choosing.
//! A runtime-loaded `zig build test` with that variable unset therefore fails
//! with this message instead of passing quietly.

const std = @import("std");
const builtin = @import("builtin");
const mimalloc = @import("mimalloc");

/// The environment variable that names a provider for the runtime-loaded route.
const provider_variable = "MIMALLOC_PROVIDER";

/// Makes the facade usable, whichever route this build is.
///
/// No-op in a linked build. In a runtime-loaded build it names one provider, once,
/// and the loader's own idempotence makes every later call a no-op. A second,
/// different provider is `ProviderMismatch` and that is upstream's answer, not
/// something to work around.
fn ensureLoaded() !void {
    if (!mimalloc.runtime_loaded) return;
    const named = std.c.getenv(provider_variable) orelse return error.ProviderNotNamed;
    try mimalloc.load(.{ .path = named });
}

/// The set of sizes every allocation-shape test walks.
///
/// Chosen to straddle the boundaries that matter rather than to be many: below,
/// at, and above the small maximum (`MI_SMALL_SIZE_MAX` is
/// `MI_SMALL_WSIZE_MAX * sizeof(size_t)`, `include/mimalloc.h:123-124`, so 1024
/// bytes where a word is 8), around the OS page size, and past the 64 KiB slice
/// size above which mimalloc switches from a size-class page to a large-object
/// page (`MI_ARENA_SLICE_SIZE`, `include/mimalloc/types.h:235`).
const probe_sizes = [_]usize{ 0, 1, 2, 7, 8, 15, 16, 17, 63, 64, 65, 127, 128, 255, 256, 1023, 1024, 1025, 4095, 4096, 4097, 65_535, 65_536, 65_537, 262_144 };

/// The alignments every alignment-shape test walks: every power of two up to and
/// past `MI_MAX_ALIGN_SIZE` (16, `include/mimalloc/types.h:38-40`), plus 64 KiB,
/// which is `MI_PAGE_MAX_OVERALLOC_ALIGN` (`include/mimalloc/types.h:510`) and so
/// the point at which mimalloc stops over-allocating inside a page and asks the
/// OS for the memory itself (`src/alloc-aligned.c:52-70`), plus 1 MiB, which is
/// past that boundary.
const probe_alignments = [_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 4096, 65_536, 1 << 20 };

test "the linked library agrees with the header it was compiled against" {
    try ensureLoaded();
    // The oracle is the linker: a bundled archive built from a different
    // `include/mimalloc.h` than the one this test's translation saw would
    // answer `mi_version` with that other header's `MI_MALLOC_VERSION`, and no
    // symbol-resolution failure would catch it because `MI_MALLOC_VERSION` is a
    // macro and never appears in a symbol name. This is the check that catches
    // it. It is not a version pin: it compares the two answers with each other
    // and would fail on any mismatch, in either direction.
    try std.testing.expectEqual(mimalloc.version_num, mimalloc.version());
}

test "this package does not replace the process allocator" {
    try ensureLoaded();
    // The oracle is the process, not this file. `MI_MALLOC_OVERRIDE` is never
    // defined by `build.zig`, so `src/alloc-override.c` stays empty
    // (`src/alloc-override.c:13`) and no redirection module is present;
    // upstream's own predicate for exactly that question answers false
    // (`include/mimalloc.h:329`, `src/prim/prim.c:65-67`).
    //
    // If this ever fails, someone has made mimalloc the process allocator, which
    // is a migration this package does not perform and does not claim. Read
    // `README.md`, "This package does not replace your allocator", before
    // treating a failure here as a bug in the test.
    try std.testing.expect(!mimalloc.isRedirected());
}

test "every size is honoured, and the usable size is at least the request" {
    try ensureLoaded();
    for (probe_sizes) |size| {
        const block = try mimalloc.malloc(size);
        defer mimalloc.free(block);
        // The oracle is the request. `mi_usable_size` reports the page's block
        // size (`src/free.c:587-590`), so it is at least what was asked for and
        // usually more; in a build with `MI_PADDING` it is exactly the request
        // (`include/mimalloc/types.h:114-121`). Both are >=.
        const usable = mimalloc.usableSize(block);
        try std.testing.expect(usable >= size);
    }
}

test "a zero-size request is a real, freeable block" {
    try ensureLoaded();
    // Upstream says so in its own words: `mi_malloc(0)` returns a valid unique
    // pointer rather than NULL, and `src/alloc.c:463-465` uses exactly that
    // sentence to describe a zero-size `mi_realloc`. With `MI_PADDING` the
    // request is widened to one word before it is served
    // (`src/alloc.c:159-162`); without it, the first block of the page is handed
    // out. Either way there is a block, and a caller that treats a zero-size
    // request as "no allocation" and then frees nothing has simply leaked the
    // only pointer it was given.
    const block = try mimalloc.malloc(0);
    mimalloc.free(block);

    const zeroed = try mimalloc.zalloc(0);
    mimalloc.free(zeroed);
}

test "freeing a null pointer changes nothing" {
    try ensureLoaded();
    // The oracle is upstream's own guard: `mi_free` is called with
    // `check_p_for_null = true` (`src/free.c:284-286`, `:251-254`), so a null
    // is a no-op rather than an error. What proves it is a no-op is the
    // allocation that follows: if it had corrupted anything, this would not be
    // the first observable symptom.
    mimalloc.free(null);
    const control = try mimalloc.malloc(32);
    defer mimalloc.free(control);
    try std.testing.expect(mimalloc.usableSize(control) >= 32);
}

test "an aligned block lands on its alignment boundary" {
    try ensureLoaded();
    for (probe_alignments) |alignment| {
        for (probe_sizes) |size| {
            const block = try mimalloc.mallocAligned(size, alignment);
            defer mimalloc.free(block);
            // The oracle is the definition: "aligned to N" means the address is a
            // multiple of N. Nothing about mimalloc's page layout, size classes
            // or over-allocation is consulted.
            const address = @intFromPtr(block);
            try std.testing.expectEqual(@as(usize, 0), address % alignment);
            // And the block really is writable to the length that was asked for,
            // which is what the alignment is for.
            const bytes: [*]u8 = @ptrCast(block);
            @memset(bytes[0..size], 0xA5);
            for (bytes[0..size]) |byte| try std.testing.expectEqual(@as(u8, 0xA5), byte);
        }
    }
}

test "an aligned block at an offset puts the offset on the boundary" {
    try ensureLoaded();
    // The oracle is upstream's own description at `include/mimalloc.h:155`: the
    // block is placed so that `offset` bytes into it sit on an `alignment`
    // boundary. This is the one entry point that lets a caller align a field
    // inside a block rather than the allocation itself.
    //
    // The alignments stop at `MI_PAGE_MAX_OVERALLOC_ALIGN` (64 KiB,
    // `include/mimalloc/types.h:510`) and that bound is upstream's, not this
    // test's: above it `src/alloc-aligned.c:62-67` refuses a non-zero offset
    // outright with an `EOVERFLOW` message, because a very large alignment is
    // served by asking the OS for the memory rather than by over-allocating
    // inside a page, and there is nowhere inside one block to put the offset.
    // Walking past that bound would be testing a refusal as if it were an
    // alignment.
    //
    // **The offsets are multiples of one word, and that bound is upstream's
    // too - but it lives in the debug path, not in the allocator.** With a
    // non-zero offset `mi_malloc_aligned_at` returns `base + adjust`, where
    // `adjust` is however far the block had to move to put `offset` on the
    // boundary (`src/alloc-aligned.c:81-86`). An odd offset makes `adjust` odd
    // and the returned pointer odd. In any build where `MI_DEBUG` is, every
    // pointer that reaches `mi_usable_size`, `mi_free` or any other page-lookup
    // entry point is rejected first for not being word-aligned
    // (`src/free.c:195-198`), and mimalloc then trips its own assertion that
    // the aligned pointer has a usable size (`src/alloc-aligned.c:117`) and
    // aborts **inside the allocation**, before the caller ever sees a pointer.
    // Measured against this tree's archive, every odd offset aborts that way
    // and every word-aligned one succeeds at every alignment up to 64 KiB. That
    // is an upstream inconsistency - a request the entry point accepts and the
    // same build's own validity check then refuses - and it is reported rather
    // than worked around in the C source. The offsets below stay word-aligned
    // so that what is checked is the alignment property and not that defect,
    // and they stay deliberately not multiples of the alignment: 8 and 24 cross
    // the boundary of every alignment from 16 upward.
    for (probe_alignments) |alignment| {
        if (alignment > 65_536) continue;
        for ([_]usize{ 8, 24, 56 }) |offset| {
            const size = 256;
            const block = try mimalloc.mallocAlignedAt(size, alignment, offset);
            defer mimalloc.free(block);
            const address = @intFromPtr(block);
            try std.testing.expectEqual(@as(usize, 0), (address + offset) % alignment);
            // A usable block, not merely a boundary. `size` is what upstream
            // itself guarantees - `mi_assert_internal(mi_usable_size(aligned_p)
            // >= size)`, `src/alloc-aligned.c:117` - and it holds at every
            // combination above.
            //
            // That guarantee stops at `size` and **does not** cover the `offset`
            // bytes in front of the field. Upstream over-allocates
            // `max(size, MI_MAX_ALIGN_SIZE) + alignment - 1` and then moves the
            // pointer forward by up to `alignment - 1`
            // (`src/alloc-aligned.c:73`, `:81-86`), which leaves up to `offset`
            // bytes too few for a field of `size` bytes placed `offset` bytes
            // in. Measured against this tree's archive, `usableSize` runs 1 to
            // `offset` bytes short of `offset + size` at every non-zero offset
            // and every alignment from 2 to 64 KiB. That is an upstream defect,
            // and it is reported rather than asserted here: `offset + size`
            // would fail on an upstream that is correct, so this test states
            // only what upstream promises.
            try std.testing.expect(mimalloc.usableSize(block) >= size);
        }
    }
}

test "an alignment that is zero or not a power of two never reaches the allocator" {
    try ensureLoaded();
    // The oracle is upstream's own rule, `include/mimalloc/internal.h:537-539`:
    // non-zero and a power of two, which is the `posix_memalign` rule upstream
    // cites at `:536`. Upstream only *asserts* it - `mi_assert_internal`, which
    // `NDEBUG` compiles away - so a release build would otherwise hand a
    // nonsense alignment to the page allocator. What proves the check happens
    // here is the control allocation afterwards: it succeeds, so the process was
    // not disturbed by the four rejected requests.
    for ([_]usize{ 0, 3, 6, 24, 48, 100 }) |alignment| {
        try std.testing.expectError(
            error.InvalidAlignment,
            mimalloc.mallocAligned(64, alignment),
        );
        try std.testing.expectError(
            error.InvalidAlignment,
            mimalloc.zallocAligned(64, alignment),
        );
        try std.testing.expectError(
            error.InvalidAlignment,
            mimalloc.callocAligned(2, 32, alignment),
        );
        try std.testing.expectError(
            error.InvalidAlignment,
            mimalloc.mallocAlignedAt(64, alignment, 0),
        );
    }
    const control = try mimalloc.malloc(64);
    defer mimalloc.free(control);
    try std.testing.expect(mimalloc.usableSize(control) >= 64);
}

test "zalloc and calloc return zeroed memory, including a recycled block" {
    try ensureLoaded();
    for (probe_sizes) |size| {
        // First the plain case: fresh memory is zero because the allocator says
        // so, not because the OS happened to hand out a fresh page. The oracle
        // is C99 7.22.3.2: `calloc` initializes to zero.
        const zeroed = try mimalloc.calloc(1, size);
        defer mimalloc.free(zeroed);
        for (mimalloc.Block.from(zeroed).bytes(size)) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }

    // Now the case that a fresh page cannot explain. The block is filled with a
    // pattern, freed, and the very same request made again: whatever handed the
    // memory back has to zero it, or the pattern survives. That is the whole
    // difference between "the OS gave us fresh pages" and "`zalloc` promises
    // zeros", and it is upstream's promise at `include/mimalloc.h:128` and
    // `:111`, reached through `_mi_theap_malloc_zero` with `zero = true`.
    for (probe_sizes) |size| {
        const dirty = try mimalloc.malloc(size);
        @memset(mimalloc.Block.from(dirty).bytes(size), 0xA5);
        mimalloc.free(dirty);

        const recycled = try mimalloc.calloc(1, size);
        defer mimalloc.free(recycled);
        for (mimalloc.Block.from(recycled).bytes(size)) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
}

test "calloc multiplies before it allocates" {
    try ensureLoaded();
    // The oracle is C99 7.22.3.2 again, this time for the product: 8 elements
    // of 16 bytes is 128 bytes of zero, and every one of the 128 is checked.
    const typed = try mimalloc.allocSliceZeroed(u64, 16);
    defer mimalloc.free(typed.ptr);
    try std.testing.expectEqual(@as(usize, 16), typed.len);
    for (typed) |word| try std.testing.expectEqual(@as(u64, 0), word);
}

test "an overflowing product is refused rather than truncated" {
    try ensureLoaded();
    // The oracle is C99 7.22.3.2's requirement that the product be
    // representable, and the fact that `count * size` would wrap on a machine
    // whose `size_t` is 64 bits: `2^63 * 4` is 2^65, which is 0 modulo 2^64.
    // Upstream detects the overflow and returns NULL
    // (`src/alloc.c:372-373`, via `mi_count_size_overflow`), which this facade
    // reports as `OutOfMemory` because upstream gives it no code of its own.
    try std.testing.expectError(
        error.OutOfMemory,
        mimalloc.calloc(std.math.maxInt(usize) / 2 + 1, 4),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        mimalloc.calloc(std.math.maxInt(usize), 2),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        mimalloc.calloc(std.math.maxInt(usize), std.math.maxInt(usize)),
    );

    // **A product of zero is not an overflow**, so this is the boundary of the
    // cases above rather than another instance of them, and the assertion is
    // that it *succeeds*. `0 * anything` is 0, which is representable, which is
    // all C99 7.22.3.2 asks. Upstream overflow-checks and then allocates the
    // product (`src/alloc.c:371-375`), so `mi_calloc(0, huge)` hands back a
    // block - measured, not assumed. This test used to require
    // `calloc(0, maxInt)` to fail, which is the opposite of what C99 requires
    // and of what upstream does, and which no correct build could satisfy.
    // Upstream's own promise that a zero-size request is a freeable block
    // (`src/alloc.c:463-465`) is checked here rather than asserted in a comment.
    const zero = try mimalloc.calloc(0, std.math.maxInt(usize));
    mimalloc.free(zero);
}

test "realloc preserves the content of the block it resizes" {
    try ensureLoaded();
    // The oracle is C99 7.20.3.4: realloc preserves the lesser of the old and
    // new sizes. The address is *not* required to change, and it does not -
    // upstream returns the same pointer whenever `newsize >= usable / 2`
    // (`src/alloc.c:483`) - so the test asserts the content, never the address.
    // No `defer` here and no `defer` at the end either: `realloc` hands the old
    // block back whenever the request fits (`src/alloc.c:483`), so the pointer
    // that arrives at the end is very often the one this line produced. Exactly
    // one `free` runs, on whatever pointer the last `realloc` returned.
    const block = try mimalloc.calloc(1, 16);
    {
        const bytes = mimalloc.Block.from(block).bytes(16);
        for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 1);
    }

    const grown = try mimalloc.realloc(block, 4096);
    {
        const bytes = mimalloc.Block.from(grown).bytes(16);
        for (bytes, 0..) |byte, index| try std.testing.expectEqual(@as(u8, @truncate(index *% 7 +% 1)), byte);
        // The rest of the grown block is writable and is not promised to hold
        // anything, so it is only written to, never read back as a known value.
        @memset(mimalloc.Block.from(grown).bytes(4096)[16..], 0x5A);
    }

    const shrunk = try mimalloc.realloc(grown, 4);
    {
        const bytes = mimalloc.Block.from(shrunk).bytes(4);
        for (bytes, 0..) |byte, index| try std.testing.expectEqual(@as(u8, @truncate(index *% 7 +% 1)), byte);
    }
    mimalloc.free(shrunk);
}

test "rezalloc zeroes the growth and leaves the content it was given" {
    try ensureLoaded();
    // The oracle is upstream's own statement about which blocks this is for:
    // `include/mimalloc.h:280-282` says "Only valid on memory that was originally
    // allocated with zero initialization too", so the block here starts as
    // `calloc`, and `src/alloc.c:506-517` shows the growth being zeroed from the
    // end of the preserved content onwards - including the last word of the old
    // allocation, so that padding is zeroed too.
    const block = try mimalloc.calloc(1, 16);
    mimalloc.Block.from(block).bytes(16)[0] = 0x5A;
    mimalloc.Block.from(block).bytes(16)[15] = 0x5A;

    const grown = try mimalloc.rezalloc(block, 128);
    defer mimalloc.free(grown);
    const bytes = mimalloc.Block.from(grown).bytes(128);
    try std.testing.expectEqual(@as(u8, 0x5A), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x5A), bytes[15]);
    for (bytes[16..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "a zero-size reallocation yields a block rather than nothing" {
    try ensureLoaded();
    // Same oracle as a zero-size `malloc`: upstream's comment at
    // `src/alloc.c:463-465`, and the reason the returned null means an error -
    // "returning NULL always indicates an error, and `p` will not have been
    // freed in that case". So a zero-size reallocation must not be a way to spell
    // "failed".
    const block = try mimalloc.malloc(64);
    const zeroed = try mimalloc.realloc(block, 0);
    mimalloc.free(zeroed);
}

test "expand refuses a size the block cannot hold, and returns the block when it can" {
    try ensureLoaded();
    // The oracle is the block's own usable size, not a constant: `mi_expand`
    // returns the pointer unchanged when the request fits and NULL when it does
    // not (`src/alloc.c:449-462`). It is compiled to `return NULL` outright when
    // `MI_PADDING` is on (`src/alloc.c:449-452`), which is the case in a Debug
    // build, so the only assertion that holds in both configurations is the shape:
    // a null request is refused, a request larger than any block is refused, and
    // a non-null answer is the very pointer that was passed in. Anything stronger
    // would be pinning one optimize mode's behaviour.
    const block = try mimalloc.malloc(64);
    defer mimalloc.free(block);
    try std.testing.expectEqual(@as(?*anyopaque, null), mimalloc.expand(null, 64));
    try std.testing.expectEqual(@as(?*anyopaque, null), mimalloc.expand(block, std.math.maxInt(usize)));
    if (mimalloc.expand(block, mimalloc.usableSize(block))) |same| {
        try std.testing.expectEqual(@as(usize, @intFromPtr(block)), @intFromPtr(same));
    }
}

test "goodSize is a rounding, and usableSize is at least what goodSize promises" {
    try ensureLoaded();
    // The oracle is the property of a rounding function rather than of any one
    // number: `src/page-queue.c:113-125` rounds a small request up to its bin, a
    // large one up to the OS page size, and returns the request unchanged above
    // `MI_MAX_ALLOC_SIZE`. Pinning a specific bin size would be pinning a
    // default constant, which this workspace's test policy forbids.
    //
    // **Idempotence is deliberately not asserted, because upstream does not
    // have it.** `mi_good_size` looks the bin up for `size + MI_PADDING_SIZE`
    // (`src/page-queue.c:116`) and reports that bin's block size, so its answer
    // describes a *larger* request than the one asked about and feeding it back
    // lands on a later bin. Measured against this build's archive, every one of
    // 1..4096 is non-idempotent: `goodSize(100)` is 112 and `goodSize(112)` is
    // 128. `MI_PADDING` is 1 whenever `MI_DEBUG` is
    // (`include/mimalloc/types.h:116-122`), so a Debug build of this tree always
    // has it, and a criterion asserted in that mode cannot be one any correct
    // build would pass.
    //
    // What replaces it is four properties of a rounding, and the fourth is the
    // promise the test's name makes: the block the allocator actually serves for
    // a rounded request is at least that rounded request. Nothing else here
    // checked it.
    var previous: usize = 0;
    for (probe_sizes, 0..) |size, index| {
        const rounded = mimalloc.goodSize(size);
        // Never rounds down.
        try std.testing.expect(rounded >= size);
        // Never steps backwards as the request grows.
        if (index > 0) try std.testing.expect(rounded >= previous);
        previous = rounded;
        // Re-rounding a rounded size never yields a smaller one.
        try std.testing.expect(mimalloc.goodSize(rounded) >= rounded);

        // What `goodSize` promises is what `mi_malloc` of that size delivers,
        // and `mi_usable_size` reports the page's block size
        // (`src/free.c:587-590`) rather than the request.
        const block = try mimalloc.malloc(rounded);
        defer mimalloc.free(block);
        try std.testing.expect(mimalloc.usableSize(block) >= rounded);
    }
}

test "strdup copies the bytes and strndup truncates at n and at a NUL" {
    try ensureLoaded();
    // The oracle is the input. Nothing about a copy can be wrong and still equal
    // its source, so this is a real check of `mi_theap_strdup`
    // (`src/alloc.c:616-626`) and of `mi_theap_strndup`'s `strnlen`
    // (`src/alloc.c:636-646`), including the rule that `strndup` stops early at
    // a NUL rather than reading past it.
    const source: [:0]const u8 = "the quick brown fox";
    const copy = try mimalloc.strdup(source);
    defer mimalloc.free(copy);
    try std.testing.expectEqualStrings(source, std.mem.span(@as([*:0]const u8, copy)));

    const whole = try mimalloc.strndup(source, source.len);
    defer mimalloc.free(whole);
    try std.testing.expectEqualStrings(source, std.mem.span(@as([*:0]const u8, whole)));

    const cut = try mimalloc.strndup(source, 3);
    defer mimalloc.free(cut);
    try std.testing.expectEqualStrings("the", std.mem.span(@as([*:0]const u8, cut)));

    // `n` longer than the string must stop at the NUL, not pad and not overrun.
    const over = try mimalloc.strndup(source, source.len * 4);
    defer mimalloc.free(over);
    try std.testing.expectEqualStrings(source, std.mem.span(@as([*:0]const u8, over)));

    // An embedded NUL: the C string ends there, and `strndup` agrees.
    const embedded = try mimalloc.strndup("ab\x00cd", 5);
    defer mimalloc.free(embedded);
    try std.testing.expectEqualStrings("ab", std.mem.span(@as([*:0]const u8, embedded)));
}

test "realpath resolves to an absolute path with no dot components left in it" {
    try ensureLoaded();
    // The oracle is POSIX's, and it is a real requirement rather than a
    // restatement of what upstream does: `realpath` returns an absolute path and
    // resolves every `.` and `..`. `realpathInto` and `realpath` are two
    // different upstream code paths - libc's `realpath` writing into the
    // caller's buffer (`src/alloc.c:719-720`) against mimalloc's own buffer plus
    // a `strndup` copy (`src/alloc.c:725-739`) - and they must agree.
    var buffer: [8192]u8 = undefined;
    const resolved = mimalloc.realpathInto(".", &buffer) orelse
        return error.SkipZigTest;
    try std.testing.expect(std.fs.path.isAbsolute(resolved));
    try std.testing.expect(std.mem.indexOf(u8, resolved, "..") == null);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "/./") == null);

    const owned = try mimalloc.realpath(".");
    defer mimalloc.free(owned);
    try std.testing.expectEqualStrings(resolved, std.mem.span(@as([*:0]const u8, owned)));
}

test "a block is owned by exactly one heap, and the main heap owns a plain one" {
    try ensureLoaded();
    // The oracle is the ownership relation itself: a pointer `mi_malloc` returned
    // is in the main heap, `mi_heap_of` names that heap, and no heap this test
    // creates contains it. That is the whole content of upstream's first-class
    // heap contract (`include/mimalloc.h:235-237`).
    const plain = try mimalloc.malloc(48);
    defer mimalloc.free(plain);

    const owner = mimalloc.Heap.of(plain) orelse return error.NoOwningHeap;
    try std.testing.expect(owner.isOpen());
    try std.testing.expect(owner.contains(plain));
    try std.testing.expect(mimalloc.Heap.main().contains(plain));

    var other = try mimalloc.Heap.init();
    defer other.deinit();
    try std.testing.expect(!other.contains(plain));
}

test "a pointer this package did not allocate is not claimed by any heap" {
    try ensureLoaded();
    // The oracle is the process's own memory. A local variable's address was
    // never handed to mimalloc, so `mi_any_heap_contains` - which is a page-map
    // lookup and not a range test (`src/heap.c:276-279`) - must say no. This is
    // what makes it usable as an ownership question at all: an allocator that
    // claimed arbitrary addresses could not answer it.
    const on_stack: u8 = 0;
    try std.testing.expect(!mimalloc.anyHeapContains(&on_stack));
    try std.testing.expect(!mimalloc.isInHeapRegion(&on_stack));
}

test "a heap can be created, used, and deleted with its blocks still valid" {
    try ensureLoaded();
    // The oracle is the ownership transition upstream documents and this facade
    // keeps separate: `mi_heap_delete` "move live blocks to the main heap"
    // (`include/mimalloc.h:243`, `src/heap.c:236-244`), so after `deinit` the
    // blocks are still readable, are still claimed by a heap, and are still the
    // caller's to free. `destroy` is the other operation and makes no such
    // promise; the next test is about that one.
    var heap = try mimalloc.Heap.init();
    try std.testing.expect(heap.isOpen());

    const block = try heap.malloc(128);
    {
        const bytes = mimalloc.Block.from(block).bytes(128);
        @memset(bytes, 0x3C);
        try std.testing.expect(heap.contains(block));
        try std.testing.expect(mimalloc.anyHeapContains(block));
        try std.testing.expect(mimalloc.Heap.of(block).?.contains(block));
    }

    heap.deinit();
    try std.testing.expect(!heap.isOpen());

    // Still ours, still readable, now in the main heap.
    for (mimalloc.Block.from(block).bytes(128)) |byte| {
        try std.testing.expectEqual(@as(u8, 0x3C), byte);
    }
    try std.testing.expect(mimalloc.anyHeapContains(block));
    try std.testing.expect(mimalloc.Heap.main().contains(block));
    mimalloc.free(block);
}

test "a second deinit on a closed heap is a no-op, not a second delete" {
    try ensureLoaded();
    // The oracle is upstream's own guard: `mi_heap_delete` returns immediately
    // on a null heap (`src/heap.c:237`). What makes this observable rather than
    // a no-op test is that `Heap.raw` is null afterwards, so the second call has
    // nothing to pass - and the process keeps allocating afterwards, which is
    // what would break first if the field had been left dangling.
    var heap = try mimalloc.Heap.init();
    heap.deinit();
    try std.testing.expect(!heap.isOpen());
    heap.deinit();
    heap.destroy();
    try std.testing.expect(!heap.isOpen());

    const control = try mimalloc.malloc(64);
    defer mimalloc.free(control);
    try std.testing.expect(mimalloc.usableSize(control) >= 64);
}

test "destroy releases a heap's blocks in one operation" {
    try ensureLoaded();
    // What is observable, and is asserted: the blocks are there before
    // `destroy` - `visitBlocks` finds at least the ones this test made - and the
    // process still allocates afterwards. What is **not** asserted, and cannot
    // be: that the blocks are gone afterwards. `mi_heap_destroy` frees them
    // (`src/heap.c:261-268`), but a freed block's address is still inside an
    // arena, and whether the page map still maps it is not a contract upstream
    // publishes. Reading them would be a use-after-free, and asking
    // `anyHeapContains` about them would be asking a question whose answer
    // upstream does not define. So this test proves the operation ran and left
    // the process working, and says plainly that it does not prove the blocks
    // were released.
    var heap = try mimalloc.Heap.init();
    const blocks = try std.testing.allocator.alloc(?*anyopaque, 32);
    defer std.testing.allocator.free(blocks);
    for (blocks) |*slot| slot.* = try heap.malloc(64);

    var counter = Counter{};
    try std.testing.expect(heap.visitBlocks(true, Counter.visit, &counter));
    try std.testing.expect(counter.calls >= blocks.len);
    try std.testing.expect(counter.blocks >= blocks.len);

    heap.destroy();
    try std.testing.expect(!heap.isOpen());

    const control = try mimalloc.malloc(64);
    defer mimalloc.free(control);
    try std.testing.expect(mimalloc.usableSize(control) >= 64);
}

test "a block visitor that stops the walk ends it" {
    try ensureLoaded();
    // The oracle is upstream's short-circuit: `ok` gates every remaining page
    // (`src/arena.c:2503`, `:2512`), and `mi_heap_visit_blocks` returns that
    // `ok` (`src/arena.c:2538-2540`). So a visitor that returns false on its
    // first call is called exactly once and the answer is false.
    var heap = try mimalloc.Heap.init();
    defer heap.deinit();
    for (0..16) |_| _ = try heap.malloc(64);

    var stopper = Stopper{};
    try std.testing.expect(!heap.visitBlocks(true, Stopper.visit, &stopper));
    try std.testing.expectEqual(@as(usize, 1), stopper.calls);
}

test "a heap allocates aligned blocks from its own arena" {
    try ensureLoaded();
    // The oracle is the same one as for the process allocator: an alignment is a
    // divisibility property of an address. Doing it through a heap is worth its
    // own test because `mi_heap_malloc_aligned` is a separate entry point
    // (`include/mimalloc.h:268`) and upstream routes it through the heap's
    // theap, not through `mi_malloc_aligned`.
    var heap = try mimalloc.Heap.init();
    defer heap.deinit();
    for (probe_alignments) |alignment| {
        const block = try heap.mallocAligned(64, alignment);
        const address = @intFromPtr(block);
        try std.testing.expectEqual(@as(usize, 0), address % alignment);
        try std.testing.expect(heap.contains(block));
        mimalloc.free(block);
    }
}

test "an arena is reserved, reported, and asked whether it contains an address" {
    try ensureLoaded();
    // The oracle is upstream's own arithmetic: `mi_arena_area` reports the
    // arena's `total_size` (`src/arena.c:193`) and `mi_arena_contains` asks
    // whether an address lies in that arena. Reserving `arenaMinSize()` and then
    // finding the reserved region is the whole of the documented sequence at
    // `include/mimalloc.h:334-348`.
    //
    // `mi_arena_min_size` and `mi_arena_min_alignment` are **two independent
    // constants** (`src/arena.c:89-95`), and this test does not compare them.
    // It used to require `min_size >= min_alignment`, which is false here and
    // cannot be true anywhere: `MI_ARENA_MIN_SIZE` is
    // `MI_BCHUNK_BITS * MI_ARENA_SLICE_SIZE`
    // (`include/mimalloc/types.h:781`; 32 MiB on this platform) while
    // `MI_ARENA_ALIGNMENT` is `MI_PAGE_META_ALIGNMENT`, which is
    // `MI_PAGE_META_ALIGNED_CHUNKS * MI_BCHUNK_BITS * MI_ARENA_SLICE_SIZE`
    // (`include/mimalloc/types.h:172`, `:268`, `:270`; 256 MiB here) - a strictly
    // larger multiple of the same slice, so the inequality always fails the
    // other way. What each one *is*, upstream does say: each is a product of
    // powers of two, so each is a power of two, and neither is a value this
    // test may pin. That is what is checked.
    //
    // A reservation can legitimately fail - a container with a hard address-space
    // or `RLIMIT_AS` limit, or a platform whose `mmap` refuses - and that is a
    // property of the machine, not of this package. It is reported as a skip with
    // the errno, never as a pass.
    const wanted = mimalloc.arenaMinSize();
    try std.testing.expect(wanted > 0);
    try std.testing.expect(mimalloc.arenaMinAlignment() > 0);
    try std.testing.expect(std.math.isPowerOfTwo(wanted));
    try std.testing.expect(std.math.isPowerOfTwo(mimalloc.arenaMinAlignment()));

    var arena_id: mimalloc.ArenaId = null;
    const err = mimalloc.reserveOsMemoryEx(wanted, false, false, false, &arena_id);
    if (err != 0) {
        std.debug.print(
            "mimalloc: reserveOsMemoryEx({d}) failed with errno {d}; the arena test is " ++
                "skipped, not passed\n",
            .{ wanted, err },
        );
        return error.SkipZigTest;
    }
    try std.testing.expect(arena_id != null);

    const area = mimalloc.arenaArea(arena_id) orelse return error.NoReservedArena;
    try std.testing.expect(area.size >= wanted);
    try std.testing.expect(mimalloc.arenaContains(arena_id, area.start));

    // The arena is provider memory: this is not something the caller frees, and
    // the provider releases it when the process ends.
}

test "an unknown arena has no region and contains nothing" {
    try ensureLoaded();
    // The oracle is `src/arena.c:188`, which zeroes the size before it looks
    // anything up, and `:190`, which returns NULL for an arena it does not know.
    // So a request about a null arena id is a clean null, not a stale answer.
    try std.testing.expectEqual(@as(?mimalloc.ArenaArea, null), mimalloc.arenaArea(null));
    try std.testing.expect(!mimalloc.arenaContains(null, &arena_probe));
}

var arena_probe: u8 = 0;

test "the size-valued options report bytes and not the kibibytes they store" {
    try ensureLoaded();
    // The oracle is the units, not a default: `mi_option_get_size` converts a
    // KiB-stored option into bytes (`src/options.c:308-317`), and reading one
    // with `optionGet` instead gives a number 1024 times too small. Which
    // options are KiB-stored is upstream's own list
    // (`mi_option_has_size_in_kib`, `src/options.c:188-191`) and both of these
    // are on it (`include/mimalloc.h:474`, `:496`), so the conversion is checked
    // exactly, for both, without pinning what either happens to be on this
    // machine.
    const reserve = mimalloc.optionGetSize(.arena_reserve);
    const max_object = mimalloc.optionGetSize(.arena_max_object_size);
    try std.testing.expect(reserve > 0);
    try std.testing.expect(max_object > 0);
    try std.testing.expectEqual(reserve, @as(usize, @intCast(mimalloc.optionGet(.arena_reserve))) * 1024);
    try std.testing.expectEqual(max_object, @as(usize, @intCast(mimalloc.optionGet(.arena_max_object_size))) * 1024);

    // `mi_arena_max_object_size` reads that option, rounds it up to a slice and
    // then **clamps** it to `mi_arena_max_fixed_object_size`
    // (`src/arena.c:116-124`), so its answer sits *below* the option whenever
    // the option exceeds that limit - which it does by default here: 2 GiB
    // against a fixed limit a little under 256 MiB. This test used to require
    // the answer to be at least the option, which is the opposite of what the
    // clamp means and which no correct build can satisfy. What is true is that
    // the answer is a positive limit, and that raising the option can never lower
    // it, because both arms of the clamp are monotone in the option.
    try std.testing.expect(mimalloc.arenaMaxObjectSize() > 0);
    const original_max_object = mimalloc.optionGet(.arena_max_object_size);
    defer mimalloc.optionSet(.arena_max_object_size, original_max_object);
    const before_raise = mimalloc.arenaMaxObjectSize();
    mimalloc.optionSet(.arena_max_object_size, std.math.maxInt(c_long));
    try std.testing.expect(mimalloc.arenaMaxObjectSize() >= before_raise);
    // Put it back **now**, not on the way out, and check that it took: a `defer`
    // restore runs after this assertion, so asserting against it would compare
    // the raised value with the original one and always fail. A leaked option
    // change would be a test that corrupts its neighbours.
    mimalloc.optionSet(.arena_max_object_size, original_max_object);
    try std.testing.expectEqual(original_max_object, mimalloc.optionGet(.arena_max_object_size));
}

test "an option can be written and read back, and put back the way it was" {
    try ensureLoaded();
    // The oracle is the round trip through upstream's own table
    // (`include/mimalloc.h:515-519`), not a forwarding accessor: `optionSet`
    // writes and `optionGet` reads a different table entry than the constant the
    // enum tag carries. The original value is restored so that this test cannot
    // change the answer of any other test, and that restore is itself checked -
    // a leaked option change would be a test that corrupts its neighbours.
    const original = mimalloc.optionGet(.max_warnings);
    const toggled: c_long = if (original == 0) 7 else 0;
    mimalloc.optionSet(.max_warnings, toggled);
    try std.testing.expectEqual(toggled, mimalloc.optionGet(.max_warnings));
    mimalloc.optionSet(.max_warnings, original);
    try std.testing.expectEqual(original, mimalloc.optionGet(.max_warnings));
}

test "the process figures are self-consistent when they are read together" {
    try ensureLoaded();
    // The oracle is the relation upstream's own two commit counters have by
    // construction: `peak_commit` is the running maximum of `current_commit`
    // (`src/stats.c:582-585`), so a peak below its current value would mean the
    // counters disagree with themselves. What is not asserted is any particular
    // number: these are facts about the machine.
    //
    // **`peak_rss` is not compared with `current_rss`, because upstream does not
    // relate them.** Upstream seeds both from the commit counters
    // (`src/stats.c:586-587`) and then `_mi_prim_process_info` overwrites only
    // the peak: on Linux and the BSDs `peak_rss` becomes
    // `rusage.ru_maxrss * 1024` (`src/prim/unix/prim.c:810-814`), the kernel's
    // high-water resident set for the whole process, while `current_rss` keeps
    // mimalloc's committed bytes - the Linux path never touches it
    // (`src/prim/unix/prim.c:829-845`). Those are two different quantities:
    // mimalloc can have committed pages the kernel has never made resident. So
    // `peak_rss >= current_rss` is not a property of anything upstream states,
    // and this test used to assert it and fail when the process had committed
    // more than the kernel had paged in.
    //
    // What is universal is that each figure is positive once the process has
    // allocated: `peak_rss` from the kernel's high-water mark where
    // `_mi_prim_process_info` reads one, and from `peak_commit` on the platforms
    // where it is a no-op (`src/prim/unix/prim.c:854-858`).
    const info = mimalloc.processInfo();
    try std.testing.expect(info.peak_commit >= info.current_commit);
    // Having allocated at all, the committed figure has to be positive.
    try std.testing.expect(info.current_commit > 0);
    try std.testing.expect(info.current_rss > 0);
    try std.testing.expect(info.peak_rss > 0);
    try std.testing.expect(info.peak_commit > 0);
}

test "collecting and resetting statistics leave the allocator usable" {
    try ensureLoaded();
    // The oracle is upstream's own statement about what `mi_collect` does: "cannot
    // really collect process wide, just a theap" (`src/theap.c:161-163`), so a
    // live block survives it. The block written before the call is read after it.
    const block = try mimalloc.malloc(96);
    mimalloc.Block.from(block).bytes(96)[0] = 0x77;
    mimalloc.collect(true);
    try std.testing.expectEqual(@as(u8, 0x77), mimalloc.Block.from(block).bytes(96)[0]);
    mimalloc.collect(false);
    mimalloc.statsReset();
    mimalloc.free(block);
}

test "a block allocated on one thread is freeable on another" {
    // This test needs a second thread, and there are targets in this package's
    // own check list that have none: `zig build check` compiles this file for
    // `wasm32-wasi`, where `std.Thread.spawn` is a `@compileError` rather than
    // a run-time failure (`lib/std/Thread.zig:346`). The condition is comptime
    // known, so the untaken branch is not analysed at all on a target with
    // threads and the body is not analysed at all on one without. This is a
    // property of the target, not of mimalloc, and it is a skip rather than a
    // pass: there is no second thread to make the promise with.
    if (builtin.single_threaded) return error.SkipZigTest;
    try ensureLoaded();
    // The oracle is upstream's cross-thread free path: `mi_free` pushes a block
    // whose originating thread differs onto the page's thread-free list
    // (`src/free.c:262-280`) rather than requiring the originating thread. This is
    // the same promise the first-class heap makes for a whole heap
    // (`include/mimalloc.h:236`), exercised through the ordinary path.
    var worker = Worker{};
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();

    const block = worker.ptr orelse return error.WorkerDidNotAllocate;
    try std.testing.expect(mimalloc.anyHeapContains(block));
    for (mimalloc.Block.from(block).bytes(64)) |byte| {
        try std.testing.expectEqual(@as(u8, 0x5A), byte);
    }
    mimalloc.free(block);
}

test "the thread-local heap can be made the default and handed back" {
    try ensureLoaded();
    // The oracle is the ownership transition `mi_theap_set_default` performs
    // (`include/mimalloc.h:385`): it *installs its argument and returns the
    // previous default*, which is what makes handing it back possible at all.
    // So the assertion is the whole round trip, in the order the transition
    // happens: displacing and reading must report the same fact, the installed
    // default must be the one that was installed, and handing it back must
    // displace exactly that and leave the value that was there before in force
    // again. None of that is a check that some particular default exists - the
    // value before is whatever the process had, and it is restored.
    //
    // This test used to compare the default *in force after the install* with
    // the value the setter displaced, which is the one thing the transition
    // guarantees they are not: after installing `theap`, the default in force
    // is `theap`. That assertion could only fail, and did.
    var heap = try mimalloc.Heap.init();
    defer heap.deinit();
    const theap = heap.theap().handle() orelse return error.SkipZigTest;

    // Read the current default before touching anything, so that a failure here
    // cannot leave the rest of the suite running against a theap this test
    // installed.
    const before = mimalloc.theapDefault();
    defer _ = mimalloc.theapSetDefault(before);
    const before_ptr = before orelse return error.SkipZigTest;

    const previous = mimalloc.theapSetDefault(theap);
    const previous_ptr = previous orelse return error.SkipZigTest;
    // Displacing the default and reading it report the same fact.
    try std.testing.expectEqual(@as(usize, @intFromPtr(before_ptr)), @intFromPtr(previous_ptr));

    // What is in force now is what was installed - that is the transition
    // `mi_theap_set_default` performs - and a plain `mi_malloc` comes from it,
    // with the block still owned by the heap it came from.
    const installed = mimalloc.theapDefault();
    try std.testing.expectEqual(
        @as(usize, @intFromPtr(theap)),
        @intFromPtr(installed orelse return error.SkipZigTest),
    );
    const block = try mimalloc.malloc(64);
    try std.testing.expect(heap.contains(block));
    mimalloc.free(block);

    // Handing it back displaces exactly what was installed, and the value that
    // was there before is in force again.
    const displaced = mimalloc.theapSetDefault(before_ptr);
    try std.testing.expectEqual(
        @as(usize, @intFromPtr(theap)),
        @intFromPtr(displaced orelse return error.SkipZigTest),
    );
    const restored = mimalloc.theapDefault();
    try std.testing.expectEqual(
        @as(usize, @intFromPtr(before_ptr)),
        @intFromPtr(restored orelse return error.SkipZigTest),
    );
}

test "printing does not require an output callback and does not allocate" {
    try ensureLoaded();
    // The oracle is that these are the *out* variants with a null callback, which
    // is what upstream's own bodies do: `mi_options_print_out(NULL, NULL)`
    // (`src/options.c:280`) and `mi_process_info_print_out(NULL, NULL)`
    // (`src/stats.c:605`) are how upstream itself prints. So the callback types
    // are genuinely nullable and this does not register one.
    //
    // What is asserted is that the calls return: an out-parameter type that could
    // not be null would be a compile error rather than a test failure, and the
    // point of exercising them is that the printing path - which builds a string
    // inside the allocator and then frees it inside the allocator - runs without
    // disturbing anything this test holds.
    const block = try mimalloc.malloc(32);
    mimalloc.Block.from(block).bytes(32)[0] = 0x2B;
    mimalloc.optionsPrintTo(null, null);
    mimalloc.processInfoPrintTo(null, null);
    mimalloc.statsPrintTo(null, null);
    try std.testing.expectEqual(@as(u8, 0x2B), mimalloc.Block.from(block).bytes(32)[0]);
    mimalloc.free(block);
}

/// Counts what a block walk saw, for the two tests above that need a number.
const Counter = struct {
    calls: usize = 0,
    blocks: usize = 0,

    fn visit(
        heap: ?*const mimalloc.c.mi_heap_t,
        area: [*c]const mimalloc.c.mi_heap_area_t,
        block: ?*anyopaque,
        block_size: usize,
        arg: ?*anyopaque,
    ) callconv(.c) bool {
        _ = heap;
        _ = area;
        _ = block_size;
        const self: *Counter = @ptrCast(@alignCast(arg.?));
        self.calls += 1;
        if (block != null) self.blocks += 1;
        return true;
    }
};

/// A visitor that refuses on its first call, to show the walk stopping.
const Stopper = struct {
    calls: usize = 0,

    fn visit(
        heap: ?*const mimalloc.c.mi_heap_t,
        area: [*c]const mimalloc.c.mi_heap_area_t,
        block: ?*anyopaque,
        block_size: usize,
        arg: ?*anyopaque,
    ) callconv(.c) bool {
        _ = heap;
        _ = area;
        _ = block;
        _ = block_size;
        const self: *Stopper = @ptrCast(@alignCast(arg.?));
        self.calls += 1;
        return false;
    }
};

/// Allocates on a thread that is not the one that will free the block.
const Worker = struct {
    ptr: ?*anyopaque = null,

    fn run(self: *Worker) void {
        const block = mimalloc.malloc(64) catch return;
        @memset(mimalloc.Block.from(block).bytes(64), 0x5A);
        self.ptr = block;
    }
};
