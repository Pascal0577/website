{
    inputs.nixpkgs.url = "nixpkgs";

    outputs = { self, nixpkgs, ... }:
    let
        forAllSystems = f: builtins.mapAttrs f nixpkgs.legacyPackages;
    in {
        devShells = forAllSystems (system: pkgs: {
            default = pkgs.mkShellNoCC {
                buildInputs = with pkgs; [
                    zig_0_16
                    zls_0_16
                    zig-shell-completions
                    vscode-langservers-extracted
                ];
            };
        });

        packages = forAllSystems (system: pkgs: {
            default = pkgs.stdenv.mkDerivation {
                name = "pscl-webserver";
                version = "1.0.0";
                src = ./.;

                nativeBuildInputs = [ pkgs.zig_0_16 ];

                buildPhase = ''
                    rm -rf $out
                    local cache=$(mktemp -d)
                    ${pkgs.zig_0_16}/bin/zig build --release=safe --prefix $out --global-cache-dir "$cache"
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
                interface = lib.mkOption {
                    type = lib.types.str;
                    default = "eth0";
                    description = "External network interface for NAT";
                };
            };

            config = lib.mkIf config.pscl-webserver.enable {
                environment.systemPackages = [ pkg ];
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

                containers.pscl-webserver = {
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

                        users.users.pscl-webserver = {
                            isSystemUser = true;
                            group = "webserver";
                            home = "/var/lib/webserver";
                            createHome = true;
                        };
                        users.groups.webserver = {};

                        systemd.services.pscl-webserver = {
                            enable = true;
                            after = [ "network.target" "network-online.target" "content-sync.service" ];
                            wants = [  "network-online.target" "content-sync.service" ];
                            wantedBy = [ "multi-user.target" ];
                            serviceConfig = {
                                Type = "simple";
                                ExecStart = lib.getExe pkg;
                                User = "pscl-webserver";
                                StateDirectory = "pscl-webserver";
                                WorkingDirectory = "/var/lib/pscl-webserver/website";
                            };
                        };

                        systemd.services.content-sync = {
                            after = [ "network-online.target" "systemd-resolved.service" ];
                            wants = [ "network-online.target" ];
                            requires = [ "systemd-resolved.service" "network-online.target" ];
                            wantedBy = [ "multi-user.target" ];
                            script = ''
                                if [ -d /var/lib/pscl-webserver/website/.git ]; then
                                  ${pkgs.git}/bin/git -C /var/lib/webserver/website pull
                                else
                                  ${pkgs.git}/bin/git clone https://github.com/Pascal0577/website /var/lib/webserver/website
                                fi
                            '';
                            serviceConfig = {
                                Type = "oneshot";
                                User = "pscl-webserver";
                                StateDirectory = "pscl-webserver";
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
