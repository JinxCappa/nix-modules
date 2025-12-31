{ lib, ... }:

with lib;
{
  ## Create a NixOS module option.
  ##
  ## ```nix
  ## lib.mkOpt types.str "My default" "Description of my option."
  ## ```
  ##
  #@ Type -> Any -> String
  mkOpt =
    type: default: description:
    mkOption { inherit type default description; };

  ## Create a NixOS module option without a description.
  ##
  ## ```nix
  ## lib.mkOpt' types.str "My default"
  ## ```
  ##
  #@ Type -> Any -> String
  mkOpt' = type: default: mkOption { inherit type default; };

  ## Create a boolean NixOS module option.
  ##
  ## ```nix
  ## lib.mkBoolOpt true "Description of my option."
  ## ```
  ##
  #@ Bool -> String -> Option
  mkBoolOpt = mkOpt types.bool;

  ## Create a boolean NixOS module option without a description.
  ##
  ## ```nix
  ## lib.mkBoolOpt' true
  ## ```
  ##
  #@ Bool -> Option
  mkBoolOpt' = default: mkOption { type = types.bool; inherit default; };

  ## Quickly enable an option.
  ##
  ## ```nix
  ## services.nginx = lib.enabled;
  ## ```
  ##
  #@ { enable = true; }
  enabled = { enable = true; };

  ## Quickly disable an option.
  ##
  ## ```nix
  ## services.nginx = lib.disabled;
  ## ```
  ##
  #@ { enable = false; }
  disabled = { enable = false; };
}
