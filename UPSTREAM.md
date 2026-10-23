# Upstream

| Field | Value |
|---|---|
| Project | mimalloc, Microsoft Research (Daan Leijen) |
| Site | <https://github.com/microsoft/mimalloc/> |
| Release | v3.5.3 |
| Published | 2026-09-17; upstream README says 2026-09-16 |
| Source archive | `mimalloc-v3.5.3-source.tar.gz` |
| Archive URL | <https://github.com/microsoft/mimalloc/releases/download/v3.5.3/mimalloc-v3.5.3-source.tar.gz> |
| Archive size | 1,458,292 bytes |
| Archive SHA-256 | `43857a9e4f26412e970cbe49635d0465c2de6e77a697ce3d4b926a473d1045ca` |
| Annotated tag object | `deac3dcf5f0614884013d411a5c07e16bec96c9f` (`v3.5.3`) |
| Commit | `d4881d338125e1cb7c47ba4cfb398d6f7c0c8d45` |

Imported from the release tarball, not a VCS checkout; no patch series was applied. The 52 imported files total 1,166,419 bytes. `UPSTREAM.sha256` records their digests.

## Imported paths

| Path | Files | Contents |
|---|---:|---|
| `include/*.h` | 5 | Public headers, including `mimalloc-profile.h` |
| `include/mimalloc/*.h` | 7 | Internal headers |
| `src/*.c`, `src/bitmap.h` | 24 | Core sources and internal bitmap header |
| `src/prim/**` | 13 | Platform implementations, dispatchers, documents, and data |
| `LICENSE`, `README.upstream.md`, `SECURITY.md` | 3 | Upstream root records |

`README.upstream.md` is the tarball's root `readme.md`, copied byte for byte: 64,898 bytes, SHA-256 `4da8b9090332b52c1fd26347415625a29f95320f440dfe225b84e87919c5beca`.

## Not imported

| Upstream path | Contents |
|---|---|
| `docs/` | Documentation site sources |
| `test/` | Upstream test suite |
| `cmake/` | CMake helpers and package templates |
| `ide/` | Visual Studio project files |
| `bin/` | Prebuilt binaries and runtime-selection helpers |
| `contrib/` | Third-party and community material |
| Root `CMakeLists.txt` | Upstream build description; read for source selection, not copied |
| mimalloc v1 and v2 source trees | Separate source lines; this package imports v3 only |

The omitted paths were not imported and are not covered by the licence inventory in `NOTICE.md`.
