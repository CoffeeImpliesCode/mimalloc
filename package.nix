# Source-only package derivation for the mimalloc SDK.
#
# One file, consumed by both flake.nix and devenv.nix, so the two entry points
# cannot describe different packages. It builds nothing but this repository: the
# native source is upstream's `include/` and `src/`, which is the whole of what
# this repository imports -- every header and every source, including the files
# the build compiles none of -- and build.zig owns the 21-unit source list,
# every compile flag, the generated pkg-config file and the whole installed
# layout. Nothing here restates a C flag, runs CMake, fetches a tarball,
# reaches into a sibling checkout, or installs an artifact of its own. The
# one edit it makes is the rpath of the ELF files the build installed: Zig
# records its own build cache there, and that directory does not exist once a
# binary is installed.
#
# What the import leaves out is upstream's documentation, its own test tree and
# its build system (`docs/`, `test/`, `cmake/`, `ide/`, `bin/`, `contrib/` and the
# top-level `CMakeLists.txt`). UPSTREAM.md, "What was NOT taken", records each
# one with its reason, and this file has no opinion about them: the Nix output
# is the library, and the library compiles none of them.
#
# One derivation, two variants. `linkage` is Zig's own `std.builtin.LinkMode`
# spelling passed straight through, so "static" and "dynamic" are two builds of
# this same tree rather than two packages. Static is the default because it is
# what `build.zig` delivers when a caller asks for nothing. The entry points
# name the pair: `flake.nix` exposes them as `packages.mimalloc-static` and
# `packages.mimalloc-shared` and groups both under `packages.mimalloc`, and
# `devenv.nix` exposes them as `outputs.static` and `outputs.shared`.
#
# This package does not make mimalloc the process allocator. `MI_MALLOC_OVERRIDE`
# is never defined by this build, so `src/alloc-override.c` stays empty and the
# installed artifact exports `mi_malloc` and `mi_free` and not `malloc`, `free`
# or the C++ operators (`build.zig:31-45`). A Nix consumer gets the same
# library this repository builds, not a linker that silently replaces the
# allocator of every process in the store.
#
# No lock file is written here. `flake.lock` and `devenv.lock` belong to the
# driver.
#
# SPDX-License-Identifier: MIT
# See FORK-LICENSE.md for what that identifier covers, and NOTICE.md for the
# per-file notices the import carries -- upstream's own `LICENSE` is MIT, but
# `src/prim/windows/etw.h` carries only "All Rights Reserved" and no grant.

{ lib
, stdenv
, zig
, patchelf
  # Zig's own `std.builtin.LinkMode` spelling, passed straight through as
  # `-Dlinkage`. "static" and "dynamic" are two variants of one derivation, and
  # `""` passes nothing at all so the graph's own default policy runs unchanged.
  # mimalloc upstream builds both an object-only amalgamation and a normal
  # library and lets CMake pick; this package's policy is the archive, and
  # `.dynamic` is the separate variant.
, linkage ? "static"
, optimize ? "ReleaseSafe"
}:

let
  requestedLinkage =
    if builtins.elem linkage [ "" "static" "dynamic" ] then linkage
    else throw "package.nix: linkage must be \"\", \"static\" or \"dynamic\", not ${toString linkage}";

# Everything except build outputs, version control and developer-tool state.
# Filtering by directory name rather than by an allow list means a file added
# here later is packaged without editing this file, while `.zig-cache/`,
# `zig-out/`, `.devenv/`, `.direnv/` and `result` stay out of a published output
# at any depth, including under consumer/. Upstream's per-file readmes, the ETW
# material and `SECURITY.md` are deliberately kept: they are upstream material
# with digests in UPSTREAM.sha256, and the audit surface is the whole upstream
# tree.
  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: _type:
      let name = builtins.baseNameOf (toString path); in
      !(lib.elem name [
        ".git"
        ".direnv"
        ".devenv"
        ".zig-cache"
        "zig-cache"
        "zig-pkg"
        "zig-out"
        "result"
      ]);
  };

# patchelf rewrites ELF rpaths and does not read Mach-O, so the rpath
# normalisation in the install phase exists for ELF targets only, and the tool is
# a build input exactly where that code runs.
isElfTarget = !stdenv.hostPlatform.isDarwin;
in

# These packages build for the compiler's own native target. A cross build here
# would mean hand-building a libc-suffixed triple that has to track nixpkgs, so
# this derivation refuses one instead of silently producing a host-architecture
# library under a foreign name. The comparison is against stdenv's own
# platforms, which are pure values; `builtins.currentSystem` is not evaluable
# in a sandbox and is not used. A remote builder is unaffected: this compares
# build against host, not against any particular machine.
assert stdenv.buildPlatform.system == stdenv.hostPlatform.system;

stdenv.mkDerivation {
  pname = "mimalloc";
  version = "3.5.3";

  inherit src;

  strictDeps = true;
  dontPatch = true;

  # The real work is one `zig build install` in installPhase below. Disabling
  # configure and build phases keeps the Zig setup hook from running a first,
  # differently-flagged build of its own; `dontInstall` is deliberately NOT set,
  # because that is what would disable the real install phase.
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ zig ] ++ lib.optional isElfTarget patchelf;

  # mimalloc reaches the C library and the C standard library from every
  # translation unit, and on Windows it would need the kernel32 import library
  # that stdenv's own cc brings in. Nothing else is propagated. Upstream's
  # pkg-config template records `-lpthread` under `Libs.private`, which is where
  # a private link dependency of a shared object belongs and is reproduced in the
  # file build.zig generates (`build.zig:1043`).
  propagatedBuildInputs = [ stdenv.cc.libc ];

  # The driver owns every gate for this SDK, and a Nix build is not a
  # verification receipt. No check phase is declared here rather than a check
  # phase that runs something smaller than the real gates; the commands that do
  # verify this package are in README.md and CHANGELOG.md.
  doCheck = false;
  dontUseZigCheck = true;

  installPhase = ''
    runHook preInstall

    # Both caches go under the Nix-provided TMPDIR, outside the unpacked source
    # tree, so a build cannot write into $src and so two parallel derivations
    # cannot share state. Any caller-supplied cache variables are left alone:
    # they are the caller's scratch, not this file's to clear.
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"

    # build.zig owns the source list, the C flags, the platform macros, the
    # generated pkg-config file, the licence records and every installed path.
    # Declaring any of them here as well would create a second place where they
    # can disagree with the build graph.
    #
    # -Dcpu=baseline because Zig's default target resolution takes the build
    # machine's CPU model, so an artifact built on one machine can demand
    # instructions another machine of the same architecture does not have.
    # baseline asks for the architecture floor instead, which is the portable
    # choice for a store output.
    #
    # -Dsystem=false names the bundled route explicitly. `systemIntegrationOption`
    # already defaults to bundled, but this derivation's whole subject is the
    # library compiled from this repository, and leaving that to a default a
    # caller could change is not a statement.
    zig build install \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=${optimize} \
      -Dcpu=baseline \
      -Dsystem=false \
      ${lib.optionalString (requestedLinkage != "") "-Dlinkage=${requestedLinkage}"}

    # Zig records the build cache in the rpath of anything that links a dynamic
    # artifact it has just built (lib/std/Build/Step/Compile.zig:1192-1199), so
    # an installed binary names a directory that is gone, and Nix rejects an
    # installed file that names its build directory at all. Both Zig caches above
    # are under $TMPDIR, so dropping those entries and no other removes it: the
    # $ORIGIN/../lib the build adds, and every store path a real dependency
    # needs, stay. This is where the shared variant needs it: the example
    # executable links the shared object this build has just made, so its rpath
    # names the build cache. Symlinks are resolved first so a soname link is
    # rewritten through to the object and never replaced by a copy of it.
    ${lib.optionalString isElfTarget ''
      for elf in "$out"/bin/* "$out"/lib/*.so*; do
        [ -f "$elf" ] || continue
        elf=$(readlink -f "$elf")
        rpath=$(patchelf --print-rpath "$elf") || rpath=""
        kept=""
        rest=$rpath
        while [ -n "$rest" ]; do
          entry="''${rest%%:*}"
          case "$entry" in
            "$TMPDIR"/*) ;;
            *) if [ -z "$kept" ]; then kept=$entry; else kept=$kept:$entry; fi ;;
          esac
          if [ "$entry" = "$rest" ]; then rest=""; else rest="''${rest#*:}"; fi
        done
        [ "$kept" = "$rpath" ] || patchelf --set-rpath "$kept" "$elf"
      done
    ''}

    runHook postInstall
  '';

  # The layout this derivation produces is the build graph's, not this file's:
  #   $out/lib/libmimalloc.a                          (linkage = "static")
  #   $out/lib/libmimalloc.so.3.5.3, .so.3, .so       (linkage = "dynamic")
  #   $out/include/{mimalloc,mimalloc-override,mimalloc-new-delete,mimalloc-stats}.h
  #   $out/lib/pkgconfig/mimalloc.pc
  #   $out/share/licenses/mimalloc/{LICENSE,NOTICE.md,FORK-LICENSE.md}
  #   $out/bin/mimalloc-smoke
  # The soname series is upstream's own, `VERSION 3.5.3` with
  # `SOVERSION 3` (`CMakeLists.txt:997`), and the four installed headers are
  # upstream's four (`CMakeLists.txt:1082-1085`): the internal headers under
  # `include/mimalloc/` travel in the source but are not part of the installed
  # surface. Both variants keep the layout; only the artifact kind differs.
  # Nothing is copied or generated by hand here, so
  # `zig build install --prefix $out` and `nix build` produce one layout by
  # construction rather than two that have to be kept in agreement.

  enableParallelBuilding = true;

  passthru = {
    inherit linkage optimize;
  };

  meta = {
    description = "mimalloc, a general purpose allocator with excellent performance, built from the official release sources";
    longDescription = ''
      The complete mimalloc v3.5.3 source closure -- the public headers, the
      internal headers the sources include, and the 21 translation units of
      upstream's own `mi_sources` list -- compiled from this repository's `src/`
      with Zig, with no CMake, no autotools and no build-time download. Ships
      the library, the four headers upstream installs, a pkg-config file and the
      licence records.

      This is the bundled library, not an allocator override: `MI_MALLOC_OVERRIDE`
      is not defined here, so nothing in this output defines `malloc`, `free` or
      the C++ allocation operators. Linking this package into a program replaces
      no allocator on its own.
    '';
    homepage = "https://github.com/microsoft/mimalloc/";
    # MIT, and the fork-authored additions are MIT on the owner's authorization
    # (FORK-LICENSE.md). NOTICE.md is the per-file inventory: every compiled
    # source carries its own MIT banner with a differing year range,
    # src/prim/emscripten/prim.c names a third holder, and
    # src/prim/windows/etw.h carries only an "All Rights Reserved" notice.
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    # No `mainProgram`: build.zig installs the library, its installed headers,
    # its pkg-config file, its licence records and the `mimalloc-smoke` example,
    # and the example is not the package's program.
  };
}
