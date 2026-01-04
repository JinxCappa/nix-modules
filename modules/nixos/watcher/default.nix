{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.watcher;

  # State directory for persistent data
  stateDir = "/var/lib/watcher";

  # Convert duration string to seconds for timeout calculations
  durationToSeconds = duration:
    let
      match = builtins.match "([0-9]+)(s|m|h)" duration;
      value = if match != null then toInt (elemAt match 0) else 30;
      unit = if match != null then elemAt match 1 else "s";
    in
    if unit == "h" then value * 3600
    else if unit == "m" then value * 60
    else value;

  # Generate YAML config from Nix options
  configYaml = pkgs.writeText "watcher-config.yaml" (builtins.toJSON {
    settings = {
      rateLimiting = {
        maxRestarts = cfg.settings.rateLimiting.maxRestarts;
        windowMinutes = cfg.settings.rateLimiting.windowMinutes;
        cooldownMinutes = cfg.settings.rateLimiting.cooldownMinutes;
      };
      metrics = {
        enable = cfg.settings.metrics.enable;
        textfile = {
          enable = cfg.settings.metrics.textfile.enable;
          path = cfg.settings.metrics.textfile.path;
        };
        victoriametrics = {
          enable = cfg.settings.metrics.victoriametrics.enable;
          endpoint = cfg.settings.metrics.victoriametrics.endpoint;
          labels = cfg.settings.metrics.victoriametrics.labels;
        };
      };
    };
    services = mapAttrs (name: svc: {
      enable = svc.enable;
      onFailed = svc.onFailed;
      onInactive = svc.onInactive;
      healthCheck = {
        enable = svc.healthCheck.enable;
        type = svc.healthCheck.type;
        target = svc.healthCheck.target;
        timeout = svc.healthCheck.timeout;
        failuresBeforeRestart = svc.healthCheck.failuresBeforeRestart;
      };
      dependencies = svc.dependencies;
      rateLimiting = {
        maxRestarts = svc.rateLimiting.maxRestarts;
        windowMinutes = svc.rateLimiting.windowMinutes;
      };
    }) cfg.services;
  });

  # The main watcher script
  watcherScript = pkgs.writeShellScript "watcher" ''
    set -euo pipefail

    CONFIG_FILE="/etc/watcher/config.yaml"
    EXTRA_CONFIG_DIR="${cfg.extraConfigDir}"
    STATE_DIR="${stateDir}"

    # Logging helpers
    log_info() {
      echo "[$(date -Iseconds)] INFO: $*"
    }

    log_warn() {
      echo "[$(date -Iseconds)] WARN: $*" >&2
    }

    log_error() {
      echo "[$(date -Iseconds)] ERROR: $*" >&2
    }

    # Load and merge configuration
    load_config() {
      local merged_config
      merged_config=$(${pkgs.yq-go}/bin/yq eval-all '. as $item ireduce ({}; . * $item)' \
        "$CONFIG_FILE" \
        $(find "$EXTRA_CONFIG_DIR" -name '*.yaml' -o -name '*.yml' 2>/dev/null | sort) \
        2>/dev/null || cat "$CONFIG_FILE")
      echo "$merged_config"
    }

    # Get service list from config
    get_services() {
      local config="$1"
      echo "$config" | ${pkgs.yq-go}/bin/yq -r '.services | keys | .[]' 2>/dev/null || true
    }

    # Get service property
    get_service_prop() {
      local config="$1"
      local service="$2"
      local prop="$3"
      local default="''${4:-}"
      local value
      value=$(echo "$config" | ${pkgs.yq-go}/bin/yq -r ".services[\"$service\"].$prop // \"$default\"" 2>/dev/null)
      echo "$value"
    }

    # Get global setting
    get_setting() {
      local config="$1"
      local prop="$2"
      local default="''${3:-}"
      echo "$config" | ${pkgs.yq-go}/bin/yq -r ".settings.$prop // \"$default\"" 2>/dev/null
    }

    # Check systemd service state
    check_systemd_state() {
      local service="$1"
      local state
      state=$(systemctl show "$service.service" --property=ActiveState --value 2>/dev/null || echo "unknown")
      echo "$state"
    }

    # Get systemd invocation ID (for dependency tracking)
    get_invocation_id() {
      local service="$1"
      systemctl show "$service.service" --property=InvocationID --value 2>/dev/null || echo ""
    }

    # HTTP health check
    check_health_http() {
      local url="$1"
      local timeout="$2"
      ${pkgs.curl}/bin/curl -sf --max-time "$timeout" "$url" > /dev/null 2>&1
    }

    # TCP health check
    check_health_tcp() {
      local target="$1"
      local timeout="$2"
      local host port
      host=$(echo "$target" | cut -d: -f1)
      port=$(echo "$target" | cut -d: -f2)
      ${pkgs.netcat}/bin/nc -z -w "$timeout" "$host" "$port" > /dev/null 2>&1
    }

    # Exec health check
    check_health_exec() {
      local cmd="$1"
      local timeout="$2"
      local result
      result=$(${pkgs.coreutils}/bin/timeout "$timeout" ${pkgs.bash}/bin/sh -c "$cmd" 2>&1)
      local exit_code=$?
      if [[ $exit_code -ne 0 ]]; then
        log_warn "Exec check failed (exit $exit_code): $result"
      fi
      return $exit_code
    }

    # Perform health check based on type
    do_health_check() {
      local type="$1"
      local target="$2"
      local timeout="$3"

      case "$type" in
        http)
          check_health_http "$target" "$timeout"
          ;;
        tcp)
          check_health_tcp "$target" "$timeout"
          ;;
        exec)
          check_health_exec "$target" "$timeout"
          ;;
        *)
          log_error "Unknown health check type: $type"
          return 1
          ;;
      esac
    }

    # Read health failure count
    get_health_failures() {
      local service="$1"
      local file="$STATE_DIR/health_failures_$service"
      if [[ -f "$file" ]]; then
        cat "$file"
      else
        echo "0"
      fi
    }

    # Update health failure count
    set_health_failures() {
      local service="$1"
      local count="$2"
      echo "$count" > "$STATE_DIR/health_failures_$service"
    }

    # Check rate limiting
    check_rate_limit() {
      local service="$1"
      local max_restarts="$2"
      local window_minutes="$3"
      local cooldown_minutes="$4"
      local restart_log="$STATE_DIR/restarts_$service"
      local cooldown_file="$STATE_DIR/cooldown_$service"

      # Check if in cooldown
      if [[ -f "$cooldown_file" ]]; then
        local cooldown_until
        cooldown_until=$(cat "$cooldown_file")
        local now
        now=$(date +%s)
        if [[ "$now" -lt "$cooldown_until" ]]; then
          log_warn "Service $service is in cooldown until $(date -d @"$cooldown_until" -Iseconds)"
          return 1
        else
          rm -f "$cooldown_file"
        fi
      fi

      # Count restarts in window
      local window_start
      window_start=$(($(date +%s) - window_minutes * 60))
      local restart_count=0

      if [[ -f "$restart_log" ]]; then
        while read -r timestamp; do
          if [[ "$timestamp" -ge "$window_start" ]]; then
            restart_count=$((restart_count + 1))
          fi
        done < "$restart_log"
      fi

      if [[ "$restart_count" -ge "$max_restarts" ]]; then
        # Enter cooldown
        local cooldown_until
        cooldown_until=$(($(date +%s) + cooldown_minutes * 60))
        echo "$cooldown_until" > "$cooldown_file"
        log_warn "Service $service hit rate limit ($restart_count restarts in $window_minutes min), entering cooldown"
        return 1
      fi

      return 0
    }

    # Record a restart
    record_restart() {
      local service="$1"
      local restart_log="$STATE_DIR/restarts_$service"
      echo "$(date +%s)" >> "$restart_log"

      # Clean old entries (keep last 100)
      if [[ -f "$restart_log" ]]; then
        tail -100 "$restart_log" > "$restart_log.tmp" && mv "$restart_log.tmp" "$restart_log"
      fi
    }

    # Restart a service
    do_restart() {
      local service="$1"
      local reason="$2"

      log_info "Restarting service $service (reason: $reason)"

      if systemctl restart "$service.service"; then
        record_restart "$service"
        log_info "Service $service restarted successfully"
        return 0
      else
        log_error "Failed to restart service $service"
        return 1
      fi
    }

    # Check dependency invocation IDs
    check_dependencies() {
      local service="$1"
      local deps="$2"
      local state_file="$STATE_DIR/deps_$service"

      # No dependencies configured
      if [[ -z "$deps" || "$deps" == "null" || "$deps" == "[]" ]]; then
        return 1
      fi

      # Parse dependency list
      local dep_list
      dep_list=$(echo "$deps" | ${pkgs.yq-go}/bin/yq -r '.[]' 2>/dev/null || echo "")

      if [[ -z "$dep_list" ]]; then
        return 1
      fi

      local needs_restart=1

      for dep in $dep_list; do
        local current_id
        current_id=$(get_invocation_id "$dep")
        local stored_id=""

        if [[ -f "$state_file" ]]; then
          stored_id=$(grep "^$dep=" "$state_file" 2>/dev/null | cut -d= -f2 || echo "")
        fi

        # Update stored ID
        if [[ -f "$state_file" ]]; then
          grep -v "^$dep=" "$state_file" > "$state_file.tmp" 2>/dev/null || true
          mv "$state_file.tmp" "$state_file"
        fi
        echo "$dep=$current_id" >> "$state_file"

        # Check if dependency restarted
        if [[ -n "$stored_id" && -n "$current_id" && "$stored_id" != "$current_id" ]]; then
          log_info "Dependency $dep of $service has restarted (invocation ID changed)"
          needs_restart=0
        fi
      done

      return $needs_restart
    }

    # Metrics tracking variables
    declare -A METRICS_RESTARTS
    declare -A METRICS_HEALTH_FAILURES
    declare -A METRICS_UP
    declare -A METRICS_RATE_LIMITED

    # Write prometheus metrics
    write_metrics() {
      local config="$1"
      local metrics_enable
      metrics_enable=$(get_setting "$config" "metrics.enable" "false")

      if [[ "$metrics_enable" != "true" ]]; then
        return
      fi

      local textfile_enable
      textfile_enable=$(get_setting "$config" "metrics.textfile.enable" "true")
      local textfile_path
      textfile_path=$(get_setting "$config" "metrics.textfile.path" "$STATE_DIR/metrics.prom")

      local vm_enable
      vm_enable=$(get_setting "$config" "metrics.victoriametrics.enable" "false")
      local vm_endpoint
      vm_endpoint=$(get_setting "$config" "metrics.victoriametrics.endpoint" "")

      # Build metrics output
      local metrics=""
      metrics+="# HELP watcher_service_restarts_total Total number of service restarts triggered by watcher\n"
      metrics+="# TYPE watcher_service_restarts_total counter\n"
      for service in "''${!METRICS_RESTARTS[@]}"; do
        metrics+="watcher_service_restarts_total{service=\"$service\"} ''${METRICS_RESTARTS[$service]}\n"
      done

      metrics+="# HELP watcher_service_health_failures_total Total health check failures\n"
      metrics+="# TYPE watcher_service_health_failures_total counter\n"
      for service in "''${!METRICS_HEALTH_FAILURES[@]}"; do
        metrics+="watcher_service_health_failures_total{service=\"$service\"} ''${METRICS_HEALTH_FAILURES[$service]}\n"
      done

      metrics+="# HELP watcher_service_up Service health status (1=healthy, 0=unhealthy)\n"
      metrics+="# TYPE watcher_service_up gauge\n"
      for service in "''${!METRICS_UP[@]}"; do
        metrics+="watcher_service_up{service=\"$service\"} ''${METRICS_UP[$service]}\n"
      done

      metrics+="# HELP watcher_rate_limited Whether service is rate limited (1=yes, 0=no)\n"
      metrics+="# TYPE watcher_rate_limited gauge\n"
      for service in "''${!METRICS_RATE_LIMITED[@]}"; do
        metrics+="watcher_rate_limited{service=\"$service\"} ''${METRICS_RATE_LIMITED[$service]}\n"
      done

      # Write to textfile
      if [[ "$textfile_enable" == "true" ]]; then
        local textfile_dir
        textfile_dir=$(dirname "$textfile_path")
        mkdir -p "$textfile_dir"
        echo -e "$metrics" > "$textfile_path.tmp"
        mv "$textfile_path.tmp" "$textfile_path"
        log_info "Wrote metrics to $textfile_path"
      fi

      # Push to VictoriaMetrics
      if [[ "$vm_enable" == "true" && -n "$vm_endpoint" ]]; then
        local extra_labels=""
        # Get extra labels (simplified - assumes flat structure)
        local labels_json
        labels_json=$(get_setting "$config" "metrics.victoriametrics.labels" "{}")
        if [[ "$labels_json" != "{}" && "$labels_json" != "null" ]]; then
          # Add extra labels to each metric line
          log_info "Pushing metrics to VictoriaMetrics at $vm_endpoint"
        fi

        echo -e "$metrics" | ${pkgs.curl}/bin/curl -sf -X POST \
          --data-binary @- \
          "$vm_endpoint" > /dev/null 2>&1 || \
          log_warn "Failed to push metrics to VictoriaMetrics"
      fi
    }

    # Load restart counts from state
    load_restart_counts() {
      for file in "$STATE_DIR"/restarts_*; do
        if [[ -f "$file" ]]; then
          local service
          service=$(basename "$file" | sed 's/restarts_//')
          local count
          count=$(wc -l < "$file" 2>/dev/null || echo "0")
          METRICS_RESTARTS[$service]=$count
        fi
      done
    }

    # Main check loop
    main() {
      log_info "Watcher starting..."

      # Ensure state directory exists
      mkdir -p "$STATE_DIR"

      # Load configuration
      local config
      config=$(load_config)

      if [[ -z "$config" ]]; then
        log_error "Failed to load configuration"
        exit 1
      fi

      # Load existing restart counts for metrics
      load_restart_counts

      # Get global rate limiting settings
      local global_max_restarts
      global_max_restarts=$(get_setting "$config" "rateLimiting.maxRestarts" "5")
      local global_window
      global_window=$(get_setting "$config" "rateLimiting.windowMinutes" "15")
      local global_cooldown
      global_cooldown=$(get_setting "$config" "rateLimiting.cooldownMinutes" "10")

      # Process each service
      local services
      services=$(get_services "$config")
      local services_checked=0
      local services_healthy=0
      local services_restarted=0

      for service in $services; do
        local enabled
        enabled=$(get_service_prop "$config" "$service" "enable" "true")

        if [[ "$enabled" != "true" ]]; then
          log_info "Service $service is disabled, skipping"
          continue
        fi

        log_info "Checking service: $service"
        services_checked=$((services_checked + 1))

        # Initialize metrics
        METRICS_UP[$service]=1
        METRICS_RATE_LIMITED[$service]=0
        [[ -z "''${METRICS_RESTARTS[$service]:-}" ]] && METRICS_RESTARTS[$service]=0
        [[ -z "''${METRICS_HEALTH_FAILURES[$service]:-}" ]] && METRICS_HEALTH_FAILURES[$service]=0

        local needs_restart=false
        local restart_reason=""

        # Get per-service rate limiting (or use global)
        local max_restarts
        max_restarts=$(get_service_prop "$config" "$service" "rateLimiting.maxRestarts" "null")
        [[ "$max_restarts" == "null" ]] && max_restarts=$global_max_restarts

        local window
        window=$(get_service_prop "$config" "$service" "rateLimiting.windowMinutes" "null")
        [[ "$window" == "null" ]] && window=$global_window

        # Check systemd state
        local on_failed
        on_failed=$(get_service_prop "$config" "$service" "onFailed" "true")
        local on_inactive
        on_inactive=$(get_service_prop "$config" "$service" "onInactive" "false")

        local state
        state=$(check_systemd_state "$service")

        if [[ "$on_failed" == "true" && "$state" == "failed" ]]; then
          needs_restart=true
          restart_reason="systemd state is failed"
          METRICS_UP[$service]=0
        elif [[ "$on_inactive" == "true" && "$state" == "inactive" ]]; then
          needs_restart=true
          restart_reason="systemd state is inactive"
          METRICS_UP[$service]=0
        fi

        # Check health (only if service appears running)
        if [[ "$state" == "active" ]]; then
          local health_enable
          health_enable=$(get_service_prop "$config" "$service" "healthCheck.enable" "false")

          if [[ "$health_enable" == "true" ]]; then
            local health_type
            health_type=$(get_service_prop "$config" "$service" "healthCheck.type" "http")
            local health_target
            health_target=$(get_service_prop "$config" "$service" "healthCheck.target" "")
            local health_timeout
            health_timeout=$(get_service_prop "$config" "$service" "healthCheck.timeout" "10s")
            local failures_threshold
            failures_threshold=$(get_service_prop "$config" "$service" "healthCheck.failuresBeforeRestart" "3")

            # Convert timeout to seconds
            local timeout_secs
            timeout_secs=$(echo "$health_timeout" | sed 's/s$//')

            if ! do_health_check "$health_type" "$health_target" "$timeout_secs"; then
              local current_failures
              current_failures=$(get_health_failures "$service")
              current_failures=$((current_failures + 1))
              set_health_failures "$service" "$current_failures"
              METRICS_HEALTH_FAILURES[$service]=$current_failures

              log_warn "Health check failed for $service ($current_failures/$failures_threshold)"

              if [[ "$current_failures" -ge "$failures_threshold" ]]; then
                needs_restart=true
                restart_reason="health check failed $current_failures times"
                METRICS_UP[$service]=0
                # Reset failure counter
                set_health_failures "$service" "0"
              fi
            else
              # Health check passed, reset counter
              set_health_failures "$service" "0"
              services_healthy=$((services_healthy + 1))
              log_info "Health check passed for $service ($health_type)"
            fi
          else
            # No health check, but service is active
            services_healthy=$((services_healthy + 1))
          fi
        else
          log_info "Service $service state: $state"
        fi

        # Check dependencies
        if [[ "$needs_restart" != true ]]; then
          local deps
          deps=$(get_service_prop "$config" "$service" "dependencies" "[]")

          if check_dependencies "$service" "$deps"; then
            needs_restart=true
            restart_reason="dependency restarted"
          fi
        fi

        # Perform restart if needed (with rate limiting)
        if [[ "$needs_restart" == true ]]; then
          if check_rate_limit "$service" "$max_restarts" "$window" "$global_cooldown"; then
            if do_restart "$service" "$restart_reason"; then
              METRICS_RESTARTS[$service]=$((''${METRICS_RESTARTS[$service]} + 1))
              services_restarted=$((services_restarted + 1))
            fi
          else
            METRICS_RATE_LIMITED[$service]=1
          fi
        fi
      done

      # Write metrics
      write_metrics "$config"

      log_info "Watcher completed: $services_checked checked, $services_healthy healthy, $services_restarted restarted"
    }

    main "$@"
  '';

in

{
  ###### interface

  options = {

    services.watcher = {
      enable = mkEnableOption "systemd service watcher";

      interval = mkOption {
        type = types.str;
        default = "30s";
        example = "1m";
        description = ''
          How often to check services. Supports systemd time format (s, m, h).
        '';
      };

      settings = {
        rateLimiting = {
          maxRestarts = mkOption {
            type = types.int;
            default = 5;
            description = ''
              Maximum number of restarts allowed within the window period.
            '';
          };

          windowMinutes = mkOption {
            type = types.int;
            default = 15;
            description = ''
              Time window in minutes for counting restarts.
            '';
          };

          cooldownMinutes = mkOption {
            type = types.int;
            default = 10;
            description = ''
              Cooldown period in minutes after hitting the rate limit.
            '';
          };
        };

        metrics = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable prometheus metrics collection.
            '';
          };

          textfile = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Write metrics to a prometheus textfile for node_exporter.
              '';
            };

            path = mkOption {
              type = types.str;
              default = "${stateDir}/metrics.prom";
              description = ''
                Path to write the prometheus textfile metrics.
              '';
            };
          };

          victoriametrics = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Push metrics directly to VictoriaMetrics.
              '';
            };

            endpoint = mkOption {
              type = types.str;
              default = "";
              example = "http://vminsert:8480/insert/0/prometheus/api/v1/import/prometheus";
              description = ''
                VictoriaMetrics import endpoint URL.
              '';
            };

            labels = mkOption {
              type = types.attrsOf types.str;
              default = { };
              example = { env = "production"; };
              description = ''
                Extra labels to add to all metrics.
              '';
            };
          };
        };
      };

      services = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether to watch this service.
              '';
            };

            onFailed = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Restart service when systemd reports it as failed.
              '';
            };

            onInactive = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Restart service when it becomes inactive (stopped).
              '';
            };

            healthCheck = {
              enable = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Enable health check for this service.
                '';
              };

              type = mkOption {
                type = types.enum [ "http" "tcp" "exec" ];
                default = "http";
                description = ''
                  Type of health check to perform.
                  - http: HTTP GET request to URL
                  - tcp: TCP connection to host:port
                  - exec: Execute a command
                '';
              };

              target = mkOption {
                type = types.str;
                default = "";
                example = "http://localhost:8080/health";
                description = ''
                  Health check target. URL for http, host:port for tcp, command for exec.
                '';
              };

              timeout = mkOption {
                type = types.str;
                default = "10s";
                description = ''
                  Timeout for health check.
                '';
              };

              failuresBeforeRestart = mkOption {
                type = types.int;
                default = 3;
                description = ''
                  Number of consecutive failures before triggering a restart.
                '';
              };
            };

            dependencies = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ "etcd" "consul" ];
              description = ''
                List of service names. If any of these services restart,
                this service will also be restarted.
              '';
            };

            rateLimiting = {
              maxRestarts = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = ''
                  Override the global maxRestarts setting for this service.
                '';
              };

              windowMinutes = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = ''
                  Override the global windowMinutes setting for this service.
                '';
              };
            };
          };
        });
        default = { };
        description = ''
          Services to watch and their configuration.
        '';
        example = literalExpression ''
          {
            nginx = {
              onFailed = true;
              healthCheck = {
                enable = true;
                type = "http";
                target = "http://localhost/health";
                failuresBeforeRestart = 3;
              };
            };
            postgresql = {
              onFailed = true;
              healthCheck = {
                enable = true;
                type = "tcp";
                target = "localhost:5432";
              };
              dependencies = [ "etcd" ];
            };
          }
        '';
      };

      extraConfigDir = mkOption {
        type = types.str;
        default = "/etc/watcher/config.d";
        description = ''
          Directory for runtime YAML configuration overrides.
          Files are merged in alphabetical order.
        '';
      };
    };

  };

  ###### implementation

  config = mkIf cfg.enable {

    # Create config directory and file
    environment.etc."watcher/config.yaml".source = configYaml;

    # Create extra config directory
    systemd.tmpfiles.rules = [
      "d '${cfg.extraConfigDir}' 0755 root root - -"
      "d '${stateDir}' 0750 root root - -"
    ];

    systemd.services.watcher = {
      description = "Service Watcher";
      after = [ "network.target" ];

      path = with pkgs; [
        coreutils
        systemd
        gnugrep
        gnused
        findutils
        yq-go
        curl
        netcat
        jq
      ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = watcherScript;

        # State directory
        StateDirectory = "watcher";
        StateDirectoryMode = "0750";

        # Hardening
        CapabilityBoundingSet = [ "" ];
        DevicePolicy = "closed";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];

        # Allow systemctl access
        ReadWritePaths = [ stateDir ];
      };
    };

    systemd.timers.watcher = {
      description = "Service Watcher Timer";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnBootSec = cfg.interval;
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "1s";
      };
    };

  };

  meta.maintainers = [ ];
}
