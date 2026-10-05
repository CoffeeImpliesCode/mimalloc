# Notice

Two separate things are recorded here: which grant covers each of the 52
vendored upstream files, and what this fork wrote on top of them.
[`FORK-LICENSE.md`](FORK-LICENSE.md) carries the grant for the second group.

**This is a per-file inventory, and the tree does not reduce to one label.**
mimalloc is MIT at the root, but its own files are not uniform: the copyright
year range differs from file to file, the holder name differs between the root
`LICENSE` and the per-file banners, one file names a third holder, one file
carries a copyright line with no grant in it at all, and six files carry no
notice of their own. Grouping them as "MIT" and moving on would lose all five
of those facts.

## The upstream term

mimalloc's root `LICENSE` is the plain two-clause MIT text with no added
condition, no exception clause and no alternative grant. Verbatim, the whole
file:

```
MIT License

Copyright (c) 2018-2025 Microsoft Corporation, Daan Leijen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Note the holder line and the period: the root grant says **Microsoft
Corporation, Daan Leijen**, `2018-2025`, and the permission clause ends
`NONINFRINGEMENT.` with a single space before the sentence break. Every
compiled `.c` and `.h` file carries its **own** banner instead, naming
**Microsoft Research**, not Microsoft Corporation, and with a period-terminated
wording of its own. Both are upstream's own text; neither has been edited, and
neither is restated from the other here.

`LICENSE` is the authoritative copy of the grant in this tree and it is
installed with the artifact, so an installed tree carries the obligation with
it.

## Inventory of the vendored upstream files

52 files, 1166419 bytes, every digest in
[`UPSTREAM.sha256`](UPSTREAM.sha256). The four groups below partition all 52.

### (a) Files carrying upstream's own MIT grant in the file — 44 files

Each of these opens with a four-line banner that names its own copyright years,
its holders, and points at the root `LICENSE` for the terms. The banner text is
the same in all of them apart from the years and the holders:

```
Copyright (c) <years> <holders>
This is free software; you can redistribute it and/or modify it under the
terms of the MIT license. A copy of the license can be found in the file
"LICENSE" at the root of this distribution.
```

So the per-file grant is "the MIT license", located by reference at
`LICENSE`, with a per-file copyright line. **The year range is not the same in
every file and neither is the punctuation** — some banners write
`2019-2026, Microsoft Research, Daan Leijen` with a comma after the years and
some write `2019-2026 Microsoft Research, Daan Leijen` without one — so the
following table groups by the exact banner each file carries, and a consumer
who needs one file's line has it here rather than inferring one from another.

| Copyright line, as it stands in the file | Count | Files |
|---|---:|---|
| `Copyright (c) 2018-2020 Microsoft Research, Daan Leijen` | 3 | `include/mimalloc-new-delete.h`, `include/mimalloc-override.h`, `src/static.c` |
| `Copyright (c) 2018-2021, Microsoft Research, Daan Leijen` | 1 | `src/alloc-posix.c` |
| `Copyright (c) 2018-2022, Microsoft Research, Daan Leijen` | 1 | `src/prim/osx/alloc-override-zone.c` |
| `Copyright (c) 2018-2023, Microsoft Research, Daan Leijen` | 4 | `include/mimalloc/track.h`, `src/prim/osx/prim.c`, `src/prim/wasi/prim.c`, `src/prim/windows/prim.c` |
| `Copyright (c) 2018-2024 Microsoft Research, Daan Leijen` | 3 | `include/mimalloc/atomic.h`, `src/page-queue.c`, `src/page.c` |
| `Copyright (c) 2018-2026, Microsoft Research, Daan Leijen` | 20 | `include/mimalloc.h`, `include/mimalloc/internal.h`, `include/mimalloc/prim-tls.h`, `include/mimalloc/prim.h`, `include/mimalloc/types.h`, `src/alloc-aligned.c`, `src/alloc-override.c`, `src/alloc.c`, `src/free.c`, `src/heap.c`, `src/init.c`, `src/libc.c`, `src/options.c`, `src/os.c`, `src/prim/prim-tls.c`, `src/prim/prim.c`, `src/prim/unix/prim.c`, `src/stats.c`, `src/subproc.c`, `src/theap.c` |
| `Copyright (c) 2018-2026, Microsoft Research, Daan Leijen, Alon Zakai` | 1 | `src/prim/emscripten/prim.c` |
| `Copyright (c) 2019-2021, Microsoft Research, Daan Leijen` | 1 | `src/random.c` |
| `Copyright (c) 2019-2024 Microsoft Research, Daan Leijen` | 2 | `include/mimalloc/bits.h`, `src/bitmap.h` |
| `Copyright (c) 2019-2026, Microsoft Research, Daan Leijen` | 4 | `src/arena.c`, `src/sample-guarded.c`, `src/sample-profile.c`, `src/threadlocal.c` |
| `Copyright (c) 2019-2026 Microsoft Research, Daan Leijen` | 1 | `src/bitmap.c` |
| `Copyright (c) 2023-2026, Microsoft Research, Daan Leijen` | 1 | `src/page-map.c` |
| `Copyright (c) 2024-2026, Microsoft Research, Daan Leijen` | 2 | `include/mimalloc-profile.h`, `include/mimalloc-stats.h` |

By extension that is **31 `.c` files and 13 `.h` files**: all 12 headers under
`include/` (5 public plus 7 internal) and `src/bitmap.h`. It is the whole of
`include/` plus the one internal header in `src/`; `src/prim/windows/etw.h` is
the only other header under `src/` and it is group (b) below.

Two of these deserve to be called out rather than left in a count:

* **`src/prim/emscripten/prim.c` names a third holder.** Its banner is
  `Copyright (c) 2018-2026, Microsoft Research, Daan Leijen, Alon Zakai` — one
  more name than any other file in the tree. A consumer reproducing a notice
  has to reproduce that file's line, not the modal one.
* **`src/static.c` is in this group and is not compiled.** Its banner says the
  same MIT terms as the 20 files that are; it simply is not in `core_sources`.
  See [`UPSTREAM.md`](UPSTREAM.md), "What was taken".

The compiled set is a strict subset of this group: `src/static.c`,
`src/alloc-override.c` and `src/free.c` carry the MIT banner but are not
separately compiled — see [`FORK-NOTES.md`](FORK-NOTES.md) §3. The term is
unaffected; the compile graph is a separate question and it has its own record.

### (b) `src/prim/windows/etw.h` — a copyright line with no grant in the file

**One file, and it is not MIT in its own text.** `src/prim/windows/etw.h:4`
reads, inside the Message Compiler banner:

```
//* Copyright (c) Microsoft Corporation. All Rights Reserved.          *`
```

There is no MIT grant anywhere in the file, no reference to `LICENSE`, no
permission and no warranty disclaimer. It is the only vendored file in that
state.

It is a **Message Compiler generated include** — one of the set Microsoft ships
for the ETW (Event Tracing for Windows) consumer SDK, alongside
`src/prim/windows/etw.man` and `src/prim/windows/etw-mimalloc.wprp` in this
same directory — and it is generated, not authored by mimalloc's authors.
`"All Rights Reserved."` is a copyright assertion, not a grant.

How this package records that, precisely and without over-claiming:

* The file is **carried unaltered and is not compiled** by this build. It is
  digested in `UPSTREAM.sha256` under its own name and nothing else.
* It is **covered by the root `LICENSE`** as a file of the release, and this
  package distributes it under the release's own terms exactly as it received
  it. That is a statement about redistribution, not a determination that
  Microsoft intended the file to be MIT, and it is not the same claim as
  groups (a) and (c).
* **No licence is asserted for this file beyond what the release and the root
  `LICENSE` say.** A consumer with a question about the ETW headers' own terms
  has to ask Microsoft; this record does not answer it.

### (c) Files carrying no per-file notice at all — 6 files

None of these has a copyright line, a grant, or a reference to `LICENSE`
anywhere in it. They are covered by the root `LICENSE` as files of the
release:

| File | What it is | Why there is no notice in it |
|---|---|---|
| `src/prim/readme.md` | upstream's own note about the platform layer and how to add one | a Markdown document |
| `src/prim/windows/readme.md` | upstream's own note about the Windows primitives, ETW and the redirection module | a Markdown document |
| `src/prim/windows/etw.man` | the ETW manifest, as `mc` consumes it | a generated-format data file |
| `src/prim/windows/etw-mimalloc.wprp` | the Windows Performance Recorder profile for mimalloc's ETW provider | an XML profile consumed by WPR; there is no comment position a notice occupies |
| `README.upstream.md` | the tarball's own `readme.md`, byte for byte | it is upstream's document, and it carries no licence text |
| `SECURITY.md` | upstream's supported-version statement and vulnerability-reporting address | a policy document |

`README.upstream.md` is the one that most often gets counted wrong: it is a
**fork-side copy under a fork-side name**, and it is deliberately digested as
itself (`4da8b909...`) rather than being treated as a file upstream ships
under that name. The tarball ships `readme.md`; this repository installs it as
`README.upstream.md`.

`LICENSE` itself is not in this group or in any other: it is the root grant,
the copy group (b) and (c) are covered by.

### (d) What this package itself carries

Everything else in this repository was written for this fork. None of it is
upstream material, none of it is derived from a third-party source, and it is
released under the owner's grant in
[`FORK-LICENSE.md`](FORK-LICENSE.md), **not** under upstream's MIT terms —
upstream's terms do not grant rights to fork-authored additions, and no
upstream author is credited with any of it:

* `build.zig`, `build.zig.zon` — the build graph and the package manifest
* `zig/root.zig` — the typed Zig facade, the only module published to a
  dependent
* `zig/translate.h` — the one header the translation step is handed
* `runtime/loader.zig`, `runtime/library.zig`, `runtime/graph.zig`,
  `runtime/generate.zig`, `runtime/sync.c`, `runtime/sync.h` — the runtime
  loading route: the reusable loader core, this SDK's descriptor, the build
  half that wires them together, the build-time dispatch generator, and the
  two C files that give the loader its namespaced process-global mutex,
  condition variable and thread identity (`RT_SYNC_PREFIX=mimalloc_rt`).
  All six are fork work; none substitutes for an upstream unit.
* `tests.zig`, `smoke.zig` — this package's own tests and example
* `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig` — the
  separate consumer package
* the packaging (`package.nix`, `flake.nix`, `flake.lock`, `devenv.nix`,
  `devenv.yaml`, `.envrc`) and the provenance driver
  (`cross-test.profile.sh`, `.github/workflows/verify.yml`)
* `.gitignore`
* this file, `README.md`, `README.zig.md`, `UPSTREAM.md`, `UPSTREAM.sha256`,
  `FORK-LICENSE.md`, `CHANGELOG.md`, `FORK-NOTES.md`

Fork-authored **source, build, packaging and script** files carry
`SPDX-License-Identifier: MIT` on their own first comment line, where a comment
position exists at all — `//` for Zig, `/* */` for C, `#` for Nix and shell.
Read out of the files rather than assumed, that is: `build.zig`,
`build.zig.zon`, `zig/root.zig`, `tests.zig`, `package.nix`, all six files of
`runtime/` (`loader.zig`, `library.zig`, `graph.zig`, `generate.zig`, `sync.c`
and `sync.h`), and the test and consumer roots as they land. Several of them
also name this file and `FORK-LICENSE.md` on the next line.

The prose records — this file and the seven documentation files beside it —
carry no tag, because a Markdown file has no identifier position and their grant
is the same MIT text recorded in `FORK-LICENSE.md`. `.gitignore` and the
remaining script files carry the grant without a tag for the same reason. They
are named here rather than left for a scanner to read as unlicensed.

Upstream's attribution obligation is unaffected by any of this: a consumer who
receives a mimalloc v3.5.3 binary, static or shared library, or any of its
headers, still owes the notice above, and the installed tree carries
`LICENSE` for it.

## Per-file exceptions

**Two, and they are the point of this file.**

1. `src/prim/windows/etw.h` carries a copyright line with **no grant in the
   file** — group (b) above.
2. `src/prim/emscripten/prim.c` names a **third copyright holder**, Alon
   Zakai, that no other file names — group (a) above.

Beyond those two there is no dual-licensing clause, no public-domain
dedication, no copyleft component, no per-file carve-out from the MIT grant and
no alternative grant anywhere in the 52 vendored files. Every one of them is
either under the root MIT `LICENSE` or, in the single case of `etw.h`, under
whatever the release and that root `LICENSE` say about it.

That is a statement about **this** release, not about all of mimalloc's
history. Earlier and later work by the same authors is not covered by it, and
neither is the v1 and v2 source trees published in the same release.

## What this fork changed in upstream files

**Nothing.** Not one byte of the 52 vendored files has been edited: no
portability patch, no reformat, no `#if` wrapped around a platform workaround,
no header edited to remove a declaration upstream wrote.
`UPSTREAM.sha256` is what makes that checkable rather than asserted, and any
future native edit has to move those digests, add a per-file record here and
add a numbered entry to [`CHANGELOG.md`](CHANGELOG.md) — in the same change,
and with an observed failure to justify it.

What this fork did change is *which* upstream files get compiled, and with what
flags: `-std=gnu11`, `MI_WIN_NOREDIRECT=1` on Windows, `MI_MALLOC_OVERRIDE`
never. All five are build-graph decisions, listed in
[`README.md`](README.md), "Native-build deviations", and none of them is a
source edit.

`STATUS`: `SOURCE-CONFIRMED`, read out of the vendored files and the recorded
digests. That is a claim about bytes and about what this file asserts about
them, and it is **not** a build result: no gate has been run for this package.
[`README.md`](README.md) carries the gate table, and every row in it reads
`PENDING-VERIFICATION`.

## Files no licence is asserted for

Upstream's release carries directories this package did not vendor — `docs/`,
`test/`, `cmake/`, `ide/`, `bin/`, `contrib/` — and the root `CMakeLists.txt`.
They are named in [`UPSTREAM.md`](UPSTREAM.md) so the omission is on the
record, and **no licence, notice or term is asserted here for any file in
them**, because this package did not read them. Nothing in this inventory
covers their contents, and nothing in this repository redistributes them.

The same rule applies to anything else: a file this package did not read has
no asserted licence here. That is the preferred answer, not a gap to be filled
with a guess.