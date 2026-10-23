# FORK-LICENSE.md

## Scope

This grant applies only to fork-authored files listed in `NOTICE.md`.

The only carried upstream material is the 52 files in `UPSTREAM.sha256`: `LICENSE`, `README.upstream.md`, `SECURITY.md`, and all of `include/` and `src/` from `mimalloc-v3.5.3-source.tar.gz`. These files are unchanged. No other third-party code, downloaded header or external data is included.

Upstream files retain the release's MIT term, `Copyright (c) 2018-2025 Microsoft Corporation, Daan Leijen`; per-file year and holder variations are listed in `NOTICE.md`. `src/prim/emscripten/prim.c` adds a third holder; `src/prim/windows/etw.h` has a copyright line but no grant; six files have no notice.

Everything else in this repository—the Zig build graph and manifest, typed module and tests, example, consumer package, runtime-loading route, packaging, integrity and provenance records, and documentation—is fork-authored and covered by this grant. The six files under `runtime/` are fork-authored, including `sync.c`; none is upstream material or derived from a third-party source, and `sync.c` is not a substitute for an upstream unit.

## Grant

The repository owner authorized independent licensing of fork-authored additions. The owner is unnamed; the copyright line uses collective attribution to fork contributors. This MIT grant is the owner's and does not derive from upstream.

Fork-authored files listed in `NOTICE.md` are released under the MIT License:

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

The fork's MIT grant has no per-file exceptions.

## SPDX

```
MIT
```

Fork-authored source, build, packaging and script files carry `SPDX-License-Identifier: MIT` where a comment position exists. Documentation and digest records have no tag; `NOTICE.md` lists them.

## Attribution and excluded material

This grant does not alter upstream's terms or imply Microsoft Research, Microsoft Corporation, Daan Leijen, Alon Zakai or other upstream authors wrote, reviewed or endorsed fork files.

Consumers shipping mimalloc v3.5.3 binaries, static or shared libraries, headers, or vendored source must retain the notice in `LICENSE`; `NOTICE.md` states where it is installed, and `README.md` lists installed files.

The upstream release's `docs/`, `test/`, `cmake/`, `ide/`, `bin/`, `contrib/`, and root `CMakeLists.txt` are not vendored or redistributed; their contents are not covered. The release's separate v1 and v2 source trees are not included.

The generated dispatch and patched translation live in the build cache. They are generated from `zig/translate.h` and upstream headers; nothing is fetched to make them, no third-party code is in them, and neither is installed or shipped. Every tracked file under `runtime/` is fork-authored under this grant.
