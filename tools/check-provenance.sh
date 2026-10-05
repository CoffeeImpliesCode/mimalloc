#!/usr/bin/env bash
# Source-integrity check for the mimalloc SDK.
#
# Three questions, all answerable without a compiler:
#
#   1. Do the vendored upstream files still hash to the digests
#      UPSTREAM.sha256 records?
#   2. Is the vendored file set exactly that set -- no missing, extra or renamed
#      file under src/ at any depth (including src/prim/) or under include/ at
#      any depth?  A plain checksum run cannot see an addition.
#   3. Are the records themselves consistent with each other and with the tree:
#      the release digest in both records, the preserved upstream README, the
#      upstream copyright notice where it has to be, the MIT permission and
#      warranty text in FORK-LICENSE.md, and the one file whose notice is
#      "All Rights Reserved" rather than an MIT grant?
#
# This is a provenance gate, not a build gate. Nothing here compiles, links or
# runs a target binary; it is the check that an edit to the canonical native
# source cannot pass as a routine change.
#
# Every count this script prints is computed from UPSTREAM.sha256 or from
# `find`, never written here as a literal, so no number in the output can drift
# from the record it is checking. UPSTREAM.sha256 is likewise the only place the
# file set is listed: this script derives its expectations from the manifest
# rather than carrying a second copy that could disagree with the first.
#
# Usage: tools/check-provenance.sh   (run from anywhere in the repository)
#
# SPDX-License-Identifier: MIT

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    echo "$1" >&2
    exit 1
}

# The manifest, read once. Its paths are paths in this tree and not upstream's,
# because `sha256sum -c` below runs from the repository root and can only find a
# file by the name this tree gives it: that is why upstream's `readme.md`
# appears here as README.upstream.md. Every path in `recorded` is relative to
# this directory.
recorded=$(awk '/^[0-9a-f]{64}  / { print $2 }' UPSTREAM.sha256)
[ -n "$recorded" ] || fail "UPSTREAM.sha256 records no file digests"
recorded_count=$(awk '/^[0-9a-f]{64}  / { n++ } END { print n + 0 }' UPSTREAM.sha256)

# 1. Bytes.
sha256sum -c --quiet UPSTREAM.sha256 || fail "a vendored upstream file no longer matches UPSTREAM.sha256"
echo "all $recorded_count recorded upstream files match UPSTREAM.sha256"

# 2. File set. The three imported root files are named in the manifest rather
# than found by a `find` that would also walk this fork's own tree.
for root_record in LICENSE README.upstream.md SECURITY.md; do
    printf '%s\n' "$recorded" | grep -qx "$root_record" ||
        fail "UPSTREAM.sha256 records no digest for $root_record"
done
expected_tree=$(printf '%s\n' "$recorded" | awk '/^(include|src)\//' | LC_ALL=C sort)
actual_tree=$(find include src -type f | LC_ALL=C sort)
if [ "$expected_tree" != "$actual_tree" ]; then
    echo "the vendored file set differs from the recorded one:" >&2
    diff -u <(echo "$expected_tree") <(echo "$actual_tree") >&2 || true
    echo >&2
    echo "An intentional change to the native source needs an observed failure, a" >&2
    echo "small causal patch, an explicit per-file deviation record in NOTICE.md," >&2
    echo "updated digests here, and a CHANGELOG.md entry in the same change." >&2
    exit 1
fi
vendored_count=$(printf '%s\n' "$actual_tree" | awk 'END { print NR }')
echo "the vendored file set under src/ and include/ is exactly the recorded $vendored_count files"

# 3a. The release digest must be recorded identically in both records, so the
#     two files cannot disagree about which upstream release this is.
# `-m1` rather than a pipe into `head -1`: with `pipefail` a `head` that closes
# the pipe early sends SIGPIPE to grep and turns a successful match into a
# failed pipeline.
# `|| true` on both, so a file with no digest at all is reported by the two
# checks below with the reason rather than exiting on grep's status alone.
digest_md=$(grep -m1 -oE '[0-9a-f]{64}' UPSTREAM.md || true)
digest_list=$(grep -m1 -oE '[0-9a-f]{64}' UPSTREAM.sha256 || true)
[ -n "$digest_md" ] || fail "UPSTREAM.md records no sha256 digest"
[ -n "$digest_list" ] || fail "UPSTREAM.sha256 records no sha256 digest"
[ "$digest_md" = "$digest_list" ] ||
    fail "UPSTREAM.md and UPSTREAM.sha256 name different release digests"
echo "the release digest is recorded consistently: $digest_md"

# 3b. The preserved upstream README. Upstream's `readme.md` is imported under
#     the name README.upstream.md, so this tree holds one copy of it and not
#     two: there is no `readme.md` here to compare against, and adding one would
#     be a second copy that could then be edited away from the first. The
#     byte-identity that matters -- the import against the tarball's bytes -- is
#     check 1, which reads the digest the import was recorded under. What is
#     checked here is that the preserved file is still present, is still
#     upstream's own readme, and has not been replaced by this fork's README.md
#     under upstream's name.
[ -f README.upstream.md ] || fail "README.upstream.md is missing"
if [ -f README.md ] && cmp -s README.md README.upstream.md; then
    fail "README.upstream.md is a copy of this fork's README.md, not upstream's readme.md"
fi
grep -qE '^# mimalloc$' README.upstream.md ||
    fail "README.upstream.md does not carry upstream's own readme text"
echo "README.upstream.md is upstream's readme.md, unchanged and distinct from README.md"

# 3c. The upstream copyright notice. include/mimalloc.h carries a per-file MIT
#     banner whose year range and holder spelling are its own and are not the
#     line LICENSE carries, so it is matched exactly; the records may quote
#     either of upstream's spellings, so they are matched on the part they have
#     in common -- a Microsoft copyright inside this project's year range.
grep -qF 'Copyright (c) 2018-2026, Microsoft Research, Daan Leijen' include/mimalloc.h ||
    fail "the upstream copyright notice is missing from include/mimalloc.h"
for record in NOTICE.md README.md FORK-LICENSE.md; do
    grep -qE 'Copyright \(c\) 2018-20[0-9]{2}[, ]+Microsoft' "$record" ||
        fail "an upstream copyright notice is missing from $record"
done
echo "the upstream copyright notice is present in include/mimalloc.h and in the records"

# 3d. The MIT grant itself, in the record that carries the fork's own licence.
grep -q 'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND' FORK-LICENSE.md ||
    fail "FORK-LICENSE.md does not reproduce the MIT permission and warranty text"
echo "the MIT permission and warranty text is reproduced in FORK-LICENSE.md"

# 3e. The one vendored file whose notice is not a grant. src/prim/windows/etw.h
#     is generated by Message Compiler and carries only "Copyright (c) Microsoft
#     Corporation. All Rights Reserved." -- no year range, no permission text, no
#     warranty text. It is the file an over-eager licence sweep would rewrite,
#     and both halves are checked: the notice is still the one the file was
#     imported with, the file has not acquired a grant it never carried, and
#     NOTICE.md still records the exception.
grep -qF 'Copyright (c) Microsoft Corporation. All Rights Reserved.' src/prim/windows/etw.h ||
    fail "the reserved-rights notice is missing from src/prim/windows/etw.h"
if grep -qE 'Permission is hereby granted|THE SOFTWARE IS PROVIDED "AS IS"' src/prim/windows/etw.h; then
    fail "src/prim/windows/etw.h now carries a licence grant it was never imported with"
fi
grep -qF 'src/prim/windows/etw.h' NOTICE.md ||
    fail "NOTICE.md no longer records src/prim/windows/etw.h"
grep -qF 'All Rights Reserved' NOTICE.md ||
    fail "NOTICE.md no longer records the reserved-rights notice"
echo "src/prim/windows/etw.h keeps its reserved-rights notice and NOTICE.md records it"

echo "provenance checks passed"
