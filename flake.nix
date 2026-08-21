{
  description = "LASP — Language-Agnostic Structural Parser";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachSystem
      [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ]
      (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # Single source of truth for the version: build.zig.zon (semver).
          # build.zig.zon is ZON, not TOML, so extract the version with a line match.
          version =
            let
              zonLines = builtins.filter builtins.isString (
                builtins.split "\n" (builtins.readFile ./build.zig.zon)
              );
              versionMatches = builtins.filter (m: m != null) (
                map (line: builtins.match "[[:space:]]*[.]version = \"([^\"]+)\".*" line) zonLines
              );
            in
            builtins.head (builtins.head versionMatches);
        in
        {
          packages = {
            default = pkgs.stdenv.mkDerivation {
              pname = "lasp";
              inherit version;
              src = ./.;

              nativeBuildInputs = [ pkgs.zig ];

              dontConfigure = true;

              buildPhase = ''
                runHook preBuild
                zig build -Doptimize=ReleaseSafe \
                  --cache-dir $(pwd)/.zig-cache \
                  --global-cache-dir $(pwd)/.zig-global-cache \
                  --prefix $out
                runHook postBuild
              '';

              # zig build --prefix already populated $out.
              installPhase = ''
                runHook preInstall
                runHook postInstall
              '';
            };

            lasp = self.packages.${system}.default;
          };

          apps.default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/lasp";
          };

          devShells.default = pkgs.mkShell {
            buildInputs = [ pkgs.zig ];
          };

          formatter = pkgs.nixfmt-tree;
        }
      );
}
