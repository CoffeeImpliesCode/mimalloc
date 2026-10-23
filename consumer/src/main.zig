// SPDX-License-Identifier: MIT
const std = @import("std");
const mimalloc = @import("mimalloc");

const ConfigurationError = error{NoProviderConfigured};

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

const alignments = [_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 4096, 65_536, 1 << 20 };

/// `fmt` is used twice, so pass one specifier for both values.
const sizes = [_]usize{ 0, 1, 7, 8, 15, 16, 17, 63, 64, 65, 127, 1023, 1024, 1025, 4096, 65_536, 262_144 };
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

    const typed = mimalloc.allocSliceZeroed(u64, 16) catch unreachable;
    defer mimalloc.free(typed.ptr);
    check("allocSliceZeroed length", typed.len == 16);
    for (typed) |word| check("allocSliceZeroed", word == 0);
}

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

    // Verify `rezalloc` zeroes growth from a zeroed block.
    const zeroed = mimalloc.calloc(1, 16) catch unreachable;
    @memset(mimalloc.Block.from(zeroed).bytes(16), 0x5A);
    const zeroed_grown = mimalloc.rezalloc(zeroed, 128) catch unreachable;
    defer mimalloc.free(zeroed_grown);
    {
        const bytes = mimalloc.Block.from(zeroed_grown).bytes(128);
        check("rezalloc kept the content", bytes[0] == 0x5A and bytes[15] == 0x5A);
        for (bytes[16..]) |byte| check("rezalloc zeroed the growth", byte == 0);
    }

    // A null `realloc` result means error, so a zero-size success must return a block.
    const to_zero = mimalloc.malloc(64) catch unreachable;
    const zero_sized = mimalloc.realloc(to_zero, 0) catch unreachable;
    mimalloc.free(zero_sized);
}

/// An overflowing allocation product must return `OutOfMemory`.
fn checkOverflow() void {
    // Free an unexpectedly successful result before failing the check.
    const unexpected = mimalloc.calloc(std.math.maxInt(usize) / 2 + 1, 4) catch {
        // Verify the process can still allocate after the rejected overflow.
        const control = mimalloc.malloc(64) catch unreachable;
        check("control allocation after a refused product", mimalloc.usableSize(control) >= 64);
        mimalloc.free(control);
        return;
    };
    mimalloc.free(unexpected);
    fail("calloc overflow", "{s}", "a block", "error.OutOfMemory");
}

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

fn checkZeroSize() void {
    const plain = mimalloc.malloc(0) catch unreachable;
    mimalloc.free(plain);
    const zeroed = mimalloc.zalloc(0) catch unreachable;
    mimalloc.free(zeroed);
}

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

    // `mi_heap_delete` moves live blocks to the main heap; it does not free them.
    heap.deinit();
    check("a deleted heap is closed", !heap.isOpen());
    for (mimalloc.Block.from(block).bytes(128)) |byte| {
        check("the block survived the heap's deletion", byte == 0x3C);
    }
    check("the block is still claimed", mimalloc.anyHeapContains(block));
    check("the main heap claims it now", mimalloc.Heap.main().contains(block));
    mimalloc.free(block);

    // `destroy` frees remaining blocks; do not inspect them afterward.
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

fn checkOwnershipBoundary() void {
    // `MI_MALLOC_OVERRIDE` is unset, so this SDK does not replace the process allocator.
    check("this build did not replace the process allocator", !mimalloc.isRedirected());

    const on_stack: u8 = 0;
    check("a stack address is not claimed", !mimalloc.anyHeapContains(&on_stack));

    // Check provider/header agreement; the next check pins version 3.5.3.
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
