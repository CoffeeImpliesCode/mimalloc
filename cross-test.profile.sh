# cross-test settings profile for the mimalloc SDK.
#
# `cross-test` looks for this file at the root of the project it is run from
# (or names it with --profile; --no-profile ignores it). It is trusted Bash that
# the harness `source`s, so this file is *settings only*: ordinary variable
# assignments and nothing else. No command runs, no compiler is probed, and no
# path in here names a host.
#
# There is deliberately no CROSS_MATRIX. The published 53-platform Zig 0.16
# Tier 1/2 table is the matrix this package is checked against, and a matrix
# named here would replace it. There is no TARGETS array either, for the same
# reason: a subset selected here would narrow the run rather than add to it.
# Both belong on the command line, where --targets selects from the active
# matrix and never adds to it.
#
# CROSS_BUILD_STEP stays the standard `test` step, which is what this profile
# states explicitly. There are no `cross_build_command` / `cross_artifact`
# hooks here, so the harness keeps its standard Zig-build mode and runs
# `zig build test -Dtarget=TARGET` per target with a fresh cache. What that
# means for a given target is the harness's decision, not this package's: a
# host target runs, a foreign target runs under whatever executor the harness
# detects (QEMU user mode, Wine, wasmtime), and a foreign target with no
# executor is reported as build-only coverage -- compiled, never executed, and
# never counted as a pass. `build.zig` gives the test binary a Run step
# (`addRunArtifact`) for every target, which is what leaves that choice open.
#
# A target graph compiles the whole 21-unit closure of upstream's `mi_sources`
# list -- the list `CMakeLists.txt:107-126` names, which `build.zig:152-174`
# reproduces in upstream's order -- and translates `mimalloc.h` with
# `b.addTranslateC` for that target, and links the facade and the test root
# against it. Each matrix cell does all of that from a fresh cache, including
# its own `src/prim/*/prim.c`: the platform implementation is `#include`d as
# text by `src/prim/prim.c:11-25`, so the same 21 paths compile a different
# body on every row.
#
# Four build jobs, not the machine's core count. The units here are short --
# this is the reason the two timeouts below are also modest -- but a cell is
# cold-cache work, and leaving jobs for the harness and for whatever else the
# host is doing is worth more than the last pair of parallel translation units.
# CROSS_BUILD_TIMEOUT is the ceiling for one cell and CROSS_TIMEOUT for the
# run of one cell's binary; both are well above what this closure needs, and
# both exist to turn a hung runner into a recorded failure rather than a run
# that never ends.
#
# Nothing here narrows the gate to what is expected to work. Which platforms
# this source can be built for is upstream's own answer in `src/prim/prim.c` and
# the `src/prim/` tree behind it, and `build.zig` resolves those macros from the
# target being built. A cell that fails is a fact to record and diagnose; it is
# not a reason to drop the cell, sample the tests or remap Debug to an optimized
# mode to make it pass.

CROSS_BUILD_STEP=test
CROSS_BUILD_JOBS=4
CROSS_BUILD_TIMEOUT=1800
CROSS_TIMEOUT=900
