# FORK-LICENSE.md — the grant for this fork's own files

[`NOTICE.md`](NOTICE.md) is the inventory: which files are upstream's, which
are this fork's, and which term covers each. This file is the grant itself,
for the second group only.

## 1. The native source is not covered by anything below

The 52 files digested in [`UPSTREAM.sha256`](UPSTREAM.sha256) — `LICENSE`,
`README.upstream.md`, `SECURITY.md`, all of `include/` and all of `src/` — are
mimalloc's, whole from `mimalloc-v3.5.3-source.tar.gz` and never edited.

Their terms are the MIT grant in that release's root `LICENSE`,
`Copyright (c) 2018-2025 Microsoft Corporation, Daan Leijen`, with the
per-file variations `NOTICE.md` records: the year range and the holder name
differ from file to file, `src/prim/emscripten/prim.c` adds a third holder,
`src/prim/windows/etw.h` carries a copyright line with no grant in the file at
all, and six files carry no notice of their own.

Nothing in this file re-grants, narrows, widens or conditions any of that
terms, and nothing here asserts that Microsoft Research, Microsoft Corporation,
Daan Leijen or Alon Zakai wrote, reviewed or endorsed a line of fork code.

## 2. The fork-authored material

Everything else in this repository — the Zig build graph and manifest, the
typed module and its tests, the example program, the consumer package, the
runtime-loading route, the packaging, the integrity and provenance records, and
the documentation — was written for this fork. The runtime-loading route is the
six files under `runtime/`: the reusable loader core, this SDK's descriptor,
the build half that wires them together, the build-time dispatch generator, and
the two C files that supply the namespaced process-global synchronization the
descriptor binds. All six are fork work under this grant; none of them is
upstream material, none is derived from a third-party source, and `sync.c` is
not a substitute for any upstream unit.

`NOTICE.md` names the files one by one. This section grants them.

### Grant

**Those files are released under the MIT License**, matching the primary
upstream term of this project, whose text is:

```
MIT License

Copyright (c) 2026 the contributors to this fork

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

The same obligation MIT imposes on mimalloc applies to this text: keep the
notice with copies of the fork's files.

### Authority for that grant

The owner of this repository authorized per-project licensing for
fork-authored additions as part of the SDK contract migration, with the term
chosen per project to match that project's primary upstream terms where that
is appropriate. mimalloc's primary upstream term is plain MIT, so MIT is the
choice. The authorization is recorded here and in `NOTICE.md`; the term above
is the owner's, reached by that authorization and **not** by any upstream grant.

The owner is not named and no individual copyright holder is invented: the
copyright line above is deliberately the collective one.

### SPDX identifier

```
MIT
```

The plain registered identifier, with no `LicenseRef-` wrapper. That is a
deliberate distinction rather than a shortcut: a fork whose primary term
carries added conditions needs an identifier that names them, because a
consumer scanning for `MIT` would otherwise stop reading and miss the
conditions. **mimalloc's term is bare MIT** — the same grant, the same one
condition, no per-file exception to the grant itself (`NOTICE.md`, "Per-file
exceptions") — so `MIT` is the accurate identifier and inventing a
`LicenseRef-` would misrepresent a plain grant as a variant one.

Every fork-authored **source, build, packaging and script** file carries
`SPDX-License-Identifier: MIT` on its own first comment line where a comment
position exists. The documentation and digest records carry no tag, because a
Markdown file has no identifier position; `NOTICE.md` names each of them
explicitly so that a scanner finding no identifier in `README.md` reads a
recorded reason rather than an apparent gap.

### What this does not do

* It does not re-license, sublicense or add a condition to any mimalloc file,
  and it says nothing about the terms of `src/prim/windows/etw.h`, which
  upstream's own release carries without a grant in the file.
* It does not assert that Microsoft Research, Microsoft Corporation, Daan
  Leijen, Alon Zakai or any other upstream author authored, reviewed, endorsed
  or is affiliated with the fork's files.
* It does not discharge mimalloc's attribution obligation. A consumer who
  ships a mimalloc v3.5.3 binary, static or shared library, any of its
  headers, or any vendored source file still owes the notice in `LICENSE`; see
  `NOTICE.md` for where it travels and `README.md` for what is installed.
* It does not claim that MIT is the only term the owner could have chosen for
  independently authored work. It is the term chosen, and it happens to match
  upstream's.

## 3. Material carried but not authored here

The only carried material is the 52 upstream files in `UPSTREAM.sha256`. There
is no third-party code, no downloaded header and no external data file in this
repository, and nothing was added to the upstream files.

Upstream's release also ships `docs/`, `test/`, `cmake/`, `ide/`, `bin/`,
`contrib/` and the root `CMakeLists.txt`. **None of them is vendored here** and
none is redistributed, so no statement in this file or in `NOTICE.md` covers
their contents; `NOTICE.md`, "Files no licence is asserted for", says so
explicitly. The v1 and v2 source trees published in the same `v3.5.3` release
are likewise separate artifacts and are not here.

The two files this build generates are not carried material either, and the
distinction is worth keeping exact rather than dropping a category to make the
sentence short. Under `-Druntime`, `runtime/graph.zig` runs
`runtime/generate.zig` over the translation step's real output through
`Run.addOutputFileArg`, so the dispatch and the generator's patched translation
both land in the build cache rather than in this tree. They are built from the
translation of `zig/translate.h` and upstream's own headers that this same build
has just produced for the target being built. Nothing is fetched to make them,
no third-party code is in them, and neither is installed or shipped: every file
under `runtime/` in this tree is a fork-authored file under section 2.

## 4. Why a separate file at all

`NOTICE.md` names which fork-authored files carry an `SPDX-License-Identifier`
line and which carry the same grant in prose without one. This file exists so
that the authority, the grant text and the limits of that grant live in one
place, next to the inventory rather than scattered across the files themselves —
and so that a consumer who receives a fork-authored file alone still has the
grant, rather than having to reconstruct it from a table that travelled
separately.