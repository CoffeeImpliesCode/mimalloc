# Nix package derivation for the mimalloc SDK.
# SPDX-License-Identifier: MIT
# See FORK-LICENSE.md for scope and NOTICE.md for per-file terms.

{ lib
, stdenv
, zig
, patchelf
  # Linkage variant passed to build.zig.
, linkage ? "static"
, optimize ? "ReleaseSafe"
}:

let
  requestedLinkage =
    if builtins.elem linkage [ "" "static" "dynamic" ] then linkage
    else throw "package.nix: linkage must be \"\", \"static\" or \"dynamic\", not ${toString linkage}";

# Exclude build and developer state; retain imported upstream sources.
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

# patchelf rewrites ELF rpaths.
isElfTarget = !stdenv.hostPlatform.isDarwin;
in

# Refuse cross builds; package the compiler's native target only.
assert stdenv.buildPlatform.system == stdenv.hostPlatform.system;

stdenv.mkDerivation {
  pname = "mimalloc";
  version = "3.5.3";

  inherit src;

  strictDeps = true;
  dontPatch = true;

  # The install phase runs the single Zig build.
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ zig ] ++ lib.optional isElfTarget patchelf;

  # Propagate the C runtime needed by library consumers.
  propagatedBuildInputs = [ stdenv.cc.libc ];

  doCheck = false;
  dontUseZigCheck = true;

  installPhase = ''
    runHook preInstall

    # Keep Zig caches under TMPDIR, outside the source tree.
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"

    # build.zig owns the compile and install configuration.
    # Use the architecture baseline for portable store outputs.
    # Build the bundled sources.
    zig build install \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=${optimize} \
      -Dcpu=baseline \
      -Dsystem=false \
      ${lib.optionalString (requestedLinkage != "") "-Dlinkage=${requestedLinkage}"}

    # Remove temporary cache paths from ELF rpaths.
    # Resolve symlinks before patching the shared object.
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
    # NOTICE.md records per-file licensing terms.
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
