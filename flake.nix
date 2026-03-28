{
  description = "LASP — Language-Agnostic Structural Parser";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "lasp";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.zig ];

          dontConfigure = true;
          dontInstall = true;

          buildPhase = ''
            mkdir -p .cache
            zig build --cache-dir $(pwd)/.cache --global-cache-dir $(pwd)/.cache -Doptimize=Debug --prefix $out
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.zig ];
        };
      }
    );
}
