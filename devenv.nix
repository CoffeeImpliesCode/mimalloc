# Canonical devenv environment for the mimalloc SDK.
# SPDX-License-Identifier: MIT
# See FORK-LICENSE.md for what that identifier covers.

{ pkgs, ... }:

let

  zig = pkgs.zig_0_17;
  mimalloc = linkage: pkgs.callPackage ./package.nix { inherit linkage; inherit zig; };

  # Resolve the SDK root from this file, not the caller's working directory.
  sdk_root = builtins.toString ./.;

  # Keep Zig caches outside the checkout unless the caller supplied paths.
  zig_caches = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        export ZIG_LOCAL_CACHE_DIR="$XDG_CACHE_HOME/mimalloc/zig-local-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        export ZIG_LOCAL_CACHE_DIR="$TMPDIR/mimalloc/zig-local-cache"
      fi
    fi
    if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        export ZIG_GLOBAL_CACHE_DIR="$XDG_CACHE_HOME/mimalloc/zig-global-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/mimalloc/zig-global-cache"
      fi
    fi
    if [ -n "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      mkdir -p "$ZIG_LOCAL_CACHE_DIR"
    fi
    if [ -n "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    fi
  '';

  # Tasks fail rather than write build output into the checkout.
  require_external_output = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      echo "mimalloc devenv: ZIG_LOCAL_CACHE_DIR, XDG_CACHE_HOME and TMPDIR are all unset," >&2
      echo "so there is nowhere outside this checkout to put build output." >&2
      echo "Export one of them at approved scratch, then run the task again." >&2
      exit 1
    fi
  '';

  # Run each task from the SDK root.
  in_sdk = ''
    ${zig_caches}
    ${require_external_output}
    cd "${sdk_root}" || exit 1
  '';

  native_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/native" "''$@"
  '';

  # Keep the nested consumer cache separate.
  consumer_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/consumer" "''$@"
  '';
in
{
  packages = [
    zig
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.findutils
    pkgs.gawk
    pkgs.diffutils
    pkgs.pkg-config
    pkgs.gnumake
  ];

  assertions = [
    {
      assertion = zig.version == "0.17.0";
      message = "The mimalloc SDK requires Zig 0.17.0; nixpkgs resolved zig_0_17 to ${zig.version}";
    }
  ];

  enterShell = ''
    ${zig_caches}
  '';

  # Package outputs stay lazy until requested.
  outputs.static = mimalloc "static";
  outputs.shared = mimalloc "dynamic";
  outputs.default = mimalloc "static";

  tasks = {
    # Install outside the checkout.
    "sdk:build" = {
      description = ''
        Compile the native library and install the delivery tree (default step)
        under the external cache rather than in this checkout.
      '';
      exec = ''
        ${in_sdk}
        zig build --prefix "$ZIG_LOCAL_CACHE_DIR/prefix/static" ${native_flags}
      '';
    };

    "sdk:build:shared" = {
      description = ''
        Deliver the native library as a real shared object with upstream's own
        soname scheme, libmimalloc.so.3.5.3 with soname libmimalloc.so.3, and
        install it under its own external prefix.
      '';
      exec = ''
        ${in_sdk}
        zig build -Dlinkage=dynamic --prefix "$ZIG_LOCAL_CACHE_DIR/prefix/dynamic" ${native_flags}
      '';
    };

    "sdk:test" = {
      description = "Run the behavioural tests (Debug)";
      exec = ''
        ${in_sdk}
        zig build test ${native_flags}
      '';
    };

    "sdk:test:release-safe" = {
      description = "Run the behavioural tests in ReleaseSafe";
      exec = ''
        ${in_sdk}
        zig build test -Doptimize=ReleaseSafe ${native_flags}
      '';
    };

    "sdk:smoke" = {
      description = "Run the deterministic example program";
      exec = ''
        ${in_sdk}
        zig build smoke ${native_flags}
      '';
    };

    "sdk:check" = {
      description = "Compile and link the library, the facade, the tests and the example for each of the six baseline check targets, without running any of them";
      exec = ''
        ${in_sdk}
        zig build check ${native_flags}
      '';
    };

    "sdk:check:shared" = {
      description = "The same six-target compile check against the shared object";
      exec = ''
        ${in_sdk}
        zig build check -Dlinkage=dynamic ${native_flags}
      '';
    };

    # Exercise the SDK from the separate consumer package.
    "sdk:consumer" = {
      description = "Build and run the separate consumer package against this SDK";
      exec = ''
        ${in_sdk}
        cd consumer
        zig build run ${consumer_flags}
      '';
    };

    # Run the provenance check from the checkout.
    "sdk:provenance" = {
      description = ''
        Check the recorded upstream digests, the exact upstream file set, the
        release digest in both records, the preserved upstream README and the
        per-file licence notices. This is a source-integrity check, not a build
        gate, and it needs no compiler.
      '';
      exec = ''
        ${in_sdk}
        bash tools/check-provenance.sh
      '';
    };

    # Package tasks run from the caller's devenv project.
    "sdk:package:static" = {
      description = ''
        Build the static Nix variant through devenv's own lazy output. No lock
        is needed by this path; `devenv build outputs.static` resolves the
        pinned input from devenv.lock, which the driver owns.
      '';
      exec = "devenv build outputs.static";
    };

    "sdk:package:shared" = {
      description = "Build the shared Nix variant through devenv's own lazy output";
      exec = "devenv build outputs.shared";
    };
  };
}
