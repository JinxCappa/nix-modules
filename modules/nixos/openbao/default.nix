# Extends the nixpkgs openbao module with flexible config options
#
# Adds:
# - configFile: Inline HCL content (string) written to a file
# - configFilePath: Path to an existing config file
#
# Fixes:
# - settings is now truly optional - won't cause errors when using extraArgs alone
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.openbao;

  settingsFormat = pkgs.formats.json { };

  # Determine which config source to use (priority order)
  hasConfigFile = cfg.configFile != null;
  hasConfigFilePath = cfg.configFilePath != null;

  # Generate the config file path based on configuration source
  # Priority: configFilePath > configFile > settings (fallback)
  effectiveConfigPath =
    if hasConfigFilePath then
      cfg.configFilePath
    else if hasConfigFile then
      pkgs.writeText "openbao.hcl" cfg.configFile
    else
      # Fall back to upstream settings (serialized to JSON)
      settingsFormat.generate "openbao.json" cfg.settings;

  # Override ExecStart when using our config options
  needsExecStartOverride = hasConfigFile || hasConfigFilePath;
in
{
  options.services.openbao = {
    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = ''
        OpenBao configuration as raw HCL content.

        The content is written to a file that OpenBao reads on startup.
        Use this when you want to define HCL configuration inline.

        For JSON configuration, use the upstream `settings` option instead.

        Mutually exclusive with `configFilePath` and `settings`.

        See [OpenBao documentation](https://openbao.org/docs/configuration)
        for configuration options.
      '';
      example = lib.literalExpression ''
        '''
          ui = true

          listener "tcp" {
            address     = "127.0.0.1:8200"
            tls_disable = true
          }

          storage "raft" {
            path = "/var/lib/openbao"
          }

          api_addr     = "http://127.0.0.1:8200"
          cluster_addr = "http://127.0.0.1:8201"
        '''
      '';
    };

    configFilePath = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to an existing OpenBao configuration file.

        Use this when you have a config file managed externally, such as
        via sops-nix, agenix, or a manually managed file.

        Mutually exclusive with `configFile` and `settings`.
      '';
      example = "/run/secrets/openbao/config.hcl";
    };
  };

  config = lib.mkIf cfg.enable {
    # Provide defaults for settings and nested options so they can be left unset
    services.openbao.settings = {
      listener = lib.mkOptionDefault { };
    };

    assertions = [
      {
        assertion = !(hasConfigFile && hasConfigFilePath);
        message = ''
          services.openbao: configFile and configFilePath are mutually exclusive.
          Choose one or use settings instead.
        '';
      }
    ];

    # Override the systemd service when using custom config options
    systemd.services.openbao = lib.mkIf needsExecStartOverride {
      serviceConfig.ExecStart = lib.mkForce (
        lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "server"
          ]
          ++ lib.optionals (effectiveConfigPath != null) [
            "-config"
            effectiveConfigPath
          ]
          ++ cfg.extraArgs
        )
      );
    };
  };
}
