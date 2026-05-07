{
    inputs = {
        nixpkgs.url = "nixpkgs";
        zig.url = "github:silversquirl/zig-flake/compat";
        zls.url = "github:zigtools/zls";

        zig.inputs.nixpkgs.follows = "nixpkgs";
        zls.inputs.nixpkgs.follows = "nixpkgs";
        zls.inputs.zig-flake.follows = "zig";
    };

    outputs = { nixpkgs, zig, zls, ... }:
    let
        forAllSystems = f: builtins.mapAttrs f nixpkgs.legacyPackages;
    in {
        devShells = forAllSystems (system: pkgs: {
            default = pkgs.mkShellNoCC {
                buildInputs = [
                    zig.packages.${system}.nightly
                    zls.packages.${system}.zls
                    pkgs.zig-shell-completions
                    pkgs.vscode-langservers-extracted
                ];
            };
        });

        packages = forAllSystems (system: pkgs: {
            default = pkgs.stdenv.mkDerivation {
                name = "my-webserver";
                version = "1.0.0";
                src = ./.;

                nativeBuildInputs = [ zig.packages.${system}.nightly ];

                buildPhase = ''
                    rm -rf $out
                    local cache=$(mktemp -d)
                    zig build --release=safe --prefix $out --global-cache-dir "$cache"
                '';

                installPhase = "true";

                dontUseZigCheck = true;
            };
        });
    };
}
