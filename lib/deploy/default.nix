{ lib, ... }: {
  # mkDeploy - Creates deploy-rs configuration from nixosConfigurations
  #
  # Usage in consuming flake:
  #   deploy = inputs.jinx-modules.lib.mkDeploy {
  #     inherit self;
  #     inherit (inputs) deploy-rs nixpkgs;
  #   };
  #
  mkDeploy = {
    self,
    deploy-rs,
    nixpkgs,
    overrides ? {},
  }: let
    hosts = self.nixosConfigurations or {};
    names = builtins.attrNames hosts;
    nodes =
      lib.foldl
      (result: name: let
        host = hosts.${name};
        user = host.config.deploy.user or null;
        sshUser = host.config.deploy.sshUser or null;
        remoteBuild = host.config.deploy.remoteBuild or null;

        # Check for pre-built deploy-rs in pkgs (from overlay)
        customDeployRs =
          if host.pkgs ? deploy-rs && lib.isDerivation host.pkgs.deploy-rs
          then host.pkgs.deploy-rs
          else null;
        deployPkgs = import nixpkgs {
          localSystem = host.pkgs.stdenv.hostPlatform.system;
          overlays = [
            deploy-rs.overlays.default
          ] ++ lib.optional (customDeployRs != null) (final: prev: {
            deploy-rs = prev.deploy-rs // { deploy-rs = customDeployRs; };
          });
        };
      in
        result
        // {
          ${name} =
            (overrides.${name} or {})
            // {
              hostname = if ( host.config.deploy.address != null )
                then host.config.deploy.address
                else overrides.${name}.hostname or "${name}";
              profilesOrder = [ "system" ] ++ lib.optional (user != null) "home";
              profiles =
                (overrides.${name}.profiles or {})
                // {
                  system =
                    (overrides.${name}.profiles.system or {})
                    // {
                      path = deployPkgs.deploy-rs.lib.activate.nixos host;
                    }
                    // ( if (sshUser == null)
                        then { sshUser = "nixos"; }
                        else { sshUser = sshUser; }
                    )
                    // { user = "root"; }
                    // lib.optionalAttrs (remoteBuild != null) {
                      remoteBuild = remoteBuild;
                    };
                }
                // ( if ( user != null )
                  then {
                    home =
                      (overrides.${name}.profiles.home or {})
                      // {
                        path =
                        if (self.homeConfigurations ? "${user}@${name}")
                          then deployPkgs.deploy-rs.lib.activate.home-manager self.homeConfigurations."${user}@${name}"
                          else deployPkgs.deploy-rs.lib.activate.home-manager self.homeConfigurations."${user}@default";
                      }
                      // {
                        user = user;
                        sshUser = if sshUser != null then sshUser else "nixos";
                      }
                      // lib.optionalAttrs (remoteBuild != null) {
                        remoteBuild = remoteBuild;
                      };
                  }
                  else {}
                );
                };
            })
      {}
      names;
  in {inherit nodes;};
}
