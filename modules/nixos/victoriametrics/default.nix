{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.victoriametrics;

  # Build a CLI flag from an option if the list is non-empty
  mkArrayFlag = name: values:
    optionalString (values != []) "-${name}=${concatStringsSep "," values}";

  mkStringFlag = name: value:
    optionalString (value != null) "-${name}=${value}";

  # Build address for health check ping, using first listen address or default port
  mkPingAddr = addrList: defaultPort:
    if addrList == [] then
      "127.0.0.1:${toString defaultPort}"
    else
      let addr = head addrList;
      in (optionalString (hasPrefix ":" addr) "127.0.0.1") + addr;
in
{
  # Extensions to services.victoriametrics for components without upstream NixOS options
  # Add future components (vmagent, vmalert, etc.) here

  options.services.victoriametrics.vmauth = {
    enable = mkEnableOption "VictoriaMetrics vmauth authentication proxy";

    listenAddress = mkOption {
      type = types.coercedTo types.str (x: [ x ]) (types.listOf types.str);
      default = [];
      description = "Addresses to listen for incoming http requests.";
      example = ":8427";
    };

    configFile = mkOption {
      type = types.path;
      description = "Path to the vmauth configuration file.";
      example = "/etc/vmauth/config.yml";
    };

    extraOptions = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra command-line options to pass to vmauth.";
      example = [ "-loggerLevel=INFO" ];
    };
  };

  options.services.victoriametrics.vmstorage = {
    enable = mkEnableOption "VictoriaMetrics vmstorage cluster component";

    listenAddress = mkOption {
      type = types.coercedTo types.str (x: [ x ]) (types.listOf types.str);
      default = [];
      description = "Addresses to listen for incoming http requests.";
      example = ":8482";
    };

    storageDataPath = mkOption {
      type = types.str;
      default = "/var/lib/vmstorage-data";
      description = "Path to storage data.";
    };

    retentionPeriod = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Data with timestamps outside the retentionPeriod is automatically deleted.";
      example = "12";
    };

    extraOptions = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra command-line options to pass to vmstorage.";
    };
  };

  options.services.victoriametrics.vmselect = {
    enable = mkEnableOption "VictoriaMetrics vmselect cluster component";

    listenAddress = mkOption {
      type = types.coercedTo types.str (x: [ x ]) (types.listOf types.str);
      default = [];
      description = "Addresses to listen for incoming http requests.";
      example = ":8481";
    };

    storageNode = mkOption {
      type = types.coercedTo types.str (x: [ x ]) (types.listOf types.str);
      default = [];
      description = "Addresses of vmstorage nodes.";
      example = [ "vmstorage-1:8401" "vmstorage-2:8401" ];
    };

    extraOptions = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra command-line options to pass to vmselect.";
      example = [ "-search.maxQueryLen=1MB" ];
    };
  };

  options.services.victoriametrics.vminsert = {
    enable = mkEnableOption "VictoriaMetrics vminsert cluster component";

    listenAddress = mkOption {
      type = types.coercedTo types.str (x: [ x ]) (types.listOf types.str);
      default = [];
      description = "Addresses to listen for incoming http requests.";
      example = ":8480";
    };

    storageNode = mkOption {
      type = types.coercedTo types.str (x: [ x ]) (types.listOf types.str);
      default = [];
      description = "Addresses of vmstorage nodes.";
      example = [ "vmstorage-1:8400" "vmstorage-2:8400" ];
    };

    extraOptions = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra command-line options to pass to vminsert.";
      example = [ "-maxInsertRequestSize=32MB" ];
    };
  };

  config = mkMerge [
    (mkIf cfg.vmauth.enable {
      systemd.services.vmauth = {
        description = "VictoriaMetrics vmauth";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          ExecStart = concatStringsSep " " (filter (s: s != "") [
            "${pkgs.victoriametrics}/bin/vmauth"
            "-auth.config=${cfg.vmauth.configFile}"
            (mkArrayFlag "httpListenAddr" cfg.vmauth.listenAddress)
            (escapeShellArgs cfg.vmauth.extraOptions)
          ]);
          Restart = "on-failure";
          RestartSec = "10s";

          DynamicUser = true;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
        };
      };
    })

    (mkIf cfg.vmstorage.enable {
      systemd.services.vmstorage = {
        description = "VictoriaMetrics vmstorage";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          ExecStart = concatStringsSep " " (filter (s: s != "") [
            "${pkgs.victoriametrics-cluster}/bin/vmstorage"
            (mkArrayFlag "httpListenAddr" cfg.vmstorage.listenAddress)
            (mkStringFlag "storageDataPath" cfg.vmstorage.storageDataPath)
            (mkStringFlag "retentionPeriod" cfg.vmstorage.retentionPeriod)
            (escapeShellArgs cfg.vmstorage.extraOptions)
          ]);
          Restart = "on-failure";
          RestartSec = "10s";

          DynamicUser = true;
          StateDirectory = "vmstorage-data";
          StateDirectoryMode = "0700";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
        };

        postStart = let
          pingAddr = mkPingAddr cfg.vmstorage.listenAddress 8482;
        in mkBefore ''
          until ${getBin pkgs.curl}/bin/curl -s -o /dev/null http://${pingAddr}/ping; do
            sleep 1;
          done
        '';
      };
    })

    (mkIf cfg.vmselect.enable {
      systemd.services.vmselect = {
        description = "VictoriaMetrics vmselect";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          ExecStart = concatStringsSep " " (filter (s: s != "") [
            "${pkgs.victoriametrics-cluster}/bin/vmselect"
            (mkArrayFlag "httpListenAddr" cfg.vmselect.listenAddress)
            (mkArrayFlag "storageNode" cfg.vmselect.storageNode)
            (escapeShellArgs cfg.vmselect.extraOptions)
          ]);
          Restart = "on-failure";
          RestartSec = "10s";

          DynamicUser = true;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
        };

        postStart = let
          pingAddr = mkPingAddr cfg.vmselect.listenAddress 8481;
        in mkBefore ''
          until ${getBin pkgs.curl}/bin/curl -s -o /dev/null http://${pingAddr}/ping; do
            sleep 1;
          done
        '';
      };
    })

    (mkIf cfg.vminsert.enable {
      systemd.services.vminsert = {
        description = "VictoriaMetrics vminsert";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          ExecStart = concatStringsSep " " (filter (s: s != "") [
            "${pkgs.victoriametrics-cluster}/bin/vminsert"
            (mkArrayFlag "httpListenAddr" cfg.vminsert.listenAddress)
            (mkArrayFlag "storageNode" cfg.vminsert.storageNode)
            (escapeShellArgs cfg.vminsert.extraOptions)
          ]);
          Restart = "on-failure";
          RestartSec = "10s";

          DynamicUser = true;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
        };

        postStart = let
          pingAddr = mkPingAddr cfg.vminsert.listenAddress 8480;
        in mkBefore ''
          until ${getBin pkgs.curl}/bin/curl -s -o /dev/null http://${pingAddr}/ping; do
            sleep 1;
          done
        '';
      };
    })
  ];
}
