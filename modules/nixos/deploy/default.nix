# Deploy-rs target configuration options
# Used by mkDeploy to generate deploy-rs node configurations
{ config, lib, ... }:

with lib;

{
  options.deploy = {
    hostname = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The hostname of the target machine.";
    };

    address = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The address of the target machine.";
    };

    sshUser = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The SSH user to connect as.";
    };

    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The user to activate the system for.";
    };

    remoteBuild = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to build remotely on the target machine.";
    };
  };
}
