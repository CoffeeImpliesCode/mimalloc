// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! A consumer of the mimalloc SDK, and a check on what it allocates.
//!
//! This is a **separate package**. Its `build.zig` says only
//! `b.dependency("mimalloc", .{ .path = ".." })` and `dep.module("mimalloc")`;
//! it reaches the facade the way any downstream would, through the published
//! module name and nothing else. It deliberately does **not** ask for
//! `dep.artifact("mimalloc")`: the module already carries the compiled library,
//! and a second route to the same symbols is a second thing that can disagree
//! about which build answered.
//!
//! ## What it proves
//!
//!   * **alignment** - for a spread of alignments and sizes, the address it
//!     returns is a multiple of the alignment, and the block is writable to the
//!     full length that was asked for. The oracle is the definition of aligned.
//!   * **zeroing** - a block filled with a pattern, freed, and asked for again
//!     with `calloc` arrives with every byte zero. The oracle is C99's
//!     `calloc` contract, and the *recycled* case is the one that a fresh OS
//!     page cannot explain.
//!   * **realloc growth** - content is preserved across a growth and a shrink,
//!     which is C99 7.20.3.4's requirement, and the growth is zeroed by
//!     `rezalloc` for a block that started zeroed.
//!   * **alignment validation** - a zero or non-power-of-two alignment is
//!     refused before the allocator sees it, which matters because upstream only
//!     asserts that rule and `NDEBUG` compiles the assertion away.
//!   * **zero-size requests** - a real, freeable block rather than a null.
//!   * **the heap surface** - a heap allocates, claims what it allocated, and can
//!     be deleted with its blocks still valid; then it can be destroyed and the
//!     process still works.
//!   * **the allocator crossing** - `isRedirected` answers false, and
//!     `anyHeapContains` denies a pointer this program never gave mimalloc.
//!
//! ## What it does not prove, and why
//!
//! **No leak claim.** Every block below belongs to mimalloc, not to Zig.
//! `std.testing.allocator` can only notice a leak of memory *it* handed out,
//! because it keeps a record of its own outstanding blocks; there is no way to
//! give it a leak oracle for a third-party allocator's memory. So this program
//! frees everything it allocates - that is hygiene - and asserts nothing about
//! leaks in either direction. Nothing here is a claim that this package leaks
//! nothing, because no test in it could observe such a claim.
//!
//! ## The runtime-loaded route
//!
//! With `mimalloc.runtime_loaded`, nothing below can run until a provider is
//! named. `--provider <absolute path>` is the only way to name one, plus
//! `MIMALLOC_CONSUMER_PROVIDER` for a run that cannot pass arguments. Neither
//! falls back to the other and neither has a default: a build with no provider
//! named says so and stops, rather than quietly using a linked copy.
//!
//! In a linked build the branch does not exist at comptime, the module is already
//! usable, and nothing is read from the environment.

const std = @import("std");
const mimalloc = @import("mimalloc");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// The provider this run should load, from `--provider <path>` or from
/// `MIMALLOC_CONSUMER_PROVIDER`.
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
    return init.environ_map.get("MIMALLOC_CONSUMER_PROVIDER") orelse
        return noProvider();
}

fn noProvider() ConfigurationError {
    std.debug.print(
        "consumer: this is a runtime-loading build. Pass --provider <absolute path>, " ++
            "or export MIMALLOC_CONSUMER_PROVIDER. Nothing is loaded by default " ++
            "and no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// The alignments this program walks.
///
/// Every power of two up to and past `MI_MAX_ALIGN_SIZE` (16), plus 64 KiB -
/// `MI_PAGE_MAX_OVERALLOC_ALIGN`, above which mimalloc asks the OS for the
/// memory instead of over-allocating inside a page - and 1 MiB, past that.
const alignments = [_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 4096, 65_536, 1 << 20 };

/// The sizes this program walks: below, at and above the small maximum, around
/// the OS page size, and past the 64 KiB slice size.
const sizes = [_]usize{ 0, 1, 7, 8, 15, 16, 17, 63, 64, 65, 127, 1023, 1024, 1025, 4096, 65_536, 262_144 };

/// Fail the run, printing both sides, so a reader sees the computed value next
/// to the line that says what it should have been.
///
/// `fmt` is printed **twice**, once for each side, so it carries exactly one
/// specifier and both values must print through it. A `fmt` with two specifiers
/// asks for four arguments from a two-argument tuple, and Zig 0.16's writer
/// rejects that at compile time with `too few arguments`. Everything that
/// describes the check belongs in `what`, which is printed once; `fmt` is for the
/// one value that is the same kind on both sides.
fn fail(comptime what: []const u8, comptime fmt: []const u8, got: anytype, expected: anytype) noreturn {
    std.debug.print("consumer: " ++ what ++ ": expected " ++ fmt ++ ", computed " ++ fmt ++ "\n", .{ expected, got });
    std.process.exit(1);
}

fn check(what: []const u8, ok: bool) void {
    if (!ok) {
        std.debug.print("consumer: {s}: the check did not hold\n", .{what});
        std.process.exit(1);
    }
}

/// Alignment, with the whole cross product of the two lists above.
fn checkAlignment() void {
    for (alignments) |alignment| {
        for (sizes) |size| {
            const block = mimalloc.mallocAligned(size, alignment) catch |err| {
                fail("mallocAligned", "error {s}", @errorName(err), "a block");
            };
            defer mimalloc.free(block);
            if (@intFromPtr(block) % alignment != 0) {
                // `what` is concatenated into the format string, so it carries no
                // specifier of its own; only `fmt` does.
                fail("an address that is not on its alignment boundary", "{d}", @intFromPtr(block) % alignment, @as(usize, 0));
            }
            const bytes: [*]u8 = @ptrCast(block);
            @memset(bytes[0..size], 0xA5);
            for (bytes[0..size]) |byte| {
                if (byte != 0xA5) fail("writability", "a byte that is not {d}", byte, @as(u8, 0xA5));
            }
        }
    }
}

/// Zeroing, and in particular the recycled case.
fn checkZeroing() void {
    for (sizes) |size| {
        const dirty = mimalloc.malloc(size) catch unreachable;
        @memset(mimalloc.Block.from(dirty).bytes(size), 0xFF);
        mimalloc.free(dirty);

        const recycled = mimalloc.calloc(1, size) catch unreachable;
        defer mimalloc.free(recycled);
        for (mimalloc.Block.from(recycled).bytes(size), 0..) |byte, index| {
            if (byte != 0) {
                fail("a recycled calloc byte that is not the index it should hold", "{d}", byte, index);
            }
        }

        const zeroed = mimalloc.zalloc(size) catch unreachable;
        defer mimalloc.free(zeroed);
        for (mimalloc.Block.from(zeroed).bytes(size)) |byte| {
            if (byte != 0) fail("zalloc", "a non-zero byte {d}", byte, @as(u8, 0));
        }
    }

    // A typed, zeroed slice.
    const typed = mimalloc.allocSliceZeroed(u64, 16) catch unreachable;
    defer mimalloc.free(typed.ptr);
    check("allocSliceZeroed length", typed.len == 16);
    for (typed) |word| check("allocSliceZeroed", word == 0);
}

/// Content preservation across a growth and a shrink, plus zeroed growth.
fn checkRealloc() void {
    const block = mimalloc.calloc(1, 16) catch unreachable;
    {
        const bytes = mimalloc.Block.from(block).bytes(16);
        for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 1);
    }

    const grown = mimalloc.realloc(block, 4096) catch unreachable;
    {
        const bytes = mimalloc.Block.from(grown).bytes(16);
        for (bytes, 0..) |byte, index| {
            if (byte != @as(u8, @truncate(index *% 7 +% 1))) {
                fail("realloc growth", "a changed byte at {d}", byte, index);
            }
        }
        check("usableSize of a 4096-byte block", mimalloc.usableSize(grown) >= 4096);
    }

    const shrunk = mimalloc.realloc(grown, 4) catch unreachable;
    {
        const bytes = mimalloc.Block.from(shrunk).bytes(4);
        for (bytes, 0..) |byte, index| {
            if (byte != @as(u8, @truncate(index *% 7 +% 1))) {
                fail("realloc shrink", "a changed byte at {d}", byte, index);
            }
        }
    }
    mimalloc.free(shrunk);

    check("goodSize(4096) covers the request", mimalloc.goodSize(4096) >= 4096);
    check("goodSize(1) covers the request", mimalloc.goodSize(1) >= 1);

    // `rezalloc` zeroes the growth, on a block that started zeroed.
    const zeroed = mimalloc.calloc(1, 16) catch unreachable;
    @memset(mimalloc.Block.from(zeroed).bytes(16), 0x5A);
    const zeroed_grown = mimalloc.rezalloc(zeroed, 128) catch unreachable;
    defer mimalloc.free(zeroed_grown);
    {
        const bytes = mimalloc.Block.from(zeroed_grown).bytes(128);
        check("rezalloc kept the content", bytes[0] == 0x5A and bytes[15] == 0x5A);
        for (bytes[16..]) |byte| check("rezalloc zeroed the growth", byte == 0);
    }

    // A zero-size reallocation is a block, not a failure: upstream's own rule is
    // that a null result from `realloc` always means an error.
    const to_zero = mimalloc.malloc(64) catch unreachable;
    const zero_sized = mimalloc.realloc(to_zero, 0) catch unreachable;
    mimalloc.free(zero_sized);
}

/// An overflowing product is refused rather than truncated.
fn checkOverflow() void {
    // The block the refused call would have returned is named so that the
    // success path below can free it: this program leaves nothing allocated
    // behind it, and `calloc` returns `*anyopaque` rather than nothing.
    const unexpected = mimalloc.calloc(std.math.maxInt(usize) / 2 + 1, 4) catch {
        // Expected. A control allocation proves the process is unharmed.
        const control = mimalloc.malloc(64) catch unreachable;
        check("control allocation after a refused product", mimalloc.usableSize(control) >= 64);
        mimalloc.free(control);
        return;
    };
    mimalloc.free(unexpected);
    // `fail`'s `fmt` is printed twice, once for each side, so it carries exactly
    // one specifier. Both sides here are descriptions rather than numbers - what
    // went wrong is that an error did *not* arrive - so `{s}` is the specifier
    // that states them both.
    fail("calloc overflow", "{s}", "a block", "error.OutOfMemory");
}

/// A zero or non-power-of-two alignment never reaches the allocator.
fn checkAlignmentValidation() void {
    var refused: usize = 0;
    for ([_]usize{ 0, 3, 6, 24, 48, 100 }) |alignment| {
        if (mimalloc.mallocAligned(64, alignment)) |block| {
            mimalloc.free(block);
        } else |err| switch (err) {
            error.InvalidAlignment => refused += 1,
            error.OutOfMemory => fail("mallocAligned", "error {s}", @errorName(err), "error.InvalidAlignment"),
        }
    }
    check("every invalid alignment was refused", refused == 6);

    const control = mimalloc.malloc(64) catch unreachable;
    defer mimalloc.free(control);
    check("control allocation after six refusals", mimalloc.usableSize(control) >= 64);
}

/// A zero-size request is a real, freeable block.
fn checkZeroSize() void {
    const plain = mimalloc.malloc(0) catch unreachable;
    mimalloc.free(plain);
    const zeroed = mimalloc.zalloc(0) catch unreachable;
    mimalloc.free(zeroed);
}

/// A heap allocates, claims what it allocated, and can be deleted with its
/// blocks still valid. Then it can be destroyed and the process still works.
fn checkHeap() void {
    var heap = mimalloc.Heap.init() catch unreachable;
    check("a new heap is open", heap.isOpen());

    const block = heap.malloc(128) catch unreachable;
    @memset(mimalloc.Block.from(block).bytes(128), 0x3C);
    check("the heap contains what it allocated", heap.contains(block));
    check("some heap claims the block", mimalloc.anyHeapContains(block));
    check("mi_heap_of names a heap that contains it", mimalloc.Heap.of(block).?.contains(block));

    const aligned = heap.mallocAligned(64, 64) catch unreachable;
    check("a heap allocates an aligned block", @intFromPtr(aligned) % 64 == 0);
    mimalloc.free(aligned);

    // `mi_heap_delete` moves live blocks to the main heap rather than freeing
    // them, so they are still readable and still the caller's afterwards.
    heap.deinit();
    check("a deleted heap is closed", !heap.isOpen());
    for (mimalloc.Block.from(block).bytes(128)) |byte| {
        check("the block survived the heap's deletion", byte == 0x3C);
    }
    check("the block is still claimed", mimalloc.anyHeapContains(block));
    check("the main heap claims it now", mimalloc.Heap.main().contains(block));
    mimalloc.free(block);

    // `destroy` is the other operation and frees everything in the heap. What
    // is observable is that the process still works afterwards; the blocks
    // themselves are not read, because reading them would be a use-after-free
    // and asking `anyHeapContains` about them would ask a question upstream does
    // not define.
    var second = mimalloc.Heap.init() catch unreachable;
    for (0..16) |_| {
        const scratch = second.malloc(64) catch unreachable;
        mimalloc.free(scratch);
    }
    second.destroy();
    check("a destroyed heap is closed", !second.isOpen());
    const control = mimalloc.malloc(64) catch unreachable;
    defer mimalloc.free(control);
    check("the process still allocates", mimalloc.usableSize(control) >= 64);
}

/// The crossing itself: what this package is, and what it is not.
fn checkOwnershipBoundary() void {
    // This build never defines `MI_MALLOC_OVERRIDE`, so the artifact exports
    // `mi_malloc` and not `malloc`, nothing preloads it, and no provider in this
    // workspace has been routed through it. Upstream's own predicate for that
    // question must answer false.
    check("this build did not replace the process allocator", !mimalloc.isRedirected());

    // A pointer this program never handed to mimalloc is not claimed by it. The
    // check is upstream's page-map lookup, not a range test, which is what makes
    // it usable as an ownership question at all.
    const on_stack: u8 = 0;
    check("a stack address is not claimed", !mimalloc.anyHeapContains(&on_stack));

    // The library that answered was compiled from the header this program was
    // compiled against. This is not a version pin - no particular number is
    // asserted - it is the boundary agreeing with itself.
    check("the library reports this build's MI_MALLOC_VERSION", mimalloc.version() == mimalloc.version_num);
    check("MI_MALLOC_VERSION is 30503 for v3.5.3", mimalloc.version_num == 30503);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    if (comptime mimalloc.runtime_loaded) {
        try mimalloc.load(.{ .path = try providerRequest(init) });
    }

    try w.print("mimalloc consumer\n", .{});
    try w.print("route:      {s}\n", .{if (mimalloc.runtime_loaded) "runtime-loaded" else "linked"});
    if (mimalloc.loadedSource()) |source| {
        try w.print("provider:   {s}\n", .{switch (source) {
            .path => |p| p,
            .system => |s| s,
        }});
    }
    try w.flush();

    checkOwnershipBoundary();
    try w.print("ok: ownership boundary\n", .{});
    try w.flush();

    checkAlignment();
    try w.print("ok: alignment over {d} alignments x {d} sizes\n", .{ alignments.len, sizes.len });
    try w.flush();

    checkZeroing();
    try w.print("ok: zeroing, including recycled blocks\n", .{});
    try w.flush();

    checkRealloc();
    try w.print("ok: realloc growth, shrink and zeroed growth\n", .{});
    try w.flush();

    checkOverflow();
    try w.print("ok: an overflowing product is refused\n", .{});
    try w.flush();

    checkAlignmentValidation();
    try w.print("ok: invalid alignments refused before the allocator\n", .{});
    try w.flush();

    checkZeroSize();
    try w.print("ok: zero-size requests are freeable blocks\n", .{});
    try w.flush();

    checkHeap();
    try w.print("ok: heap create, claim, delete, destroy\n", .{});
    try w.flush();

    try w.print("\nall consumer checks agreed\n", .{});
    try w.flush();
}
