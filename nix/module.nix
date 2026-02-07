{ config, lib, pkgs, ... }:

let
  cfg = config.services.systemd-cri;
in
{
  options.services.systemd-cri = {
    enable = lib.mkEnableOption "systemd-cri container runtime";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The systemd-cri package to use.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "warn" "error" ];
      default = "info";
      description = "Log level for systemd-cri.";
    };

    streamingPort = lib.mkOption {
      type = lib.types.port;
      default = 10010;
      description = "Port for the HTTP streaming server (exec/attach).";
    };

    socketPath = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Override the gRPC socket path.
        Defaults to /run/systemd-cri/cri.sock (via RUNTIME_DIRECTORY).
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Override the state directory.
        Defaults to /var/lib/systemd-cri (via STATE_DIRECTORY).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    systemd.services.systemd-cri = {
      description = "Container Runtime Interface using systemd";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "dbus.service" ];
      requires = [ "dbus.service" ];

      path = [
        pkgs.skopeo
        pkgs.umoci
      ];

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          args = lib.cli.toGNUCommandLineShell {} {
            log-level = cfg.logLevel;
            streaming-port = cfg.streamingPort;
            socket = cfg.socketPath;
            state-dir = cfg.stateDir;
          };
        in "${cfg.package}/bin/systemd-cri ${args}";

        Restart = "on-failure";
        RestartSec = "5s";

        # Use systemd's directory management
        StateDirectory = "systemd-cri";
        RuntimeDirectory = "systemd-cri";

        # Security hardening
        NoNewPrivileges = false; # Needs privileges for container operations
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [
          "/var/lib/machines"
          "/var/lib/systemd-cri"
          "/run/systemd-cri"
        ];

        # Needs access to systemd and D-Bus
        ProtectControlGroups = false;
        ProtectKernelTunables = false;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;

        # Container runtime needs various capabilities
        AmbientCapabilities = [
          "CAP_SYS_ADMIN"
          "CAP_NET_ADMIN"
          "CAP_MKNOD"
          "CAP_CHOWN"
          "CAP_FOWNER"
          "CAP_DAC_OVERRIDE"
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_KILL"
        ];
        CapabilityBoundingSet = [
          "CAP_SYS_ADMIN"
          "CAP_NET_ADMIN"
          "CAP_MKNOD"
          "CAP_CHOWN"
          "CAP_FOWNER"
          "CAP_DAC_OVERRIDE"
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_KILL"
        ];
      };
    };

    # Ensure machined is available for image management
    systemd.services.systemd-machined.enable = true;
  };
}
