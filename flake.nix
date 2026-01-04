{
  description = "Jinx shared NixOS modules and lib helpers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      # Import custom lib helpers
      moduleLib = import ./lib/module { inherit lib; };
      deployLib = import ./lib/deploy { inherit lib; };
      flakeLib = import ./lib/flake { inherit lib; };
    in {
      # Lib functions - use via inputs.jinx-modules.lib.*
      # Example: inputs.jinx-modules.lib.mkOpt
      # Example: inputs.jinx-modules.lib.mkDeploy { self, deploy-rs, nixpkgs }
      # Example: inputs.jinx-modules.lib.mkFlake { inputs, src, ... }
      lib = moduleLib // deployLib // flakeLib;

      # NixOS modules - use via inputs.jinx-modules.nixosModules.*
      nixosModules = {
        # Deploy-rs target configuration options
        deploy = ./modules/nixos/deploy;

        # Netbird mesh networking - extends nixpkgs netbird with SSH options
        netbird = ./modules/nixos/netbird;

        # VictoriaMetrics cluster components (vmauth, vmstorage, vmselect, vminsert)
        victoriametrics = ./modules/nixos/victoriametrics;

        # Service watcher - monitors and restarts failed services
        watcher = ./modules/nixos/watcher;

        # Zabbix Agent 2 with TLS/PSK support
        zabbixAgent2 = ./modules/nixos/zabbixAgent2;

        # Import all modules at once
        default = { ... }: {
          imports = [
            self.nixosModules.deploy
            self.nixosModules.netbird
            self.nixosModules.victoriametrics
            self.nixosModules.watcher
            self.nixosModules.zabbixAgent2
          ];
        };
      };
    };
}
