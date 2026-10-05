# Upstream

Which upstream this SDK is built from, what was taken from it byte for byte,
what was left behind, and how the bytes got here.

## Canonical source

| | |
|---|---|
| Project | mimalloc, Microsoft Research (Daan Leijen) |
| Authoritative site | <https://github.com/microsoft/mimalloc/> |
| Artifact | `mimalloc-v3.5.3-source.tar.gz` |
| URL | <https://github.com/microsoft/mimalloc/releases/download/v3.5.3/mimalloc-v3.5.3-source.tar.gz> |
| Released | 2026-09-17 |
| Size | 1458292 bytes |
| sha256 | `43857a9e4f26412e970cbe49635d0465c2de6e77a697ce3d4b926a473d1045ca` |
| Annotated tag object | `deac3dcf5f0614884013d411a5c07e16bec96c9f` (`v3.5.3`) |
| Commit the tag points at | `d4881d338125e1cb7c47ba4cfb398d6f7c0c8d45` |
| Extracts to | `mimalloc-d4881d338125e1cb7c47ba4cfb398d6f7c0c8d45/` |

The artifact URL, the release date and the size above are the values the
release itself carries. `SOURCE-CONFIRMED`: the sha256 is the digest of the
downloaded `mimalloc-v3.5.3-source.tar.gz` over its whole 1458292 bytes, and
the extraction directory name is the commit SHA the tarball's own archive is
built from — which is how the commit and the tag were recovered here without a
clone (see "Import mechanism").

The two GitHub objects are **recorded, not imported**. They are what the
GitHub API reports for the annotated tag `v3.5.3`, and they are recorded so a
later reader can go and look at the same release upstream. They are not a
provenance chain for this tree: there is no Git history here, no merge base and
no patch series, and nothing below is derived from them. The only thing that
makes the bytes in `src/` and `include/` the bytes of v3.5.3 is
[`UPSTREAM.sha256`](UPSTREAM.sha256).

Upstream's own release notes, kept verbatim in
[`README.upstream.md`](README.upstream.md), name `v3.5.3` as "Latest release
: `v3.5.3`  (2026-09-16) recommended". That is upstream's string inside the
tarball; the release publication date recorded above is 2026-09-17. Both are
recorded rather than reconciled, because reconciling them would mean preferring
one source over the other without a reason.

## What upstream is

mimalloc (pronounced "me-malloc") is a general purpose allocator with excellent
performance characteristics, initially developed by Daan Leijen for the
runtime systems of the Koka and Lean languages, and now maintained under
Microsoft Research.

Structurally, as imported: a compact allocator with small, consistent data
structures, split by concern across roughly ten thousand lines of C —
`src/alloc.c` and `src/alloc-aligned.c` (the allocation surface),
`src/alloc-posix.c` (the POSIX-shaped spellings), `src/free.c` (the free path),
`src/page.c`, `src/page-map.c` and `src/page-queue.c` (page management),
`src/arena.c` and `src/bitmap.c` (arena management and the two-level bitmap
that tracks pages and blocks in them), `src/heap.c` and `src/theap.c`
(first-class heaps and the thread-local "theap" fast path on top of one),
`src/subproc.c` (sub-processes), `src/options.c`, `src/init.c`, `src/stats.c`,
`src/os.c`, `src/random.c`, `src/libc.c`, `src/sample-guarded.c`,
`src/sample-profile.c` and `src/threadlocal.c`.

Below all of that sits `src/prim/`, which is the whole platform layer behind
one dispatcher. `src/prim/prim.c:11-25` `#include`s the platform implementation
as text and the `#if` chain decides which one, so this repository carries every
platform's implementation — `unix`, `osx`, `wasi`, `windows`, `emscripten` —
and compiles exactly one. That is upstream's structure, kept as it is; see
[`FORK-NOTES.md`](FORK-NOTES.md) for why a build that listed a platform
directory would be a fork decision rather than an import.

mimalloc publishes **three** maintained lines side by side — v1, v2 and v3 —
and this SDK is the v3 one. That distinction is load-bearing and is stated
where it matters: [`README.zig.md`](README.zig.md) and `runtime/library.zig`
both record that the v1 and v2 sources are published in the **same** `v3.5.3`
release beside the v3 one, so all three export the same `mi_malloc`/`mi_free`
spellings under the same header names, and a symbol check alone does not
separate the families.

## The preserved upstream README

The release tarball ships a `readme.md` at its root. It is upstream's own
project document — a general-purpose allocator's readme, covering performance
numbers, tuning, security notes and the various ways of hooking mimalloc into a
program — and **not** a fork README. It is preserved here unaltered under the
name the rest of this repository uses for one:

* [`README.upstream.md`](README.upstream.md) — the tarball's `readme.md`, byte
  for byte, 64898 bytes, sha256
  `4da8b9090332b52c1fd26347415625a29f95320f440dfe225b84e87919c5beca`.

It is the whole file, not an extract, and nothing has been added to it. The
canonical fork document is [`README.md`](README.md).

Upstream's other two root documents travel beside it: `SECURITY.md` (its
supported-version statement and vulnerability-reporting address) and `LICENSE`
(the MIT grant). Both are digested in `UPSTREAM.sha256` as themselves.

## What was taken

52 files, 1166419 bytes. Every one is byte-identical to the tarball, and every
one is recorded by digest in [`UPSTREAM.sha256`](UPSTREAM.sha256).

| Path | Files | What it is |
|---|---:|---|
| `include/*.h` | 5 | the four headers upstream installs (`mimalloc.h`, `mimalloc-override.h`, `mimalloc-new-delete.h`, `mimalloc-stats.h`) plus `mimalloc-profile.h` |
| `include/mimalloc/*.h` | 7 | the internal headers: `types.h`, `bits.h`, `atomic.h`, `prim.h`, `prim-tls.h`, `internal.h`, `track.h` |
| `src/*.c`, `src/bitmap.h` | 24 | the portable core and its one internal header |
| `src/prim/**` | 13 | every platform implementation, the two dispatchers, and the platform documents and data files that live beside them |
| `LICENSE`, `README.upstream.md`, `SECURITY.md` | 3 | upstream's own root records |

That is the **complete compiled and installed closure**, in the sense that
matters for a build: everything `include/mimalloc.h` reaches, every
implementation file it can select at compile time, every header upstream's own
build installs, and every header that file needs.

Two things inside that set are carried but not compiled, and both are recorded
here rather than being quietly present:

* **`src/static.c` is retained and not compiled.** It is the whole-amalgamation
  translation unit — `src/static.c:23` includes `alloc.c`, which includes
  `alloc-override.c` and `free.c` — for a single-object build that a C++
  compiler can drop into another build, and upstream's own CMake compiles it
  only as its separate `mimalloc-obj` target (`CMakeLists.txt:1092`). Compiling
  it alongside the ordinary units would define every symbol twice. It is not a
  patch, and deleting it would have been: an upstream file that is simply
  uncompiled here is a build-graph fact, not a source deviation.
* **`src/alloc-override.c` is retained and not compiled as a unit, and is
  empty when compiled at all.** `src/alloc.c:19-22` `#include`s it textually,
  which is why upstream's `mi_sources` list has no entry for it, and
  `src/alloc-override.c:13` guards its whole body behind
  `#if defined(MI_MALLOC_OVERRIDE)`. This build never defines that macro, so
  the unit contributes nothing. [`README.md`](README.md), "This package does
  not replace your allocator", is the place that decision is argued at length.

`src/free.c` is the third file upstream does not compile separately, for the
same textual-include reason (`src/alloc.c:19-22`), and unlike the other two it
is genuinely compiled — as part of `alloc.c`.

## What was NOT taken

Named plainly, because a partial import is only honest when the omissions are
listed. Nothing below was edited, reformatted or "cleaned up before
importing"; none of it is in this repository at all.

| Path in the tarball | What it is | Why it was not vendored |
|---|---|---|
| `docs/` | upstream's own documentation site sources | not part of the compiled closure and not read by `zig build`; `README.upstream.md` already carries the project document that a consumer needs |
| `test/` | upstream's own test suite | this package's tests are its own, written against the Zig facade, and a second suite that cannot be built by this graph would be a claim with nothing behind it |
| `cmake/` | upstream's CMake helpers and package-config templates | this package uses no CMake at all; `build.zig` writes its own `mimalloc.pc` from the same fields |
| `ide/` | Visual Studio project files | IDE integration for a build system this package does not use |
| `bin/` | prebuilt binaries and runtime-selection helpers | a binary vendored into a source package is neither built from nor checked by this tree |
| `contrib/` | third-party and community material carried by upstream | material this package did not read cannot be licensed, digested or counted, and it is not in the compiled closure |
| `CMakeLists.txt` (root) | upstream's build description | **read, cited, not vendored.** `CMakeLists.txt:107-126` is where `core_sources` is read from, but the file is not redistributed: this package builds with Zig, and shipping upstream's build graph beside a build graph that replaces it invites the two to be read as alternatives |

Two further omissions are not directories at all:

* **`mi_collect_reduce` (`include/mimalloc.h:435`) and `mi_stats_merge`
  (`include/mimalloc.h:438`) are declared by the vendored header and defined
  nowhere in the v3.5.3 source closure.** They are upstream's, in upstream's
  `Deprecated` block, and this fork did not add them, stub them or patch the
  header to remove them. Both are excluded from the runtime loader's required
  symbol set in `runtime/graph.zig` (`provider_excluded`), and the Zig facade
  calls neither. [`FORK-NOTES.md`](FORK-NOTES.md) §6 has the full record.
* **The v1 and v2 source trees in the same release** are not vendored. They
  are separate release artifacts and a separate ABI; this SDK is the v3 line.

## Nothing is generated at build time, from upstream's side

mimalloc has no configure step, no generated header and no generated table:
the whole implementation is checked-in C, and `CMakeLists.txt` selects platform
macros rather than producing inputs. That is not an omission in this port —
there is nothing for a build step to generate from upstream.

This build does generate files, and none of them is a second source of truth
for the C: the `mimalloc.pc` it installs, a version script on ELF, and — only
under `-Druntime=true` — the runtime dispatch, which is generated from the
translation that same build has just produced for the target being built.

## Import mechanism

**A release tarball, imported whole, verified by sha256.** There was no
`git clone`, no submodule, no fetch of upstream's history and no patch series
applied on top. The tree either matches the tarball or a deviation is recorded;
`UPSTREAM.sha256` is the check that it does.

The commit SHA and the annotated tag object in the table at the top were read
from the GitHub API for the `v3.5.3` release, and are recorded as **provenance
metadata for a release that was downloaded, not as the identity of a VCS
import**. They cannot be used to reconstruct this tree and nothing here was
derived from them. The identity of the imported bytes is the sha256 and the
52 per-file digests.

If a future wave re-syncs to another release, the correct sequence is:
download the new `mimalloc-v*-source.tar.gz`, verify its published sha256,
replace the imported files, update `UPSTREAM.sha256`, `UPSTREAM.md`,
`NOTICE.md` and `README.md`, and add a numbered [`CHANGELOG.md`](CHANGELOG.md)
entry — in one change.

## Third-party material in this repository

None that was not read. There is no vendored dependency, no downloaded header
and no external data file. The 52 files in `UPSTREAM.sha256` are the complete
upstream material, and nothing was added to them.

The directories this package does not vendor — `docs/`, `test/`, `cmake/`,
`ide/`, `bin/`, `contrib/` — are listed above precisely so that this sentence
cannot be misread. Those directories exist in the release; their contents were
not imported and are not covered by any statement here, including any
statement about their licence. See [`NOTICE.md`](NOTICE.md) for the rule this
package applies: no licence is asserted for a file that was not read.