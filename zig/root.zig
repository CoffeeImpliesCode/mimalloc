// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Zig facade over mimalloc's C API.
//!
//! Returned allocations belong to mimalloc; release them through its `free`, `Block`, or `Heap` APIs.
//! Runtime-loaded builds require `load` before other calls; linked builds are the default.
const std = @import("std");

/// Upstream's translated C API for the same header and library as this facade.
/// Runtime-loading builds expose the generated dispatch in this namespace.
pub const c = @import("c");

/// Loader types shared by linked and runtime-loaded builds.
const rt = @import("rt");

/// True when native symbols are resolved at runtime; this is a comptime constant.
/// Call `load` before using the facade in this configuration.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Explicit provider file path or system-library name for `load`.
/// Invalid requests return `LoadError`; there is no fallback.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Errors returned by `load`.
/// Load one explicit provider; same-request calls are idempotent and failures may be retried.
/// Concurrent calls wait; mismatched or reentrant requests return `LoadError`.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;
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

/// Return the retained provider request, or null in linked mode.
pub fn loadedSource() ?LoadSource {
    if (runtime_loaded) return c.loadedSource();
    return null;
}

/// Allocation errors detected by this facade.
pub const Error = error{
    /// The C returned NULL, including overflow in count-times-size calls.
    OutOfMemory,
    /// Zero or non-power-of-two alignment, rejected before the C call.
    InvalidAlignment,
};

/// Encoded `MI_MALLOC_VERSION` from the translated header.
pub const version_num: c_int = c.MI_MALLOC_VERSION;

/// Return the linked library's version, or the loaded provider's version.
pub fn version() c_int {
    return c.mi_version();
}

/// Report whether the provider serves the process's standard `malloc`.
/// This build leaves `MI_MALLOC_OVERRIDE` undefined; runtime mode reports provider state.
pub fn isRedirected() bool {
    return c.mi_is_redirected();
}

// mimalloc asserts this rule only in debug builds, so the facade checks it in all modes.
fn checkedAlignment(alignment: usize) Error!usize {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;
    return alignment;
}

// `mi_malloc` and related functions return mimalloc-owned pointers; use `free`.

/// Allocate `size` bytes; release the result with `free`.
/// Zero-size allocation may return a valid block; NULL returns `OutOfMemory`.
pub fn malloc(size: usize) Error!*anyopaque {
    return c.mi_malloc(size) orelse error.OutOfMemory;
}

/// Allocate and zero `size` bytes; NULL returns `OutOfMemory`.
pub fn zalloc(size: usize) Error!*anyopaque {
    return c.mi_zalloc(size) orelse error.OutOfMemory;
}

/// Allocate and zero `count * size` bytes; NULL returns `OutOfMemory`.
/// Product overflow also returns `OutOfMemory`.
pub fn calloc(count: usize, size: usize) Error!*anyopaque {
    return c.mi_calloc(count, size) orelse error.OutOfMemory;
}

/// Allocate uninitialized `count * size` bytes; overflow returns `OutOfMemory`.
pub fn mallocn(count: usize, size: usize) Error!*anyopaque {
    return c.mi_mallocn(count, size) orelse error.OutOfMemory;
}

/// Allocate through the small-block path; NULL returns `OutOfMemory`.
/// Sizes are not checked; `free` can release the result.
pub fn mallocSmall(size: usize) Error!*anyopaque {
    return c.mi_malloc_small(size) orelse error.OutOfMemory;
}

/// Allocate a zeroed block through the small-block path.
pub fn zallocSmall(size: usize) Error!*anyopaque {
    return c.mi_zalloc_small(size) orelse error.OutOfMemory;
}

/// Resize a block; failure leaves it valid, and null input behaves like `malloc`.
/// Zero-size requests may return a valid block; NULL returns `OutOfMemory`.
pub fn realloc(block: ?*anyopaque, new_size: usize) Error!*anyopaque {
    return c.mi_realloc(block, new_size) orelse error.OutOfMemory;
}

/// Resize an uninitialized `count * size` allocation; failure leaves the block valid.
pub fn reallocn(block: ?*anyopaque, count: usize, size: usize) Error!*anyopaque {
    return c.mi_reallocn(block, count, size) orelse error.OutOfMemory;
}

/// Resize a block and free it on failure; otherwise follows `realloc` semantics.
/// NULL returns `OutOfMemory`.
pub fn reallocFree(block: ?*anyopaque, new_size: usize) Error!*anyopaque {
    return c.mi_reallocf(block, new_size) orelse error.OutOfMemory;
}

/// Resize a zero-initialized block and zero the growth; failure leaves it valid.
/// NULL returns `OutOfMemory`.
pub fn rezalloc(block: ?*anyopaque, new_size: usize) Error!*anyopaque {
    return c.mi_rezalloc(block, new_size) orelse error.OutOfMemory;
}

/// Resize a zero-initialized `count * size` allocation and zero its growth.
pub fn recalloc(block: ?*anyopaque, newcount: usize, size: usize) Error!*anyopaque {
    return c.mi_recalloc(block, newcount, size) orelse error.OutOfMemory;
}

/// Grow a block in place; null means it could not grow, not an error.
/// `MI_PADDING` may disable growth.
pub fn expand(block: ?*anyopaque, new_size: usize) ?*anyopaque {
    return c.mi_expand(block, new_size);
}

/// Return a mimalloc pointer; null is accepted.
/// Do not pass a pointer owned by another allocator.
pub fn free(block: ?*anyopaque) void {
    c.mi_free(block);
}

/// Free a mimalloc pointer with a size hint; the size is not a contract.
/// Use `free` when the size is unknown or untrusted.
pub fn freeSize(block: ?*anyopaque, size: usize) void {
    c.mi_free_size(block, size);
}

/// Free a pointer from `mallocSmall` or `zallocSmall`; null is accepted.
pub fn freeSmall(block: ?*anyopaque) void {
    c.mi_free_small(block);
}

/// Free a non-null pointer from the small-block allocation path.
pub fn freeSmallNonnull(block: *anyopaque) void {
    c.mi_free_small_nonnull(block);
}

/// Return the usable bytes in a non-null pointer returned by mimalloc.
/// Passing a foreign pointer is undefined in release builds.
pub fn usableSize(block: *const anyopaque) usize {
    return c.mi_usable_size(block);
}

/// Return mimalloc's size-class or page rounding for a request.
/// Requests above `MI_MAX_ALLOC_SIZE` are returned unchanged.
pub fn goodSize(size: usize) usize {
    return c.mi_good_size(size);
}

/// Duplicate a NUL-terminated string; the returned storage belongs to mimalloc.
/// NULL returns `OutOfMemory`; release the result with `free`.
pub fn strdup(s: [:0]const u8) Error![*:0]u8 {
    return c.mi_strdup(s.ptr) orelse error.OutOfMemory;
}

/// Duplicate up to `n` bytes, stopping at NUL; storage belongs to mimalloc.
/// NULL returns `OutOfMemory`; release the result with `free`.
pub fn strndup(s: [:0]const u8, n: usize) Error![*:0]u8 {
    return c.mi_strndup(s.ptr, n) orelse error.OutOfMemory;
}

/// Resolve a path into a NUL-terminated buffer owned by mimalloc.
/// NULL returns `OutOfMemory`; release the result with `free`.
pub fn realpath(fname: [:0]const u8) Error![*:0]u8 {
    return c.mi_realpath(fname.ptr, null) orelse error.OutOfMemory;
}

/// Resolve a path into caller-owned `buffer`; it must hold a `PATH_MAX` path.
/// Return null when the path cannot be resolved.
pub fn realpathInto(fname: [:0]const u8, buffer: []u8) ?[]u8 {
    // The buffer receives a NUL-terminated path.
    if (c.mi_realpath(fname.ptr, @ptrCast(buffer.ptr)) == null) return null;
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}

/// Allocate `size` bytes at `alignment`; invalid alignment returns `InvalidAlignment`.
/// NULL returns `OutOfMemory`.
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

/// Place the block so `offset` bytes into it sit on an alignment boundary.
/// Invalid alignment returns `InvalidAlignment`; NULL returns `OutOfMemory`.
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

/// Resize an aligned block; failure leaves the old block valid.
/// Invalid alignment returns `InvalidAlignment`; NULL returns `OutOfMemory`.
pub fn reallocAligned(block: ?*anyopaque, new_size: usize, alignment: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_realloc_aligned(block, new_size, alignment) orelse error.OutOfMemory;
}

/// `mi_realloc_aligned_at` (`include/mimalloc.h:161`).
pub fn reallocAlignedAt(block: ?*anyopaque, new_size: usize, alignment: usize, offset: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_realloc_aligned_at(block, new_size, alignment, offset) orelse error.OutOfMemory;
}

/// Resize a zeroed aligned block and zero its growth.
pub fn rezallocAligned(block: ?*anyopaque, new_size: usize, alignment: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_rezalloc_aligned(block, new_size, alignment) orelse error.OutOfMemory;
}

/// `mi_rezalloc_aligned_at` (`include/mimalloc.h:289`).
pub fn rezallocAlignedAt(block: ?*anyopaque, new_size: usize, alignment: usize, offset: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_rezalloc_aligned_at(block, new_size, alignment, offset) orelse error.OutOfMemory;
}

/// Resize a zeroed aligned block to `newcount * size` and zero its growth.
pub fn recallocAligned(block: ?*anyopaque, newcount: usize, size: usize, alignment: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_recalloc_aligned(block, newcount, size, alignment) orelse error.OutOfMemory;
}

/// `mi_recalloc_aligned_at` (`include/mimalloc.h:291`).
pub fn recallocAlignedAt(block: ?*anyopaque, newcount: usize, size: usize, alignment: usize, offset: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_recalloc_aligned_at(block, newcount, size, alignment, offset) orelse error.OutOfMemory;
}

/// Free an aligned block, passing its alignment for the fast path.
/// `free` also accepts the pointer without alignment.
pub fn freeAligned(block: ?*anyopaque, alignment: usize) void {
    c.mi_free_aligned(block, alignment);
}

/// Free an aligned block with a size hint; size is not a contract.
pub fn freeSizeAligned(block: ?*anyopaque, size: usize, alignment: usize) void {
    c.mi_free_size_aligned(block, size, alignment);
}

/// POSIX `aligned_alloc` spelling with `(alignment, size)` argument order.
/// Invalid alignment returns `InvalidAlignment`; NULL returns `OutOfMemory`.
pub fn alignedAlloc(alignment: usize, size: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_aligned_alloc(alignment, size) orelse error.OutOfMemory;
}

/// Historical POSIX `memalign` spelling; same argument order as `alignedAlloc`.
/// Invalid alignment returns `InvalidAlignment`; NULL returns `OutOfMemory`.
pub fn memalign(alignment: usize, size: usize) Error!*anyopaque {
    _ = try checkedAlignment(alignment);
    return c.mi_memalign(alignment, size) orelse error.OutOfMemory;
}

/// Allocate `size` bytes at the platform's page alignment.
pub fn valloc(size: usize) Error!*anyopaque {
    return c.mi_valloc(size) orelse error.OutOfMemory;
}

/// Page-aligned allocation with size rounded up to a page multiple.
pub fn pvalloc(size: usize) Error!*anyopaque {
    return c.mi_pvalloc(size) orelse error.OutOfMemory;
}

/// Allocate `n` elements of `T`; the product is overflow-checked.
/// `T` must fit `MI_MAX_ALIGN_SIZE`; use `allocSliceAligned` otherwise.
pub fn allocSlice(comptime T: type, n: usize) Error![]T {
    const total = std.math.mul(usize, n, @sizeOf(T)) catch return error.OutOfMemory;
    const raw = try malloc(total);
    return (@as([*]T, @ptrCast(@alignCast(raw))))[0..n];
}

/// Allocate `n` zeroed elements of `T`; the product is overflow-checked.
pub fn allocSliceZeroed(comptime T: type, n: usize) Error![]T {
    const total = std.math.mul(usize, n, @sizeOf(T)) catch return error.OutOfMemory;
    const raw = try zalloc(total);
    return (@as([*]T, @ptrCast(@alignCast(raw))))[0..n];
}

/// Allocate `n` elements of `T` at comptime `alignment`.
/// The result has that alignment; safe builds check the raw pointer.
pub fn allocSliceAligned(comptime T: type, comptime alignment: usize, n: usize) Error![]align(alignment) T {
    const total = std.math.mul(usize, n, @sizeOf(T)) catch return error.OutOfMemory;
    const raw = try mallocAligned(total, alignment);
    const bytes: [*]align(alignment) u8 = @ptrCast(@alignCast(raw));
    const typed: [*]align(alignment) T = @ptrCast(bytes);
    return typed[0..n];
}

// Avoid ambiguous file-scope names inside `Block` methods.
const block_zalloc = zalloc;
const block_calloc = calloc;
const block_usable_size = usableSize;
const block_realloc = realloc;

/// A copyable mimalloc block. Call `deinit` once; do not pass it to a Zig allocator.
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

    /// View `len` writable bytes; the length is caller-supplied, not `usableSize`.
    pub fn bytes(self: Block, len: usize) []u8 {
        return (@as([*]u8, @ptrCast(self.ptr)))[0..len];
    }

    /// View `len` elements of `T`; safe builds check the pointer alignment.
    pub fn bytesAs(self: Block, comptime T: type, len: usize) []T {
        return (@as([*]T, @ptrCast(@alignCast(self.ptr))))[0..len];
    }

    /// How many bytes this block really has, as `usableSize` reports it.
    pub fn usableSize(self: Block) usize {
        return block_usable_size(self.ptr);
    }

    /// Resize this block; on failure, it remains valid.
    pub fn realloc(self: Block, new_size: usize) Error!Block {
        return .{ .ptr = try block_realloc(self.ptr, new_size) };
    }

    /// Free this block. It is copyable; calling `deinit` twice double-frees.
    pub fn deinit(self: Block) void {
        free(self.ptr);
    }
};

// Heap blocks may be freed across threads.
// `deinit` moves live blocks to the main heap; `destroy` frees them.
// Neither operation closes the process's main heap.

/// An owning mimalloc heap; methods require it to remain open.
/// `deinit` moves live blocks to main heap; `destroy` frees them.
pub const Heap = struct {
    raw: ?*c.mi_heap_t = null,

    /// Create a heap; NULL returns `OutOfMemory`.
    pub fn init() Error!Heap {
        return .{ .raw = c.mi_heap_new() orelse return error.OutOfMemory };
    }

    /// Create a heap in `arena_id`; null selects the process default.
    /// NULL returns `OutOfMemory`.
    pub fn initInArena(arena_id: ArenaId) Error!Heap {
        return .{ .raw = c.mi_heap_new_in_arena(arena_id) orelse return error.OutOfMemory };
    }

    /// Close the heap and move live blocks to main heap; they remain owned.
    pub fn deinit(self: *Heap) void {
        const raw = self.raw orelse return;
        self.raw = null;
        c.mi_heap_delete(raw);
    }

    /// Close the heap and free every live block; do not free them afterward.
    pub fn destroy(self: *Heap) void {
        const raw = self.raw orelse return;
        self.raw = null;
        c.mi_heap_destroy(raw);
    }

    /// Return the live upstream heap handle; panic if this heap is closed.
    /// Public for `TheapRef` and declarations this wrapper does not expose.
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

    /// Borrow the process's main heap. The caller must not close it.
    pub fn main() MainHeapRef {
        return .{ .raw = c.mi_heap_main() };
    }

    /// Find the heap owning `block`; null means no mimalloc heap owns it.
    pub fn of(block: *const anyopaque) ?HeapRef {
        return .{ .raw = c.mi_heap_of(block) };
    }

    /// Whether this heap owns `block`; null is checked against the main heap.
    pub fn contains(self: *const Heap, block: *const anyopaque) bool {
        return c.mi_heap_contains(self.handle(), block);
    }

    /// Release free pages from this heap's thread-local heap; live blocks remain.
    pub fn collect(self: *const Heap, force: bool) void {
        c.mi_heap_collect(self.handle(), force);
    }

    /// Associate this heap with a NUMA node.
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

    /// Resize a block owned by this heap or its shared arena; on failure it survives.
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

    /// Duplicate a string from this heap; release the mimalloc-owned result with `free`.
    pub fn strdup(self: *const Heap, s: [:0]const u8) Error![*:0]u8 {
        return c.mi_heap_strdup(self.handle(), s.ptr) orelse error.OutOfMemory;
    }

    /// Duplicate at most `n` bytes; release the result with `free`.
    pub fn strndup(self: *const Heap, s: [:0]const u8, n: usize) Error![*:0]u8 {
        return c.mi_heap_strndup(self.handle(), s.ptr, n) orelse error.OutOfMemory;
    }

    /// Resolve a path into caller-owned `buffer` (`PATH_MAX` bytes).
    /// Return null when unresolved.
    pub fn realpathInto(self: *const Heap, fname: [:0]const u8, buffer: []u8) ?[]u8 {
        if (c.mi_heap_realpath(self.handle(), fname.ptr, @ptrCast(buffer.ptr)) == null) return null;
        return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
    }

    /// Visit this heap's pages and, if requested, their blocks; return false to stop.
    /// The caller must be the only thread running with this heap.
    pub fn visitBlocks(self: *const Heap, visit_blocks: bool, visitor: BlockVisitFn, arg: ?*anyopaque) bool {
        return c.mi_heap_visit_blocks(self.handle(), visit_blocks, visitor, arg);
    }

    /// Visit pages abandoned by terminated threads; return value matches `visitBlocks`.
    pub fn visitAbandonedBlocks(self: *const Heap, visit_blocks: bool, visitor: BlockVisitFn, arg: ?*anyopaque) bool {
        return c.mi_heap_visit_abandoned_blocks(self.handle(), visit_blocks, visitor, arg);
    }

    /// Whether the page containing `block` is under-utilized.
    /// Unsafe unless this is the only thread accessing the page.
    pub fn unsafePageIsUnderUtilized(self: *const Heap, block: ?*anyopaque, perc_threshold: usize) bool {
        return c.mi_unsafe_heap_page_is_under_utilized(self.handle(), block, perc_threshold);
    }

    /// Return this heap's provider-owned thread-local heap.
    pub fn theap(self: *const Heap) TheapRef {
        return .{ .heap = self };
    }
};

/// Borrowed heap reference; it does not own or close the heap.
/// Returned by `Heap.of` and `Heap.main`.
pub const HeapRef = struct {
    raw: ?*c.mi_heap_t,

    /// Whether the referenced heap is still open; the handle may become stale.
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

/// Borrowed reference to the process's main heap; it cannot be closed.
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

// A thread-local heap is provider-owned and usable only from its creating thread.
// This wrapper exposes references, not create or destroy operations.

/// Borrowed, provider-owned thread-local heap; use only from its creating thread.
/// Obtain it through `Heap.theap`; it lives with that heap.
pub const TheapRef = struct {
    /// Parent heap; closing it invalidates this reference.
    heap: *const Heap,

    /// Resolve upstream's theap pointer on each call; it is created on first use.
    /// Public because `theapSetDefault` requires the raw pointer.
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

    /// Allocate with alignment; invalid alignment returns `InvalidAlignment`.
    pub fn mallocAligned(self: TheapRef, size: usize, alignment: usize) Error!*anyopaque {
        _ = try checkedAlignment(alignment);
        return c.mi_theap_malloc_aligned(self.handle(), size, alignment) orelse error.OutOfMemory;
    }

    /// Allocate zeroed with alignment; invalid alignment returns `InvalidAlignment`.
    pub fn zallocAligned(self: TheapRef, size: usize, alignment: usize) Error!*anyopaque {
        _ = try checkedAlignment(alignment);
        return c.mi_theap_zalloc_aligned(self.handle(), size, alignment) orelse error.OutOfMemory;
    }

    /// Resize a block; failure leaves it valid.
    pub fn realloc(self: TheapRef, block: ?*anyopaque, new_size: usize) Error!*anyopaque {
        return c.mi_theap_realloc(self.handle(), block, new_size) orelse error.OutOfMemory;
    }

    /// Resize a zeroed block and zero its growth.
    pub fn rezalloc(self: TheapRef, block: ?*anyopaque, new_size: usize) Error!*anyopaque {
        return c.mi_theap_rezalloc(self.handle(), block, new_size) orelse error.OutOfMemory;
    }

    /// Release free pages of this thread-local heap; live blocks remain.
    pub fn collect(self: TheapRef, force: bool) void {
        c.mi_theap_collect(self.handle(), force);
    }

    /// Experimental guard pages: rate 0 disables them; rate 1 guards every object.
    pub fn guardedSetSampleRate(self: TheapRef, sample_rate: usize, seed: usize) void {
        c.mi_theap_guarded_set_sample_rate(self.handle(), sample_rate, seed);
    }

    /// Set the eligible rounded object-size range for guard pages.
    pub fn guardedSetSizeBound(self: TheapRef, min: usize, max: usize) void {
        c.mi_theap_guarded_set_size_bound(self.handle(), min, max);
    }
};

/// Set the calling thread's default theap; return the previous value.
/// Pass null to clear the default.
pub fn theapSetDefault(theap: ?*c.mi_theap_t) ?*c.mi_theap_t {
    return c.mi_theap_set_default(theap);
}

/// Return the calling thread's default theap.
pub fn theapDefault() ?*c.mi_theap_t {
    return c.mi_theap_get_default();
}

// An arena reserves or adopts a process-local region for allocator pages.

/// Opaque upstream arena identifier.
pub const ArenaId = c.mi_arena_id_t;

/// Region reserved for an arena.
pub const ArenaArea = struct {
    /// Provider-owned memory; do not free or write to it.
    start: [*]u8,
    /// Region size in bytes.
    size: usize,
};

/// Return an arena's region, or null when the id is unknown.
/// The provider owns this memory; do not free or write to it.
pub fn arenaArea(arena_id: ArenaId) ?ArenaArea {
    var size: usize = 0;
    const start = c.mi_arena_area(arena_id, &size) orelse return null;
    return .{ .start = @ptrCast(start), .size = size };
}

/// Minimum alignment for arena regions.
pub fn arenaMinAlignment() usize {
    return c.mi_arena_min_alignment();
}

/// Minimum size for an arena reservation.
pub fn arenaMinSize() usize {
    return c.mi_arena_min_size();
}

/// Largest object an arena can hold.
/// Derived from the current `arena_max_object_size` option.
pub fn arenaMaxObjectSize() usize {
    return c.mi_arena_max_object_size();
}

/// Whether `block` lies inside this arena's region.
pub fn arenaContains(arena_id: ArenaId, block: *const anyopaque) bool {
    return c.mi_arena_contains(arena_id, block);
}

/// Reserve OS memory for allocator use; return 0 on success or an errno.
pub fn reserveOsMemory(size: usize, commit: bool, allow_large: bool) c_int {
    return c.mi_reserve_os_memory(size, commit, allow_large);
}

/// As `reserveOsMemory`, also writes an arena id and supports exclusivity.
pub fn reserveOsMemoryEx(size: usize, commit: bool, allow_large: bool, exclusive: bool, arena_id: *ArenaId) c_int {
    return c.mi_reserve_os_memory_ex(size, commit, allow_large, exclusive, arena_id);
}

/// Reserve 1 GiB pages at one NUMA node.
pub fn reserveHugeOsPagesAt(pages: usize, numa_node: c_int, timeout_msecs: usize) c_int {
    return c.mi_reserve_huge_os_pages_at(pages, numa_node, timeout_msecs);
}

/// Reserve 1 GiB pages at one NUMA node; also write an arena id.
pub fn reserveHugeOsPagesAtEx(pages: usize, numa_node: c_int, timeout_msecs: usize, exclusive: bool, arena_id: *ArenaId) c_int {
    return c.mi_reserve_huge_os_pages_at_ex(pages, numa_node, timeout_msecs, exclusive, arena_id);
}

/// Reserve 1 GiB pages interleaved across `numa_nodes`.
pub fn reserveHugeOsPagesInterleave(pages: usize, numa_nodes: usize, timeout_msecs: usize) c_int {
    return c.mi_reserve_huge_os_pages_interleave(pages, numa_nodes, timeout_msecs);
}

/// Deprecated upstream spelling with a `double` timeout and reserved-page count.
/// Prefer `reserveHugeOsPagesAtEx`.
pub fn reserveHugeOsPages(pages: usize, max_secs: f64, pages_reserved: *usize) c_int {
    return c.mi_reserve_huge_os_pages(pages, max_secs, pages_reserved);
}

/// Hand caller-owned page-aligned memory to the allocator.
/// The provider retains it at exit unless `destroy_on_exit` is enabled.
pub fn manageOsMemory(start: ?*anyopaque, size: usize, is_committed: bool, is_pinned: bool, is_zero: bool, numa_node: c_int) bool {
    return c.mi_manage_os_memory(start, size, is_committed, is_pinned, is_zero, numa_node);
}

/// As `manageOsMemory`, also writes an arena id and supports exclusivity.
pub fn manageOsMemoryEx(start: ?*anyopaque, size: usize, is_committed: bool, is_pinned: bool, is_zero: bool, numa_node: c_int, exclusive: bool, arena_id: *ArenaId) bool {
    return c.mi_manage_os_memory_ex(start, size, is_committed, is_pinned, is_zero, numa_node, exclusive, arena_id);
}

/// Experimental memory management with a commit callback under allocator locks.
/// Set `is_zero`; blocking on another allocating thread can deadlock.
pub fn manageMemory(start: ?*anyopaque, size: usize, is_committed: bool, is_pinned: bool, is_zero: bool, numa_node: c_int, exclusive: bool, commit_fun: ?CommitFn, commit_fun_arg: ?*anyopaque, arena_id: *ArenaId) bool {
    return c.mi_manage_memory(start, size, is_committed, is_pinned, is_zero, numa_node, exclusive, commit_fun, commit_fun_arg, arena_id);
}

/// Print arena debug information through the registered output.
pub fn debugShowArenas() void {
    c.mi_debug_show_arenas();
}

/// Print the arena summary.
pub fn arenasPrint() void {
    c.mi_arenas_print();
}

// A sub-process groups arenas without cross-group reclamation.
// It is an in-process allocator boundary, not an OS process.

/// Opaque mimalloc sub-process identifier.
pub const Subproc = struct {
    raw: c.mi_subproc_id_t,

    /// Return the process's initial sub-process group.
    pub fn main() Subproc {
        return .{ .raw = c.mi_subproc_main() };
    }

    /// Return the group containing the calling thread.
    pub fn current() Subproc {
        return .{ .raw = c.mi_subproc_current() };
    }

    /// Create an empty sub-process group.
    pub fn create() Subproc {
        return .{ .raw = c.mi_subproc_new() };
    }

    /// Destroy this group; its remaining blocks are no longer usable.
    pub fn destroy(self: Subproc) void {
        c.mi_subproc_destroy(self.raw);
    }

    /// Assign the calling thread immediately after creation, before it allocates.
    pub fn addCurrentThread(self: Subproc) void {
        c.mi_subproc_add_current_thread(self.raw);
    }

    /// Visit each heap in this group; return false when the visitor stops.
    /// Heaps are borrowed; do not close one during the visit.
    pub fn visitHeaps(self: Subproc, visitor: HeapVisitFn, arg: ?*anyopaque) bool {
        return c.mi_subproc_visit_heaps(self.raw, visitor, arg);
    }
};

// Options are process-wide; most have little effect after the first allocation.
// Upstream also reads `MIMALLOC_<OPTION>` from the environment.

/// Upstream option tags; `_mi_option_last` and duplicate-value aliases are omitted.
/// Omitted aliases: `large_os_pages`, `eager_region_commit`, `reset_decommits`, `reset_delay`, `limit_os_alloc`.
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
    /// Release all memory on exit; upstream warns this can be unsafe with dynamic unloading.
    destroy_on_exit = c.mi_option_destroy_on_exit,
    /// Initial arena reservation size; read with `optionGetSize` in bytes.
    arena_reserve = c.mi_option_arena_reserve,
    /// Arena purge-delay multiplier.
    arena_purge_mult = c.mi_option_arena_purge_mult,
    /// `mi_option_disallow_arena_alloc`: take no arena memory for allocation.
    disallow_arena_alloc = c.mi_option_disallow_arena_alloc,
    /// Retry OOM for N milliseconds; 0 disables retry (Windows only).
    retry_on_oom = c.mi_option_retry_on_oom,
    /// `mi_option_guarded_min`: smallest rounded object size eligible for a
    /// guard page, in a `MI_GUARDED` build.
    guarded_min = c.mi_option_guarded_min,
    /// `mi_option_guarded_max`: largest, likewise.
    guarded_max = c.mi_option_guarded_max,
    /// Place guarded blocks immediately before their guard page.
    guarded_precise = c.mi_option_guarded_precise,
    /// Guard one object in N within the size bound.
    guarded_sample_rate = c.mi_option_guarded_sample_rate,
    /// `mi_option_guarded_sample_seed`: fix the sample for a reproducible run.
    guarded_sample_seed = c.mi_option_guarded_sample_seed,
    /// `mi_option_generic_collect`: collect theaps every N generic allocations.
    generic_collect = c.mi_option_generic_collect,
    /// Reclaim pages on free: -1 never, 0 only from this theap, 1 always.
    page_reclaim_on_free = c.mi_option_page_reclaim_on_free,
    /// `mi_option_page_full_retain`: keep N full pages per size class.
    page_full_retain = c.mi_option_page_full_retain,
    /// `mi_option_page_max_candidates`: candidate pages to consider.
    page_max_candidates = c.mi_option_page_max_candidates,
    /// Largest user virtual-address width to consider.
    max_vabits = c.mi_option_max_vabits,
    /// Commit the whole page map to catch invalid pointers inside it.
    pagemap_commit = c.mi_option_pagemap_commit,
    /// `mi_option_page_commit_on_demand`: commit page memory on demand.
    page_commit_on_demand = c.mi_option_page_commit_on_demand,
    /// Keep at most N pages of a size class on the originating theap.
    page_max_reclaim = c.mi_option_page_max_reclaim,
    /// Cross-thread counterpart to `page_max_reclaim`.
    page_cross_thread_max_reclaim = c.mi_option_page_cross_thread_max_reclaim,
    /// Allow transparent huge pages; 0 disables them process-wide.
    allow_thp = c.mi_option_allow_thp,
    /// `mi_option_minimal_purge_size`: the smallest purge, in KiB.
    minimal_purge_size = c.mi_option_minimal_purge_size,
    /// Largest arena object-size limit; `optionGetSize` returns bytes.
    arena_max_object_size = c.mi_option_arena_max_object_size,
    /// Experimental: use a local NUMA node for the initial arena allocation.
    arena_is_numa_local = c.mi_option_arena_is_numa_local,
    /// Merge theap statistics into its parent heap on collection.
    collect_merges_stats = c.mi_option_collect_merges_stats,
};

/// `mi_option_is_enabled` (`include/mimalloc.h:509`): whether this option is on.
pub fn optionIsEnabled(option: Option) bool {
    return c.mi_option_is_enabled(@backingInt(option));
}

/// Enable this option.
pub fn optionEnable(option: Option) void {
    c.mi_option_enable(@backingInt(option));
}

/// Disable this option.
pub fn optionDisable(option: Option) void {
    c.mi_option_disable(@backingInt(option));
}

/// Set whether this option is enabled.
pub fn optionSetEnabled(option: Option, enable: bool) void {
    c.mi_option_set_enabled(@backingInt(option), enable);
}

/// Change the built-in default rather than the current value.
pub fn optionSetEnabledDefault(option: Option, enable: bool) void {
    c.mi_option_set_enabled_default(@backingInt(option), enable);
}

/// Return the current value as `c_long`, matching the platform's C `long`.
pub fn optionGet(option: Option) c_long {
    return c.mi_option_get(@backingInt(option));
}

/// Return the current value clamped to `min .. max`; non-numeric options use `min`.
pub fn optionGetClamp(option: Option, min: c_long, max: c_long) c_long {
    return c.mi_option_get_clamp(@backingInt(option), min, max);
}

/// Return a size-valued option in bytes; upstream stores these values in KiB.
pub fn optionGetSize(option: Option) usize {
    return c.mi_option_get_size(@backingInt(option));
}

/// Set this option's value.
pub fn optionSet(option: Option, value: c_long) void {
    c.mi_option_set(@backingInt(option), value);
}

/// Set the built-in default rather than the current value.
pub fn optionSetDefault(option: Option, value: c_long) void {
    c.mi_option_set_default(@backingInt(option), value);
}

// The first allocation initializes process and thread state.
// These APIs let embedding runtimes control initialization timing.

/// Initialize the process; normally the first allocation does this.
/// Call early to parse options before other runtime allocations.
pub fn processInit() void {
    c.mi_process_init();
}

/// Release process memory after all allocating threads stop.
/// Intended for dynamic unloading, not normal use.
pub fn processDone() void {
    c.mi_process_done();
}

/// Initialize the calling thread.
pub fn threadInit() void {
    c.mi_thread_init();
}

/// Release the calling thread's allocator state.
pub fn threadDone() void {
    c.mi_thread_done();
}

/// Mark the calling thread as pooled so its memory survives thread exit.
pub fn threadSetInThreadpool() void {
    c.mi_thread_set_in_threadpool();
}

/// Release free pages on the calling thread's theap; live blocks remain.
/// This does not collect process-wide.
pub fn collect(force: bool) void {
    c.mi_collect(force);
}

// Ownership queries report heap ownership, not whether an address is managed.
// They cannot report ownership for pointers from another allocator.

/// Whether any mimalloc heap owns `block`.
pub fn anyHeapContains(block: *const anyopaque) bool {
    return c.mi_any_heap_contains(block);
}

/// Deprecated alias of `anyHeapContains`.
/// Use `anyHeapContains` instead.
pub fn checkOwned(block: *const anyopaque) bool {
    return c.mi_check_owned(block);
}

/// Deprecated: tests whether an address is managed, even if it is not a live block.
/// Use `anyHeapContains` to check ownership.
pub fn isInHeapRegion(block: *const anyopaque) bool {
    return c.mi_is_in_heap_region(block);
}

// Callbacks enter Zig from mimalloc's C code and use `callconv(.c)`.
// The provider passes `arg` back unchanged and calls on its own threads.
// This package holds no lock while callbacks run.

/// Callback invoked before collection.
pub const DeferredFreeFn = *const fn (force: bool, heartbeat: u64, arg: ?*anyopaque) callconv(.c) void;

/// Receive provider-owned NUL-terminated output; copy it to retain it.
/// This signature matches the translated C declaration.
pub const OutputFn = *const fn (msg: [*c]const u8, arg: ?*anyopaque) callconv(.c) void;

/// Receive an errno; without a handler, upstream's default callback aborts.
/// Registering this callback replaces that behavior.
pub const ErrorFn = *const fn (err: c_int, arg: ?*anyopaque) callconv(.c) void;

/// Visit a page or block; returning false stops the remaining walk.
/// Heap and area pointers are borrowed and match the translated C ABI.
pub const BlockVisitFn = *const fn (
    heap: ?*const c.mi_heap_t,
    area: [*c]const c.mi_heap_area_t,
    block: ?*anyopaque,
    block_size: usize,
    arg: ?*anyopaque,
) callconv(.c) bool;

/// `mi_heap_visit_fun` (`include/mimalloc.h:367`): one heap, borrowed.
pub const HeapVisitFn = *const fn (heap: ?*c.mi_heap_t, arg: ?*anyopaque) callconv(.c) bool;

/// Experimental callback to commit or reset memory; see `manageMemory`.
/// Write through `is_zero`, a C out-parameter.
pub const CommitFn = *const fn (
    commit: bool,
    start: ?*anyopaque,
    size: usize,
    is_zero: [*c]bool,
    user_arg: ?*anyopaque,
) callconv(.c) bool;

/// Register a callback before collection so a runtime can release its objects.
/// `heartbeat` counts calls; `force` passes through unchanged.
pub fn registerDeferredFree(deferred_free: DeferredFreeFn, arg: ?*anyopaque) void {
    c.mi_register_deferred_free(deferred_free, arg);
}

/// Route mimalloc messages to `out`; null restores its default output.
/// `msg` is provider-owned and NUL-terminated; copy it to retain it.
pub fn registerOutput(out: ?OutputFn, arg: ?*anyopaque) void {
    c.mi_register_output(out, arg);
}

/// Replace the default abort after an error message.
pub fn registerError(fun: ErrorFn, arg: ?*anyopaque) void {
    c.mi_register_error(fun, arg);
}

// Reporting APIs write to the registered output, or the default output.
// They return no owned data.

/// The eight values returned by upstream's `mi_process_info`.
/// Values are copied directly; this wrapper does not recompute them.
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

/// Read all eight process metrics in one call.
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

/// Print every option and its value.
pub fn optionsPrint() void {
    c.mi_options_print();
}

/// Print options to `out`; null selects upstream's default output.
pub fn optionsPrintTo(out: ?OutputFn, arg: ?*anyopaque) void {
    c.mi_options_print_out(out, arg);
}

/// Print the values returned by `processInfo`.
pub fn processInfoPrint() void {
    c.mi_process_info_print();
}

/// Print process information to `out`; null selects upstream's default output.
pub fn processInfoPrintTo(out: ?OutputFn, arg: ?*anyopaque) void {
    c.mi_process_info_print_out(out, arg);
}

/// Print upstream statistics through `out`.
/// Structured statistics are also available through `c`.
pub fn statsPrintTo(out: ?OutputFn, arg: ?*anyopaque) void {
    c.mi_stats_print_out(out, arg);
}

/// Deprecated; print statistics for the calling thread only.
pub fn threadStatsPrintTo(out: ?OutputFn, arg: ?*anyopaque) void {
    c.mi_thread_stats_print_out(out, arg);
}

/// `mi_stats_reset` (`include/mimalloc.h:437`): reset this process's statistics.
pub fn statsReset() void {
    c.mi_stats_reset();
}
