{
    inputs = {
        nixpkgs.url = "nixpkgs";
        zig.url = "github:silversquirl/zig-flake/compat";
        zls.url = "github:zigtools/zls";

        zig.inputs.nixpkgs.follows = "nixpkgs";
        zls.inputs.nixpkgs.follows = "nixpkgs";
        zls.inputs.zig-flake.follows = "zig";
    };

    outputs = { self, nixpkgs, zig, zls, ... }:
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

                meta.mainProgram = "webserver";
            };
        });

        nixosModules.webserver = { pkgs, lib, ... }:
        let
            pkg = self.packages.${pkgs.system}.default;
        in {
            networking.firewall.allowedTCPPorts = [ 80 ];
            environment.systemPackages = [ pkg ];

            users.users.webserver = {
                isSystemUser = true;
                group = "webserver";
                home = "/var/lib/webserver";
                createHome = true;
            };
            users.groups.webserver = {};

            systemd.services.webserver = {
                enable = true;
                after = [ "network.target" "network-online.target" "content-sync.service" ];
                wants = [ "content-sync.service" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                    Type = "simple";
                    ExecStart = lib.getExe pkg;
                    User = "webserver";
                    StateDirectory = "webserver";
                    WorkingDirectory = "/var/lib/webserver";
                };
            };

            systemd.services.content-sync = {
                wantedBy = [ "multi-user.target" ];
                script = ''
                    if [ -d /var/lib/webserver/website ]; then
                      ${pkgs.git}/bin/git -C /var/lib/webserver pull
                    else
                      ${pkgs.git}/bin/git clone https://github.com/Pascal0577/website /var/lib/webserver
                    fi
                '';
                serviceConfig = {
                    Type = "oneshot";
                    User = "webserver";
                    StateDirectory = "webserver";
                };
            };

            systemd.timers.content-sync = {
                wantedBy = [ "timers.target" ];
                timerConfig = {
                    OnCalendar = "*:0/5";
                    Persistent = true;
                };
            };
        };
    };
}
