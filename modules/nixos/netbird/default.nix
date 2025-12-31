# Extends the nixpkgs netbird module with SSH options
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    filterAttrs
    mapAttrs'
    mkEnableOption
    mkIf
    mkMerge
    nameValuePair
    optionalString
    pipe
    ;

  cfg = config.services.netbird;
in
{
  # Extend the client submodule with SSH settings (uses types.submodule's merge behavior)
  options.services.netbird.clients = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
      options.login.ssh = {
        allowServerSsh = mkEnableOption "SSH server on the netbird interface (--allow-server-ssh)";

        enableLocalPortForwarding = mkEnableOption "SSH local port forwarding (--enable-ssh-local-port-forwarding)";

        enableRemotePortForwarding = mkEnableOption "SSH remote port forwarding (--enable-ssh-remote-port-forwarding)";

        enableRoot = mkEnableOption "root access via SSH (--enable-ssh-root)";

        enableSftp = mkEnableOption "SFTP subsystem (--enable-ssh-sftp)";

        disableAuth = mkEnableOption "disabling SSH authentication (--disable-ssh-auth)";
      };
    }));
  };

  config = mkMerge [
    # Override the login service to include SSH flags
    {
      systemd.services = pipe cfg.clients [
        (filterAttrs (_: client: client.login.enable))
        (mapAttrs' (
          _: client:
          let
            sshFlags = lib.concatStrings [
              (optionalString client.login.ssh.allowServerSsh " --allow-server-ssh")
              (optionalString client.login.ssh.enableLocalPortForwarding " --enable-ssh-local-port-forwarding")
              (optionalString client.login.ssh.enableRemotePortForwarding " --enable-ssh-remote-port-forwarding")
              (optionalString client.login.ssh.enableRoot " --enable-ssh-root")
              (optionalString client.login.ssh.enableSftp " --enable-ssh-sftp")
              (optionalString client.login.ssh.disableAuth " --disable-ssh-auth")
            ];
          in
          nameValuePair "${client.service.name}-login" (mkIf (sshFlags != "") {
            script = lib.mkForce ''
              set -x
              status_file="/tmp/status.txt"

              refresh_status() {
                '${lib.getExe client.wrapper}' status &>"$status_file" || :
              }

              print_short_setup_key() {
                cut -b1-8 <"$NB_SETUP_KEY_FILE"
              }

              main() {
                refresh_status
                <"$status_file" sed 's/^/STATUS:PRE-CONNECT : /g'

                until refresh_status && <"$status_file" grep --quiet 'Connected\|NeedsLogin' ; do
                  sleep 1
                done
                <"$status_file" sed 's/^/STATUS:POST-CONNECT: /g'

                if <"$status_file" grep --quiet 'NeedsLogin' ; then
                  echo "Using Setup Key File with key: $(print_short_setup_key)" >&2
                  '${lib.getExe client.wrapper}' up --setup-key-file="$NB_SETUP_KEY_FILE"${sshFlags}
                fi
              }

              main "$@"
            '';
          })
        ))
      ];
    }
    # When hardened=false, override login service to run as root
    {
      systemd.services = pipe cfg.clients [
        (filterAttrs (_: client: client.login.enable && !client.hardened))
        (mapAttrs' (
          _: client:
          nameValuePair "${client.service.name}-login" {
            serviceConfig = {
              User = lib.mkForce "root";
              Group = lib.mkForce "root";
            };
          }
        ))
      ];
    }
  ];
}
