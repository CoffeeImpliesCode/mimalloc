// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! A runnable, deterministic demonstration of the mimalloc facade.
//!
//! `zig build smoke` runs this. There is no input beyond the optional provider
//! name, and no output that depends on the host, the clock or a random seed, so
//! the same lines come out every time.
//!
//! Every answer below is an **expected value**, not a value this program
//! computed and printed for comparison. An alignment is checked against
//! `addr % alignment == 0`, which is what "aligned" means and is not mimalloc's
//! definition to change; a size class is checked against the property of a
//! rounding rather than against a number; a preserved prefix is checked against
//! C99 7.20.3.4's requirement. A mismatch prints both sides and exits non-zero,
//! so this is a check and not a demo.
//!
//! In a runtime-loading build the provider is named on the command line
//! (`--provider <path>`) or in `MIMALLOC_SMOKE_PROVIDER`, and the program says
//! which configuration it is in the first lines. In a linked build neither is
//! needed and neither is read.
//!
//! What it exercises, in order: which route this build is, the version the
//! provider itself reports, whether anything in this package replaced the
//! process allocator, an aligned block, a recycled block that has to arrive
//! zeroed, a `realloc` that has to preserve its content, a size class, a heap
//! that is closed with its blocks still valid, an arena's own arithmetic, and a
//! non-power-of-two alignment that must never reach the allocator.
//!
//! It makes **no leak claim**. Every block it allocates belongs to mimalloc, and
//! a third-party allocator's memory cannot be the subject of a Zig-side leak
//! oracle: `std.testing.allocator` can only notice a leak of memory it handed
//! out. So every block below is freed, and nothing is asserted about leaks in
//! either direction.

const std = @import("std");
const mimalloc = @import("mimalloc");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// The provider this run should load, from `--provider <path>` or from
/// `MIMALLOC_SMOKE_PROVIDER`.
///
/// Both are explicit. Nothing here looks in a default location and falls back to
/// a linked copy: a runtime-loading build that was not told which file to load
/// reports that it was not told, rather than loading something else.
fn providerRequest(init: std.process.Init) ConfigurationError![]const u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return noProvider();
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return noProvider();
            return args[index + 1];
        }
    }
    return init.environ_map.get("MIMALLOC_SMOKE_PROVIDER") orelse
        return noProvider();
}

/// Say which variable is missing. An error name on its own would send the next
/// person into the loader instead of to the command line.
fn noProvider() ConfigurationError {
    std.debug.print(
        "smoke: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export MIMALLOC_SMOKE_PROVIDER with a shared object exporting the " ++
            "declarations of zig/translate.h. Nothing is loaded by default and " ++
            "no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// Prints one answer and fails the run when it is not the expected one.
///
/// `got` is printed whatever it is, so a reader of a failing run sees the
/// computed value next to the line that says what it should have been.
fn check(w: *std.Io.Writer, what: []const u8, got: anytype, expected: anytype) !void {
    try w.print("{s: <52}{any}\n", .{ what, got });
    if (!std.meta.eql(got, expected)) {
        std.debug.print(
            "smoke: {s}: expected {any}, computed {any}\n",
            .{ what, expected, got },
        );
        return error.SmokeCheckFailed;
    }
}

/// A boolean with the same shape, for the checks whose answer is a yes or a no.
fn checkFlag(w: *std.Io.Writer, what: []const u8, got: bool, expected: bool) !void {
    try w.print("{s: <52}{s}\n", .{ what, if (got) "yes" else "no" });
    if (got != expected) {
        std.debug.print(
            "smoke: {s}: expected {s}, computed {s}\n",
            .{ what, if (expected) "yes" else "no", if (got) "yes" else "no" },
        );
        return error.SmokeCheckFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // In a runtime-loading build nothing below can run until a provider is
    // loaded, and the load is the one explicit step the contract asks for. In a
    // linked build this branch does not exist at comptime and the module is
    // already usable.
    if (comptime mimalloc.runtime_loaded) {
        try mimalloc.load(.{ .path = try providerRequest(init) });
    }

    try w.print("mimalloc smoke\n", .{});
    try w.print("{s: <52}{s}\n", .{
        "route",
        if (mimalloc.runtime_loaded) "runtime-loaded" else "linked",
    });
    if (mimalloc.loadedSource()) |source| {
        try w.print("{s: <52}{s}\n", .{ "provider", switch (source) {
            .path => |p| p,
            .system => |s| s,
        } });
    }
    try w.flush();

    // The library's own answer against this build's header. In a runtime-loaded
    // build the first value is the provider's own rather than a constant
    // compiled into this program, so it is a fact about the provider.
    //
    // This is not a version pin. Nothing here asserts a particular number, and
    // there is deliberately no line that prints one and compares it with another
    // copy of the same constant - that would only prove the program agrees with
    // itself. The pin lives in `UPSTREAM.md` and is checked by
    // `tools/check-provenance.sh`; what this line proves is that the library that
    // answered was compiled from the header this program was compiled against.
    try check(w, "the library reports this build's MI_MALLOC_VERSION", mimalloc.version(), mimalloc.version_num);

    // The one fact that says what this package is not. `MI_MALLOC_OVERRIDE` is
    // never defined by `build.zig`, so the artifact exports `mi_malloc` and not
    // `malloc`, nothing preloads it, and no provider has been routed through it.
    // Upstream's own predicate for that question must answer false here; see
    // `README.md`, "This package does not replace your allocator".
    try checkFlag(w, "this build replaced the process allocator", mimalloc.isRedirected(), false);

    // An alignment, checked against the definition. `(size, alignment)` is the
    // order every entry point in this package takes, and it is the reverse of
    // `posix_memalign`'s - see `README.zig.md`.
    {
        const alignment: usize = 256;
        const block = try mimalloc.mallocAligned(300, alignment);
        defer mimalloc.free(block);
        @memset(mimalloc.Block.from(block).bytes(300), 0x11);
        try check(w, "256-byte alignment of a 300-byte block", @intFromPtr(block) % alignment, @as(usize, 0));
        try check(w, "that block can be written to its full length", mimalloc.usableSize(block) >= 300, true);
    }

    // A recycled block has to arrive zeroed. Fresh pages are zero, so a block
    // that is merely fresh would prove nothing; this one is filled, freed, and
    // asked for again at the same size.
    {
        const dirty = try mimalloc.malloc(128);
        @memset(mimalloc.Block.from(dirty).bytes(128), 0xFF);
        mimalloc.free(dirty);

        const recycled = try mimalloc.calloc(1, 128);
        defer mimalloc.free(recycled);
        var still_dirty: usize = 0;
        for (mimalloc.Block.from(recycled).bytes(128)) |byte| {
            if (byte != 0) still_dirty += 1;
        }
        try check(w, "non-zero bytes in a recycled calloc block", still_dirty, @as(usize, 0));
    }

    // `realloc` has to keep the content, which is C99's requirement and not
    // mimalloc's. The address is not checked: upstream returns the same pointer
    // whenever the request fits (`src/alloc.c:483`).
    {
        const block = try mimalloc.calloc(1, 16);
        for (mimalloc.Block.from(block).bytes(16), 0..) |*byte, index| {
            byte.* = @truncate(index +% 1);
        }
        const grown = try mimalloc.realloc(block, 1024);
        defer mimalloc.free(grown);
        var mismatches: usize = 0;
        for (mimalloc.Block.from(grown).bytes(16), 0..) |byte, index| {
            if (byte != @as(u8, @truncate(index +% 1))) mismatches += 1;
        }
        try check(w, "bytes changed by realloc(16 -> 1024)", mismatches, @as(usize, 0));
    }

    // A size class is a rounding: it never rounds down, and it never steps
    // backwards as the request grows. It is **not** idempotent, and upstream
    // says so by construction: `mi_good_size` looks the bin up for
    // `size + MI_PADDING_SIZE` (`src/page-queue.c:116`) and reports that bin's
    // block size, so the answer describes a larger request than the one asked
    // about - `goodSize(100)` is 112 and `goodSize(112)` is 128 here, and every
    // one of 1..4096 moves on a second pass. Pinning a particular bin size
    // would be pinning a default constant, which is not what this program is
    // for.
    //
    // What is checked instead, besides the round-up, is the promise the name
    // makes: the block served for a rounded request is at least that request.
    {
        const sizes = [_]usize{ 0, 1, 17, 64, 100, 1024, 4097, 65_537, 262_144 };
        var previous: usize = 0;
        var not_rounding_up: usize = 0;
        var stepped_back: usize = 0;
        var shrank_again: usize = 0;
        var short_blocks: usize = 0;
        for (sizes, 0..) |size, index| {
            const rounded = mimalloc.goodSize(size);
            if (rounded < size) not_rounding_up += 1;
            if (index > 0 and rounded < previous) stepped_back += 1;
            previous = rounded;
            if (mimalloc.goodSize(rounded) < rounded) shrank_again += 1;
            const block = try mimalloc.malloc(rounded);
            if (mimalloc.usableSize(block) < rounded) short_blocks += 1;
            mimalloc.free(block);
        }
        try check(w, "goodSize never rounds a request down", not_rounding_up, @as(usize, 0));
        try check(w, "goodSize never steps backwards as the request grows", stepped_back, @as(usize, 0));
        try check(w, "goodSize never shrinks when fed its own answer", shrank_again, @as(usize, 0));
        try check(w, "usableSize is at least the goodSize it was asked for", short_blocks, @as(usize, 0));
    }

    // A heap, and the ownership transition that is easy to get wrong:
    // `mi_heap_delete` moves live blocks to the main heap rather than freeing
    // them (`include/mimalloc.h:243`), so they are still readable and still the
    // caller's afterwards.
    {
        var heap = try mimalloc.Heap.init();
        const block = try heap.malloc(64);
        @memset(mimalloc.Block.from(block).bytes(64), 0x5A);
        try checkFlag(w, "a heap contains what it allocated", heap.contains(block), true);

        heap.deinit();
        var intact: usize = 0;
        for (mimalloc.Block.from(block).bytes(64)) |byte| {
            if (byte == 0x5A) intact += 1;
        }
        try check(w, "bytes still readable after the heap was deleted", intact, @as(usize, 64));
        try checkFlag(w, "the block is still claimed by a heap", mimalloc.anyHeapContains(block), true);
        mimalloc.free(block);
    }

    // An arena's own arithmetic: the minimum size is a whole number of slices,
    // and a slice is what the arena is aligned to.
    try check(w, "an arena's minimum alignment is positive", mimalloc.arenaMinAlignment() > 0, true);
    try check(w, "an arena's minimum size is positive", mimalloc.arenaMinSize() > 0, true);
    try check(w, "an unknown arena has no region", mimalloc.arenaArea(null) == null, true);

    // An alignment upstream only asserts. `MI_PADDING` and the optimize mode
    // change whether `mi_assert_internal` is compiled in at all, so this is
    // checked in this facade, before the allocator sees anything.
    {
        var refused: usize = 0;
        for ([_]usize{ 0, 3, 6, 24, 48 }) |alignment| {
            if (mimalloc.mallocAligned(64, alignment)) |block| {
                mimalloc.free(block);
            } else |err| {
                if (err == error.InvalidAlignment) refused += 1;
            }
        }
        try check(w, "invalid alignments refused before the allocator", refused, @as(usize, 5));
    }

    try w.print("\nall mimalloc smoke checks agreed\n", .{});
    try w.flush();
}
