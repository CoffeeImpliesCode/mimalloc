# Notice

The 52 upstream files listed in `UPSTREAM.sha256` are distributed with the root `LICENSE`. That file is installed with the artifact.

## Root licence

```text
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

## Upstream per-file notices

44 files carry an MIT notice that points to the root `LICENSE`. The banner is:

```text
Copyright (c) <years> <holders>
This is free software; you can redistribute it and/or modify it under the
terms of the MIT license. A copy of the license can be found in the file
"LICENSE" at the root of this distribution.
```

Copyright lines and paths:

| Copyright line | Count | Paths |
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

## Exceptions and files without a per-file notice

`src/prim/windows/etw.h` contains `//* Copyright (c) Microsoft Corporation. All Rights Reserved.          *` and no grant. It is a Message Compiler generated include, carried unchanged. The package distributes it with the release's root `LICENSE`; this notice makes no separate licence claim for it.

These six files have no per-file notice and are covered by the root `LICENSE`:

| Path | Description |
|---|---|
| `src/prim/readme.md` | Upstream platform-layer note |
| `src/prim/windows/readme.md` | Upstream Windows-primitives note |
| `src/prim/windows/etw.man` | ETW manifest |
| `src/prim/windows/etw-mimalloc.wprp` | Windows Performance Recorder profile |
| `README.upstream.md` | Tarball's `readme.md`, copied byte for byte under this name |
| `SECURITY.md` | Upstream security policy |

`src/prim/emscripten/prim.c` names the additional holder Alon Zakai. No other per-file grant, carve-out, or alternate licence is recorded for the 52 imported files. `LICENSE` is the root grant, not a per-file notice.

## Fork-authored files

All repository files outside the 52 upstream paths recorded in `UPSTREAM.sha256` are fork-authored and covered by the collective MIT grant in `FORK-LICENSE.md`. No upstream author is credited for these additions.

No licence claim is made here for omitted upstream paths. `UPSTREAM.md` lists them. This inventory covers only the imported release files; it makes no claim for other mimalloc versions.
