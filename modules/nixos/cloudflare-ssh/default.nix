{ config, pkgs, lib, ... }:

let
  cfg = config.services.cloudflare-ssh;

  cloudflaredCfgPath = "/etc/cloudflared/config.yml";
  cloudflaredCredPath = "/var/lib/cloudflared/${cfg.tunnelId}.json";
  cloudflareCaPubPath = "/etc/ssh/cloudflare_access_ca.pub";
in
{
  options.services.cloudflare-ssh = {
    enable = lib.mkEnableOption "Cloudflare Tunnel for SSH";

    tunnelId = lib.mkOption {
      type = lib.types.str;
      description = "Cloudflare Tunnel UUID";
      example = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      description = "Public hostname for SSH access";
      example = "ssh.example.com";
    };

    sopsFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to sops secrets file containing tunnel credentials and SSH CA key";
      example = ./secrets.yaml;
    };

    sshLockdown = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "When enabled, disables authorized_keys and only allows Cloudflare CA authentication";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.cloudflared ];

    users.groups.cloudflared = {};
    users.users.cloudflared = {
      isSystemUser = true;
      group = "cloudflared";
      home = "/var/lib/cloudflared";
    };

    sops.secrets."cloudflared/tunnel_credentials_json" = {
      sopsFile = cfg.sopsFile;
      format = "yaml";
      path = cloudflaredCredPath;
      owner = "cloudflared";
      group = "cloudflared";
      mode = "0400";
    };

    sops.secrets."cloudflare_access/ssh_ca_pub" = {
      sopsFile = cfg.sopsFile;
      format = "yaml";
      path = cloudflareCaPubPath;
      owner = "root";
      group = "root";
      mode = "0444";
    };

    services.openssh = {
      enable = true;
      listenAddresses = lib.mkIf cfg.sshLockdown (lib.mkForce [
        { addr = "127.0.0.1"; port = 22; }
        { addr = "::1"; port = 22; }
      ]);
      settings = {
        PubkeyAuthentication = lib.mkForce true;
        TrustedUserCAKeys = lib.mkForce cloudflareCaPubPath;
        PasswordAuthentication = lib.mkForce false;
        KbdInteractiveAuthentication = lib.mkForce false;
        PermitRootLogin = lib.mkForce "no";
      } // lib.optionalAttrs cfg.sshLockdown {
        AuthorizedKeysFile = lib.mkForce "none";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.sshLockdown (lib.mkForce []);

    environment.etc."cloudflared/config.yml".text = ''
      tunnel: ${cfg.tunnelId}
      credentials-file: ${cloudflaredCredPath}
      no-autoupdate: true

      ingress:
        - hostname: ${cfg.hostname}
          service: ssh://localhost:22
        - service: http_status:404
    '';

    systemd.services.cloudflared-ssh = {
      description = "Cloudflare Tunnel (SSH)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        User = "cloudflared";
        Group = "cloudflared";
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --config ${cloudflaredCfgPath} run";
        Restart = "on-failure";
        RestartSec = "5s";
        StateDirectory = "cloudflared";
        WorkingDirectory = "/var/lib/cloudflared";
      };
    };
  };
}
