# Changelog

- Document the separate provider variables required by runtime tests, smoke checks, and the consumer.
- Fix runtime test provider paths, exclude override-only size aliases from required symbols, report missing names, and complete COFF public exports.
- Exclude static-only baseline targets from shared-linkage and runtime-loading check graphs.
- Port to Zig 0.17.0.
- Forward nested build cache settings through the environment and configure WASI page sizing and clock emulation.
- The root consumer step runs host-native targets and installs foreign targets.
- Added `mi_expand` to the Zig facade and made output callbacks nullable.
- Added runtime loading with explicit `path` or `system` provider selection.
- Added mimalloc v3.5.3 as a Zig package with linkage options, installed headers, `mimalloc.pc`, and a typed facade.
