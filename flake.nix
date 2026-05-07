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

        nixosModules.webserver = { pkgs, lib, config, ... }:
        let
            pkg = self.packages.${pkgs.stdenv.system}.default;
        in {
            options.pscl-webserver = {
                enable = lib.mkEnableOption "My webserver";
                interface = lib.mkDefault "eth0";
            };

            config = lib.mkIf config.mySystem.enableWebserver {
                networking.nat = {
                    enable = true;
                    internalInterfaces = [ "ve-+" ];
                    externalInterface = config.pscl-webserver.interface;
                    forwardPorts = [{
                        sourcePort = 80;
                        proto = "tcp";
                        destination = "10.0.0.2:8080";
                    }];
                };

                networking.firewall = {
                    allowedTCPPorts = [ 80 ];
                    trustedInterfaces = [ "ve-+" ];
                };

                containers.webserver = {
                    autoStart = true;
                    privateNetwork = true;
                    privateUsers = "pick";
                    hostAddress = "10.0.0.1";
                    localAddress = "10.0.0.2";
                    restartIfChanged = true;
                    config = {
                        system.stateVersion = "26.05";
                        networking.firewall.allowedTCPPorts = [ 8080 ];
                        networking.useHostResolvConf = lib.mkForce false;

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
                                WorkingDirectory = "/var/lib/webserver/website";
                            };
                        };

                        systemd.services.content-sync = {
                            after = [ "network-online.target" "systemd-resolved.service" ];
                            wants = [ "network-online.target" ];
                            requires = [ "systemd-resolved.service" "network-online.target" ];
                            wantedBy = [ "multi-user.target" ];
                            script = ''
                                if [ -d /var/lib/webserver/website/.git ]; then
                                  ${pkgs.git}/bin/git -C /var/lib/webserver/website pull
                                else
                                  ${pkgs.git}/bin/git clone https://github.com/Pascal0577/website /var/lib/webserver/website
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

                        services.resolved = {
                            enable = true;
                            settings.Resolve = lib.mkDefault {
                                DNS = "9.9.9.9#dns.quad9.net";
                                FallbackDNS = "1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google";
                                DNSSEC = true;
                                DNSOverTLS = true;
                            };
                        };
                    };
                };
            };
        };
    };
}
