# Flake interface for the mimalloc SDK.
#
# Portable counterpart to devenv.nix. Both call ./package.nix, so the package a
# flake builds and the package devenv builds are the same derivation; this file
# only decides which systems are exposed and which variants of that derivation
# they get.
#
# Canonical development is `devenv shell` (see devenv.nix and .envrc). This
# flake exists so the SDK can be built and consumed off this host. `nix develop`
# here is parity, not the canonical entry point, and it deliberately does not
# build the SDK: entering a shell must not require building a library.
#
# flake.lock is not written here: the driver owns locks. What is written is
# flake.lock itself, beside this file, and its single nixpkgs node is copied
# byte for byte from ../lua/flake.lock -- the same recorded resolution, down to
# the revision, the lastModified field and the narHash, and the same revision
# this file's `inputs.nixpkgs.url` pins. It is copied rather than regenerated
# because regenerating it is the driver's job and a lock this fork invented
# would be a lock nobody resolved. The copy is recorded here because a lock file
# is JSON and cannot carry the note itself.
#
# The lock is not in `build.zig.zon`'s `.paths`: a Nix derivation takes its
# inputs as arguments and the flake frontend resolves the locked inputs before
# the build source filter runs, so a fetched copy that arrives without the lock
# resolves the revision pinned above instead of failing.
#
# SPDX-License-Identifier: MIT
# See FORK-LICENSE.md for what that identifier covers, and NOTICE.md for the
# per-file notices the import carries.

{
  description = "mimalloc 3.5.3, the Microsoft general purpose allocator, packaged for Zig 0.16";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";
  };

  outputs = { self, nixpkgs }:
    let
      # Unix systems only, which is the same boundary package.nix asserts: it
      # builds for the compiler's native target rather than hand-building a
      # cross triple. A system is added here when a build on it has been
      # observed, not because upstream's own platform list or `stdenv.mkDerivation`
      # would accept it. Documented in README.md, not worked around here.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
        "x86_64-freebsd"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          mk = linkage: pkgs.callPackage ./package.nix {
            inherit linkage;
            zig = pkgs.zig_0_16;
          };

          # One derivation, two names. Both are the same sources and the same
          # build graph; only `linkage` differs.
          mimalloc-static = mk "static";
          mimalloc-shared = mk "dynamic";
        in
        {
          inherit mimalloc-static mimalloc-shared;

          # The name a consumer reaches for: both variants and the default, so
          # one dependency name can select either linkage instead of asking the
          # consumer to know which derivation holds which.
          mimalloc = {
            static = mimalloc-static;
            shared = mimalloc-shared;
            default = mimalloc-static;
          };

          default = mimalloc-static;
        });

      # Parity only. The canonical development environment is devenv.nix. The
      # shell carries the tools a task needs and nothing else: the Zig 0.16.0
      # compiler, and the coreutils, grep, find, awk and diff that
      # tools/check-provenance.sh answers its three questions with. Building the
      # library is not in this list, because entering a shell must not require
      # building one.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_16
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.findutils
            pkgs.gawk
            pkgs.diffutils
          ];
        };
      });
    };
}
