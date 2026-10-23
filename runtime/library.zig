// SPDX-License-Identifier: MIT
const std = @import("std");

const rt = @import("rt");

/// Namespaced synchronization bindings for the runtime loader.
pub const Sync = struct {
    extern fn mimalloc_rt_lock() void;
    extern fn mimalloc_rt_unlock() void;
    extern fn mimalloc_rt_wait() void;
    extern fn mimalloc_rt_broadcast() void;
    // Matches the C `unsigned long long` thread identifier on supported targets.
    extern fn mimalloc_rt_thread_self() u64;

    pub fn lock() void {
        mimalloc_rt_lock();
    }
    pub fn unlock() void {
        mimalloc_rt_unlock();
    }
    pub fn wait() void {
        mimalloc_rt_wait();
    }
    pub fn broadcast() void {
        mimalloc_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return mimalloc_rt_thread_self();
    }
};

/// Allocation size used by provider validation.
const probe_size: usize = 64;

/// Configures the runtime loader for this translated dispatch.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Name shown in loader errors.
        pub const library_name = "mimalloc";

        /// Table type generated from the translated headers.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// Namespaced synchronization binding used by the loader.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// Validates a resolved provider; returns a refusal message or null.
        pub fn validate(dst: *const table) ?[]const u8 {
            // `mi_version` distinguishes v3 from v1/v2, which share symbol names (`src/options.c:20-22`).
            const family = dst.mi_version();
            const expected: c_int = @intCast(dispatch.MI_MALLOC_VERSION);
            if (family != expected) {
                // Print details here; validation returns static text to the loader.
                std.debug.print(
                    "mimalloc: provider reports mi_version {d}, this SDK's headers " ++
                        "describe {d}; they are different external ABIs\n",
                    .{ family, expected },
                );
                return "this provider implements a different mimalloc major/minor " ++
                    "ABI than the one this SDK's headers describe";
            }

            // Probe provider initialization with one allocation before publishing.
            const probe = dst.mi_malloc(probe_size) orelse return
                "mi_malloc returned null for a 64-byte request, so this " ++
                "provider's allocator could not satisfy a fresh block";
            // Free the probe before the loader closes a rejected provider.
            defer dst.mi_free(probe);

            // Reject a provider whose usable block size is smaller than requested.
            const usable = dst.mi_usable_size(probe);
            if (usable < probe_size) {
                std.debug.print(
                    "mimalloc: provider reports mi_usable_size {d} for a {d}-byte request\n",
                    .{ usable, probe_size },
                );
                return "mi_usable_size reported fewer bytes than were requested, so " ++
                    "this provider's block layout is not the one these headers describe";
            }

            // Confirm the provider claims the pointer it just allocated.
            if (!dst.mi_any_heap_contains(probe)) {
                return "mi_any_heap_contains denied the pointer mi_malloc had just " ++
                    "returned, so this provider does not own the blocks its own " ++
                    "allocator hands out";
            }

            return null;
        }
    };
}
