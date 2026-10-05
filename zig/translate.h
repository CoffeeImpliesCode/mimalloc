/* The one header this package translates.
 *
 * `zig build` runs translate-c over this file, and what that translation
 * becomes is the `c` module the Zig facade in zig/root.zig imports.  Its whole
 * job is to name the public headers of the library this build compiles.
 *
 * Which headers those are
 * -----------------------
 * mimalloc installs five headers, and this file names one of them:
 *
 *   mimalloc.h   the whole C API.  It is the only header a C consumer needs:
 *                the standard malloc interface, the extended and aligned
 *                allocation functions, first-class heaps, arenas, theaps,
 *                sub-processes, the option table and the process and thread
 *                lifecycle entry points are all declared in it.
 *
 * It is included whole, with its own include guard, so this wrapper cannot
 * disagree with the real header by omission and cannot re-declare a prototype
 * with a different type.
 *
 * Why the other four are not listed
 * ---------------------------------
 *   mimalloc-override.h    (include/mimalloc-override.h:18) is a convenience
 *                          wrapper that *defines* `malloc`, `free`, `calloc`,
 *                          `realloc` and the C++ operators as forwarding
 *                          functions.  It is the standard-malloc interposition
 *                          route, which this package deliberately does not
 *                          take; see README.md, "This package does not replace
 *                          your allocator".  It reaches nothing here that
 *                          `<mimalloc.h>` does not already declare.
 *   mimalloc-new-delete.h  is the same idea for `operator new`/`operator
 *                          delete` alone, with the same objection.
 *   mimalloc-profile.h     (include/mimalloc-profile.h:12-13) opens
 *                          `<mimalloc.h>`, `<stdbool.h>` and `<stdint.h>` and
 *                          adds only compile-time profiling knobs.
 *   mimalloc-stats.h       (include/mimalloc-stats.h:12-13) opens
 *                          `<mimalloc.h>`, `<string.h>` and `<stdint.h>`.  It
 *                          is excluded for two reasons that both matter to a
 *                          build, not one: `<string.h>` would pull the C
 *                          library's whole string surface into the translation
 *                          and force a several-hundred-name libc noise list in
 *                          runtime/graph.zig, and `mi_stats_t`
 *                          (include/mimalloc-stats.h:106-121) is a fixed-layout
 *                          table of `size_t` counters that upstream extends
 *                          between minor versions, so a Zig mirror of it would
 *                          be a second source of truth about a layout the
 *                          library owns.  The printed-statistics entry points a
 *                          caller actually wants are declared in
 *                          `<mimalloc.h>` itself - `mi_stats_print_out`
 *                          (include/mimalloc.h:441), `mi_process_info`
 *                          (:204), `mi_options_print_out` (:202) - and reach
 *                          through this wrapper unchanged.
 *
 * All five are still installed, unchanged, by build.zig, because they are
 * upstream's installed headers and a C++ or profiling consumer of the
 * installed tree needs them.
 *
 * What is deliberately not here
 * -----------------------------
 * A copy of any declaration, and no macro of this build's own.
 *
 * In particular `MI_MALLOC_OVERRIDE` is *not* defined, on this header or
 * anywhere else on the compile line.  It is the one macro that decides whether
 * this library defines the standard allocator: `src/alloc.c:19-22` includes
 * `src/alloc-override.c`, and that file is empty unless `MI_MALLOC_OVERRIDE` is
 * defined (`src/alloc-override.c:13`), after which it aliases `malloc`,
 * `calloc`, `realloc`, `free`, `posix_memalign`, `operator new` and the rest
 * onto their `mi_` counterparts.  Defining it here would put a C definition of
 * `malloc` in the translation, which is an interposition this package does not
 * perform and a symbol a `libmimalloc.so` this build did not compile would not
 * export.
 *
 * `MI_SHARED_LIB` and `MI_SHARED_LIB_EXPORT` are the declaration half of the
 * same split and are the only ones build.zig turns on, and only on Windows:
 * `include/mimalloc.h:39-67` makes `mi_decl_export` `__declspec(dllimport)`
 * unless `MI_SHARED_LIB` is defined and `__declspec(dllexport)` unless
 * `MI_SHARED_LIB_EXPORT` is also defined.  build.zig gives both to the units
 * that produce a shared object and `MI_SHARED_LIB` alone to this translation
 * and to a consumer of the DLL, which is how a C consumer gets the same
 * `dllimport` answer without repeating the flag.  On every other target
 * `mi_decl_export` is empty (include/mimalloc.h:64-67), so neither changes
 * anything.
 */

#ifndef MIMALLOC_TRANSLATE_H
#define MIMALLOC_TRANSLATE_H

#include <mimalloc.h>

#endif /* MIMALLOC_TRANSLATE_H */
