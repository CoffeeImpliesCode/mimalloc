// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Deterministic smoke checks for the mimalloc facade.
//! Runtime-loaded mode requires `--provider <path>` or `MIMALLOC_SMOKE_PROVIDER`.

const std = @import("std");
const mimalloc = @import("mimalloc");

const ConfigurationError = error{NoProviderConfigured};

/// Read an explicit provider request for runtime-loaded builds.
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

/// Print a value and return an error when it differs from the expected value.
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

    try check(w, "the library reports this build's MI_MALLOC_VERSION", mimalloc.version(), mimalloc.version_num);

    try checkFlag(w, "this build replaced the process allocator", mimalloc.isRedirected(), false);

    {
        const alignment: usize = 256;
        const block = try mimalloc.mallocAligned(300, alignment);
        defer mimalloc.free(block);
        @memset(mimalloc.Block.from(block).bytes(300), 0x11);
        try check(w, "256-byte alignment of a 300-byte block", @intFromPtr(block) % alignment, @as(usize, 0));
        try check(w, "that block can be written to its full length", mimalloc.usableSize(block) >= 300, true);
    }

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

    // Check the preserved prefix; realloc may return the original address.
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

    // Deleting a heap moves live blocks to the main heap.
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

    try check(w, "an arena's minimum alignment is positive", mimalloc.arenaMinAlignment() > 0, true);
    try check(w, "an arena's minimum size is positive", mimalloc.arenaMinSize() > 0, true);
    try check(w, "an unknown arena has no region", mimalloc.arenaArea(null) == null, true);

    // Reject invalid alignments before mimalloc's debug-only check.
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
