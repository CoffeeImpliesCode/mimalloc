// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Behavioral tests for the mimalloc facade.
//! Runtime-loaded tests require `MIMALLOC_PROVIDER` to name an absolute library path.

const std = @import("std");
const builtin = @import("builtin");
const mimalloc = @import("mimalloc");

const provider_variable = "MIMALLOC_PROVIDER";

/// Load the provider for runtime-loaded builds.
fn ensureLoaded() !void {
    if (!mimalloc.runtime_loaded) return;
    const named = std.c.getenv(provider_variable) orelse return error.ProviderNotNamed;
    try mimalloc.load(.{ .path = std.mem.span(named) });
}

/// Sizes span allocation, page, and large-object boundaries.
const probe_sizes = [_]usize{ 0, 1, 2, 7, 8, 15, 16, 17, 63, 64, 65, 127, 128, 255, 256, 1023, 1024, 1025, 4095, 4096, 4097, 65_535, 65_536, 65_537, 262_144 };

/// Alignments span mimalloc's small-block and page-overallocation limits.
const probe_alignments = [_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 4096, 65_536, 1 << 20 };

test "runtime loading does not require allocator override entry points" {
    if (!mimalloc.runtime_loaded) return;
    for ([_][]const u8{ "mi_malloc_size", "mi_malloc_usable_size" }) |name| {
        for (mimalloc.c.symbols) |symbol| {
            try std.testing.expect(!std.mem.eql(u8, name, symbol.name));
        }
        var optional = false;
        for (mimalloc.c.optional_symbols) |symbol| {
            if (std.mem.eql(u8, name, symbol.name)) optional = true;
        }
        try std.testing.expect(optional);
    }
}

test "the linked library agrees with the header it was compiled against" {
    try ensureLoaded();
    try std.testing.expectEqual(mimalloc.version_num, mimalloc.version());
}

test "this package does not replace the process allocator" {
    try ensureLoaded();
    try std.testing.expect(!mimalloc.isRedirected());
}

test "every size is honoured, and the usable size is at least the request" {
    try ensureLoaded();
    for (probe_sizes) |size| {
        const block = try mimalloc.malloc(size);
        defer mimalloc.free(block);
        const usable = mimalloc.usableSize(block);
        try std.testing.expect(usable >= size);
    }
}

test "a zero-size request is a real, freeable block" {
    try ensureLoaded();
    const block = try mimalloc.malloc(0);
    mimalloc.free(block);

    const zeroed = try mimalloc.zalloc(0);
    mimalloc.free(zeroed);
}

test "freeing a null pointer changes nothing" {
    try ensureLoaded();
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
            const address = @intFromPtr(block);
            try std.testing.expectEqual(@as(usize, 0), address % alignment);
            const bytes: [*]u8 = @ptrCast(block);
            @memset(bytes[0..size], 0xA5);
            for (bytes[0..size]) |byte| try std.testing.expectEqual(@as(u8, 0xA5), byte);
        }
    }
}

test "an aligned block at an offset puts the offset on the boundary" {
    try ensureLoaded();
    // Offsets stay word-aligned because mimalloc's debug page lookup requires it.
    // `usableSize` guarantees `size`, not `offset + size`.
    for (probe_alignments) |alignment| {
        if (alignment > 65_536) continue;
        for ([_]usize{ 8, 24, 56 }) |offset| {
            const size = 256;
            const block = try mimalloc.mallocAlignedAt(size, alignment, offset);
            defer mimalloc.free(block);
            const address = @intFromPtr(block);
            try std.testing.expectEqual(@as(usize, 0), (address + offset) % alignment);
            try std.testing.expect(mimalloc.usableSize(block) >= size);
        }
    }
}

test "an alignment that is zero or not a power of two never reaches the allocator" {
    try ensureLoaded();
    // Reject invalid alignments before mimalloc's debug-only assertion.
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
        const zeroed = try mimalloc.calloc(1, size);
        defer mimalloc.free(zeroed);
        for (mimalloc.Block.from(zeroed).bytes(size)) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }

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
    const typed = try mimalloc.allocSliceZeroed(u64, 16);
    defer mimalloc.free(typed.ptr);
    try std.testing.expectEqual(@as(usize, 16), typed.len);
    for (typed) |word| try std.testing.expectEqual(@as(u64, 0), word);
}

test "an overflowing product is refused rather than truncated" {
    try ensureLoaded();
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

    const zero = try mimalloc.calloc(0, std.math.maxInt(usize));
    mimalloc.free(zero);
}

test "realloc preserves the content of the block it resizes" {
    try ensureLoaded();
    // Free only the final pointer; realloc may return the original block.
    const block = try mimalloc.calloc(1, 16);
    {
        const bytes = mimalloc.Block.from(block).bytes(16);
        for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 1);
    }

    const grown = try mimalloc.realloc(block, 4096);
    {
        const bytes = mimalloc.Block.from(grown).bytes(16);
        for (bytes, 0..) |byte, index| try std.testing.expectEqual(@as(u8, @truncate(index *% 7 +% 1)), byte);
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
    // `rezalloc` requires a block that was zero-initialized.
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
    const block = try mimalloc.malloc(64);
    const zeroed = try mimalloc.realloc(block, 0);
    mimalloc.free(zeroed);
}

test "expand refuses a size the block cannot hold, and returns the block when it can" {
    try ensureLoaded();
    // Debug `MI_PADDING` can disable growth; assert only null or same-pointer results.
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
    var previous: usize = 0;
    for (probe_sizes, 0..) |size, index| {
        const rounded = mimalloc.goodSize(size);
        try std.testing.expect(rounded >= size);
        if (index > 0) try std.testing.expect(rounded >= previous);
        previous = rounded;
        try std.testing.expect(mimalloc.goodSize(rounded) >= rounded);

        const block = try mimalloc.malloc(rounded);
        defer mimalloc.free(block);
        try std.testing.expect(mimalloc.usableSize(block) >= rounded);
    }
}

test "strdup copies the bytes and strndup truncates at n and at a NUL" {
    try ensureLoaded();
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

    const over = try mimalloc.strndup(source, source.len * 4);
    defer mimalloc.free(over);
    try std.testing.expectEqualStrings(source, std.mem.span(@as([*:0]const u8, over)));

    const embedded = try mimalloc.strndup("ab\x00cd", 5);
    defer mimalloc.free(embedded);
    try std.testing.expectEqualStrings("ab", std.mem.span(@as([*:0]const u8, embedded)));
}

test "realpath resolves to an absolute path with no dot components left in it" {
    try ensureLoaded();
    var buffer: [8192]u8 = undefined;
    const resolved = mimalloc.realpathInto(".", &buffer) orelse
        return error.SkipZigTest;
    try std.testing.expect(std.Io.Dir.path.isAbsolute(resolved));
    try std.testing.expect(std.mem.indexOf(u8, resolved, "..") == null);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "/./") == null);

    const owned = try mimalloc.realpath(".");
    defer mimalloc.free(owned);
    try std.testing.expectEqualStrings(resolved, std.mem.span(@as([*:0]const u8, owned)));
}

test "a block is owned by exactly one heap, and the main heap owns a plain one" {
    try ensureLoaded();
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
    const on_stack: u8 = 0;
    try std.testing.expect(!mimalloc.anyHeapContains(&on_stack));
    try std.testing.expect(!mimalloc.isInHeapRegion(&on_stack));
}

test "a heap can be created, used, and deleted with its blocks still valid" {
    try ensureLoaded();
    // Deleting a heap moves live blocks to the main heap; callers still own them.
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

    for (mimalloc.Block.from(block).bytes(128)) |byte| {
        try std.testing.expectEqual(@as(u8, 0x3C), byte);
    }
    try std.testing.expect(mimalloc.anyHeapContains(block));
    try std.testing.expect(mimalloc.Heap.main().contains(block));
    mimalloc.free(block);
}

test "a second deinit on a closed heap is a no-op, not a second delete" {
    try ensureLoaded();
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
    // Check live blocks before destroy; do not inspect freed addresses afterward.
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
    var heap = try mimalloc.Heap.init();
    defer heap.deinit();
    for (0..16) |_| _ = try heap.malloc(64);

    var stopper = Stopper{};
    try std.testing.expect(!heap.visitBlocks(true, Stopper.visit, &stopper));
    try std.testing.expectEqual(@as(usize, 1), stopper.calls);
}

test "a heap allocates aligned blocks from its own arena" {
    try ensureLoaded();
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
    // Minimum size and alignment are independent; do not compare them.
    // Reservation may fail for host resource limits, so this test skips on errors.
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
}

test "an unknown arena has no region and contains nothing" {
    try ensureLoaded();
    try std.testing.expectEqual(@as(?mimalloc.ArenaArea, null), mimalloc.arenaArea(null));
    try std.testing.expect(!mimalloc.arenaContains(null, &arena_probe));
}

var arena_probe: u8 = 0;

test "the size-valued options report bytes and not the kibibytes they store" {
    try ensureLoaded();
    const reserve = mimalloc.optionGetSize(.arena_reserve);
    const max_object = mimalloc.optionGetSize(.arena_max_object_size);
    try std.testing.expect(reserve > 0);
    try std.testing.expect(max_object > 0);
    try std.testing.expectEqual(reserve, @as(usize, @intCast(mimalloc.optionGet(.arena_reserve))) * 1024);
    try std.testing.expectEqual(max_object, @as(usize, @intCast(mimalloc.optionGet(.arena_max_object_size))) * 1024);

    // The option is clamped, so a larger limit must not lower this value.
    try std.testing.expect(mimalloc.arenaMaxObjectSize() > 0);
    const original_max_object = mimalloc.optionGet(.arena_max_object_size);
    defer mimalloc.optionSet(.arena_max_object_size, original_max_object);
    const before_raise = mimalloc.arenaMaxObjectSize();
    mimalloc.optionSet(.arena_max_object_size, std.math.maxInt(c_long));
    try std.testing.expect(mimalloc.arenaMaxObjectSize() >= before_raise);
    // Restore the process-wide option before the final assertions.
    mimalloc.optionSet(.arena_max_object_size, original_max_object);
    try std.testing.expectEqual(original_max_object, mimalloc.optionGet(.arena_max_object_size));
}

test "an option can be written and read back, and put back the way it was" {
    try ensureLoaded();
    const original = mimalloc.optionGet(.max_warnings);
    const toggled: c_long = if (original == 0) 7 else 0;
    mimalloc.optionSet(.max_warnings, toggled);
    try std.testing.expectEqual(toggled, mimalloc.optionGet(.max_warnings));
    mimalloc.optionSet(.max_warnings, original);
    try std.testing.expectEqual(original, mimalloc.optionGet(.max_warnings));
}

test "the process figures are self-consistent when they are read together" {
    try ensureLoaded();
    // RSS and commit counters use different sources; assert no ordering between them.
    const info = mimalloc.processInfo();
    try std.testing.expect(info.peak_commit >= info.current_commit);
    try std.testing.expect(info.current_commit > 0);
    try std.testing.expect(info.current_rss > 0);
    try std.testing.expect(info.peak_rss > 0);
    try std.testing.expect(info.peak_commit > 0);
}

test "collecting and resetting statistics leave the allocator usable" {
    try ensureLoaded();
    const block = try mimalloc.malloc(96);
    mimalloc.Block.from(block).bytes(96)[0] = 0x77;
    mimalloc.collect(true);
    try std.testing.expectEqual(@as(u8, 0x77), mimalloc.Block.from(block).bytes(96)[0]);
    mimalloc.collect(false);
    mimalloc.statsReset();
    mimalloc.free(block);
}

test "a block allocated on one thread is freeable on another" {
    if (builtin.single_threaded) return error.SkipZigTest;
    try ensureLoaded();
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
    var heap = try mimalloc.Heap.init();
    defer heap.deinit();
    const theap = heap.theap().handle() orelse return error.SkipZigTest;

    // Restore the original thread default even if a later assertion fails.
    const before = mimalloc.theapDefault();
    defer _ = mimalloc.theapSetDefault(before);
    const before_ptr = before orelse return error.SkipZigTest;

    const previous = mimalloc.theapSetDefault(theap);
    const previous_ptr = previous orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, @intFromPtr(before_ptr)), @intFromPtr(previous_ptr));

    const installed = mimalloc.theapDefault();
    try std.testing.expectEqual(
        @as(usize, @intFromPtr(theap)),
        @intFromPtr(installed orelse return error.SkipZigTest),
    );
    const block = try mimalloc.malloc(64);
    try std.testing.expect(heap.contains(block));
    mimalloc.free(block);

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
    // A null output callback selects upstream's default printer.
    const block = try mimalloc.malloc(32);
    mimalloc.Block.from(block).bytes(32)[0] = 0x2B;
    mimalloc.optionsPrintTo(null, null);
    mimalloc.processInfoPrintTo(null, null);
    mimalloc.statsPrintTo(null, null);
    try std.testing.expectEqual(@as(u8, 0x2B), mimalloc.Block.from(block).bytes(32)[0]);
    mimalloc.free(block);
}

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

const Worker = struct {
    ptr: ?*anyopaque = null,

    fn run(self: *Worker) void {
        const block = mimalloc.malloc(64) catch return;
        @memset(mimalloc.Block.from(block).bytes(64), 0x5A);
        self.ptr = block;
    }
};
