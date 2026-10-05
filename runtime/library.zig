// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.
//
//! mimalloc's side of the runtime loader: the names its synchronization binding
//! has, what it requires of a provider beyond resolving its symbols, and what the
//! external ABI boundary for this provider actually is.
//!
//! Everything else about the runtime route is generic. `runtime/loader.zig` is
//! the state machine and the platform layer; `runtime/generate.zig` builds the
//! dispatch from whatever the translation step actually produced;
//! `runtime/graph.zig` wires them together. This file is what makes them
//! mimalloc's, and it is the file another SDK replaces.
//!
//! ## What a provider must be
//!
//! Every `mi_`-prefixed entry point `zig/translate.h` reaches, which is
//! `include/mimalloc.h` and nothing else. That header opens exactly three
//! standard headers - `<stddef.h>` (`include/mimalloc.h:98`), `<stdbool.h>`
//! (`:99`) and `<assert.h>` (`:100`) - and declares no exported data object, so
//! the required set is functions only.
//!
//! The C library's own surface that reaches the translation through those three
//! headers is classified as noise in `runtime/graph.zig` and is not in the table.
//! It is not part of what a mimalloc provider owes: `libmimalloc.so` exports
//! `__assert_fail` on glibc because glibc does, not because it is an allocator.
//!
//! ### The two names the header declares and upstream never defines
//!
//! `mi_collect_reduce` (`include/mimalloc.h:435`) and `mi_stats_merge`
//! (`include/mimalloc.h:438`) sit in upstream's own `Deprecated` block and are
//! `SOURCE-CONFIRMED` absent from every translation unit of the v3.5.3 source
//! closure. A build that required them would fail every single load, on every
//! platform, against a perfectly good provider. They are therefore named in
//! `provider_excluded` in `runtime/graph.zig`: routed, nullable, and never
//! required. The Zig facade does not call either one, so a linked build never
//! asks the linker for a symbol that does not exist either. This is upstream's
//! header, recorded here rather than patched in the vendored tree - see
//! `FORK-NOTES.md`.
//!
//! ## The ABI boundary, stated honestly
//!
//! The supported external ABI family is **mimalloc v3**, `MI_MALLOC_VERSION`
//! 30503 (`include/mimalloc.h:11`), built from this repository's `src/` and
//! `include/` with no override macro defined. That is a narrower claim than "a
//! shared object that exports these names", and the difference is real:
//!
//!   * `MI_MALLOC_VERSION` is major + two digits of minor + two digits of patch,
//!     so v3.5.3 is 30503 while v3.4.1 is 30401 and v2.5.2 is 20502. The
//!     project ships v1, v2 and v3 side by side in one release - the `v3.5.3`
//!     release carries `mimalloc-v1.15.2-source.tar.gz`,
//!     `mimalloc-v2.5.2-source.tar.gz` and `mimalloc-v3.5.3-source.tar.gz` - and
//!     all three export the same `mi_malloc`/`mi_free` spellings under the same
//!     header names. A provider built from the v2 or v1 line passes a symbol
//!     check and is a different ABI. `mi_version` is what separates them.
//!   * The v3 layout is not the v2 layout. `mi_heap_s`, `mi_theap_s` and the
//!     arena types are opaque here, so a caller only passes their addresses
//!     around, but `mi_heap_area_t` (`include/mimalloc.h:308-316`) is a plain
//!     struct whose five `size_t` fields and two pointers a block-visiting
//!     callback reads through are part of the boundary. A v2 provider hands a v3
//!     callback a different struct.
//!   * The whole surface is about memory the *provider* owns. `mi_malloc`
//!     returns a block from mimalloc's own arena; `mi_free` puts it back;
//!     `mi_usable_size` reports what the page layout says, not what was asked
//!     for; `mi_heap_new` creates a heap the provider tracks. Nothing in this
//!     SDK can observe, bound or account for those allocations: a Zig allocator
//!     is not in the path, and a test framework cannot supply a leak oracle for
//!     memory a third-party allocator owns. Every `pub fn` that hands a pointer
//!     across the boundary says so in its own documentation.
//!   * `mi_deferred_free_fun`, `mi_output_fun`, `mi_error_fun`,
//!     `mi_block_visit_fun`, `mi_heap_visit_fun` and `mi_commit_fun_t` are
//!     function-pointer types crossing the boundary in both directions. A
//!     callback built against this translation is called by the provider's own C
//!     with the provider's own calling convention.
//!   * The provider's own process-wide effects are real and this loader does
//!     not contain them. `mi_process_init` (`include/mimalloc.h:211`) installs a
//!     process-wide allocation strategy and `mi_collect` (`:198`) acts on every
//!     thread. Neither is per-handle state a table can isolate.
//!
//! Resolving the symbols and translating the header is the boundary. They are
//! not proof that a provider is compatible, and this file does not pretend to
//! add more than it checks. What is checked at load time, before anything is
//! published:
//!
//!   * `mi_version` answers with this header's `MI_MALLOC_VERSION`. That is the
//!     ABI *family* check, and it is the only thing that separates v3 from the v2
//!     and v1 sources published beside it.
//!   * `mi_malloc` returns a block for a 64-byte request, `mi_usable_size`
//!     reports at least that many bytes for it, `mi_any_heap_contains` claims it,
//!     and `mi_free` returns it. One allocation and one free, through this same
//!     table, before anything is published. That exercises the provider's
//!     initialization path - the first `mi_theap_malloc` is what reaches
//!     `_mi_heap_init` (`src/alloc.c:338` -> `src/init.c:200`) - and its free
//!     path, and the block is freed on every path out of this function,
//!     including the refusing ones, so a failed validation does not leave a
//!     block behind in a provider this process is about to close.
//!
//! ## What is deliberately *not* called here
//!
//! `mi_is_redirected` (`include/mimalloc.h:329`) answers whether *this* provider
//! is the one serving the process's `malloc`. It is the single most informative
//! fact about a loaded provider and it is not a requirement, because the honest
//! answer for a `dlopen`ed `libmimalloc.so` is `false`: the process was not
//! preloaded with it. Requiring `true` would refuse every provider this loader
//! is for. The facade exposes it as `isRedirected()`, and `README.md` says
//! plainly what a `false` means.
//!
//! `mi_process_init` and `mi_process_done` are likewise not called: the first
//! `mi_malloc` runs the provider's own initialization, and a loader that tore a
//! process down as a side effect of refusing a provider would be a worse
//! neighbour than one that simply closes its handle.
const std = @import("std");

const rt = @import("rt");

/// The synchronization this loader calls, bound by exact name.
///
/// The names below are `runtime/sync.c` compiled with
/// `RT_SYNC_PREFIX=mimalloc_rt`, which is what `runtime/graph.zig` passes. Two
/// spellings of that prefix have to agree: this file names the symbols, and
/// graph.zig defines the macro. A build where they disagree does not link, and
/// that is the whole error report: there is no runtime path that could hide it.
///
/// The core in `runtime/loader.zig` never names a symbol of its own, which is
/// what lets two SDKs, or two configurations of one SDK, hold their own loader
/// state in one process without sharing any of it.
pub const Sync = struct {
    extern fn mimalloc_rt_lock() void;
    extern fn mimalloc_rt_unlock() void;
    extern fn mimalloc_rt_wait() void;
    extern fn mimalloc_rt_broadcast() void;
    // `unsigned long long`. Declared as u64, which is the same type in every
    // ABI this SDK targets: 64-bit on x86_64, aarch64, riscv64 and wasm32.
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

/// The request `validate` makes through the provider, in bytes.
///
/// Small enough to be served out of the provider's first page and large enough
/// that no platform's minimum-alignment rounding can make the usable size a
/// weird answer, which is the point: the check is about a block being handed
/// back, not about size classes.
const probe_size: usize = 64;

/// The loader's configuration for this SDK, given the dispatch that owns the
/// table.
///
/// `dispatch` is the generated module, passed as a type by the dispatch itself
/// so that this file never has to import it. The direction is one-way on
/// purpose: the descriptor knows what the loader needs, the dispatch knows what
/// the header said, and neither imports the other.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Named in the pre-load panic, so the message says which library was
        /// reached for before it was loaded.
        pub const library_name = "mimalloc";

        /// The table the generated dispatch declares, and the symbols it needs
        /// to fill it. Both come from the translated headers, not from this file.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// The project's namespaced synchronization binding.
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

        /// The library-specific checks, run after every symbol resolved and
        /// before anything is published.
        ///
        /// A non-null answer is `ValidationFailed` and the candidate is closed
        /// without being published. Every check here is one whose failure this
        /// code can observe; see the module comment for what is deliberately
        /// not called and why.
        pub fn validate(dst: *const table) ?[]const u8 {
            // The ABI family check. `mi_version` takes no arguments and returns
            // the constant its own header was compiled with
            // (`src/options.c:20-22`), so this asks the provider which of the
            // three source lines published in one release its `mi_malloc`
            // actually came from. Nothing else in the table distinguishes a v2
            // or a v1 provider: the spellings are the same and the loader would
            // be satisfied.
            const family = dst.mi_version();
            const expected: c_int = @intCast(dispatch.MI_MALLOC_VERSION);
            if (family != expected) {
                // The numbers go to the diagnostic stream rather than into the
                // returned text: `validate` has no allocator and the loader
                // reports whatever string it is given.
                std.debug.print(
                    "mimalloc: provider reports mi_version {d}, this SDK's headers " ++
                        "describe {d}; they are different external ABIs\n",
                    .{ family, expected },
                );
                return "this provider implements a different mimalloc major/minor " ++
                    "ABI than the one this SDK's headers describe";
            }

            // One allocation, through this same table. This is the check that
            // the provider's initialization path works at all: the first
            // `mi_theap_malloc` is what reaches `_mi_heap_init`
            // (`src/alloc.c:338` -> `src/init.c:200`), and a provider that
            // cannot get that far is not usable whatever its symbols say.
            const probe = dst.mi_malloc(probe_size) orelse return
                "mi_malloc returned null for a 64-byte request, so this " ++
                "provider's allocator could not satisfy a fresh block";
            // Freed on every path out of this function, including the two
            // refusals below. The candidate is about to be closed and this
            // process is not going to use it, so leaving a block inside a
            // provider that is about to be unloaded is exactly what this defer
            // prevents.
            defer dst.mi_free(probe);

            // `mi_usable_size` reports the page's block size
            // (`src/free.c:587-590` -> `_mi_page_usable_size`), so it is the
            // provider's own rounding answer. A provider that reported less
            // than was asked for would be describing a block this table's
            // caller cannot safely write `probe_size` bytes into.
            const usable = dst.mi_usable_size(probe);
            if (usable < probe_size) {
                std.debug.print(
                    "mimalloc: provider reports mi_usable_size {d} for a {d}-byte request\n",
                    .{ usable, probe_size },
                );
                return "mi_usable_size reported fewer bytes than were requested, so " ++
                    "this provider's block layout is not the one these headers describe";
            }

            // `mi_any_heap_contains` is upstream's own ownership predicate
            // (`include/mimalloc.h:251`, `src/heap.c:276-279`). A provider that
            // does not claim the pointer it just handed out is describing a
            // different address space under the same entry point.
            if (!dst.mi_any_heap_contains(probe)) {
                return "mi_any_heap_contains denied the pointer mi_malloc had just " ++
                    "returned, so this provider does not own the blocks its own " ++
                    "allocator hands out";
            }

            return null;
        }
    };
}
