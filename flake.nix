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
      # Systems supported by package.nix's native-target derivation.
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

          mimalloc-static = mk "static";
          mimalloc-shared = mk "dynamic";
        in
        {
          inherit mimalloc-static mimalloc-shared;

          mimalloc = {
            static = mimalloc-static;
            shared = mimalloc-shared;
            default = mimalloc-static;
          };

          default = mimalloc-static;
        });

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
