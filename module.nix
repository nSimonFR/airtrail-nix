# NixOS module for AirTrail — self-hosted personal flight tracker.
#
# Usage in nic-os (or any NixOS flake):
#
#   inputs.airtrail-nix.url = "github:nSimonFR/airtrail-nix";
#
#   imports = [ inputs.airtrail-nix.nixosModules.airtrail ];
#   services.airtrail = {
#     enable          = true;
#     origin          = "https://airtrail.example.ts.net";
#     environmentFile = "/run/agenix/airtrail-env";   # provides DB_URL (with password)
#   };
#
# The environmentFile must export at minimum:
#   DB_URL=postgres://airtrail:<password>@127.0.0.1:5432/airtrail
#
# AirTrail is a single Node (SvelteKit adapter-node) process plus a one-shot
# SQL migration runner. PostgreSQL must be provided by the host; the `unaccent`
# extension must exist in the database (a migration issues CREATE EXTENSION,
# which needs superuser — pre-create it, IF NOT EXISTS is idempotent).
#
# First boot against an empty database seeds ~85k airports and fetches airline
# icons from GitHub — it needs network and takes a few minutes; later starts are
# instant. The service is intentionally always-on (steady-state RSS ~65 MB).
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.airtrail;
  defaultPackage = pkgs.callPackage (self + "/package.nix") { };

  appEnv = {
    NODE_ENV = "production";
    HOST = cfg.host;
    PORT = toString cfg.port;
    ORIGIN = cfg.origin;
    UPLOAD_LOCATION = "${cfg.stateDir}/uploads";
    # Trust the reverse proxy (Tailscale Serve / nginx) for scheme + host so
    # SvelteKit CSRF and absolute URLs are correct behind TLS termination.
    PROTOCOL_HEADER = "x-forwarded-proto";
    HOST_HEADER = "x-forwarded-host";
    BODY_SIZE_LIMIT = cfg.bodySizeLimit;
  } // lib.optionalAttrs (cfg.databaseUrl != null) {
    DB_URL = cfg.databaseUrl;
  } // cfg.settings;

  commonServiceConfig = {
    User = cfg.user;
    Group = cfg.group;
    WorkingDirectory = "${cfg.package}/share/airtrail";
    StateDirectory = baseNameOf cfg.stateDir;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    ReadWritePaths = [ cfg.stateDir ];
  } // lib.optionalAttrs (cfg.environmentFile != null) {
    EnvironmentFile = cfg.environmentFile;
  };
in
{
  options.services.airtrail = {
    enable = lib.mkEnableOption "AirTrail personal flight tracker";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "The AirTrail derivation to use.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the Node server binds to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port the Node server listens on.";
    };

    origin = lib.mkOption {
      type = lib.types.str;
      example = "https://airtrail.example.ts.net";
      description = ''
        Public origin (scheme://host[:port]) the app is served from. Required
        for SvelteKit CSRF: form POSTs from any other origin are rejected.
        Comma-separated list allowed for multiple origins.
      '';
    };

    databaseUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "postgres://airtrail@127.0.0.1:5432/airtrail";
      description = ''
        DB_URL for the app and migrator. Leave null and provide DB_URL via
        environmentFile when the connection string embeds a password (keeps
        the secret out of the world-readable Nix store).
      '';
    };

    bodySizeLimit = lib.mkOption {
      type = lib.types.str;
      default = "10M";
      description = "adapter-node BODY_SIZE_LIMIT (max request body, e.g. file imports).";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/airtrail";
      description = "Persistent state directory (holds uploads/).";
    };

    user = lib.mkOption { type = lib.types.str; default = "airtrail"; };
    group = lib.mkOption { type = lib.types.str; default = "airtrail"; };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to a file exporting secrets as KEY=VALUE lines (DB_URL at minimum).";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { OAUTH_ENABLED = "true"; };
      description = "Extra environment variables merged into all AirTrail services.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = lib.mkIf (cfg.user == "airtrail") {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = false;
    };
    users.groups.${cfg.group} = lib.mkIf (cfg.group == "airtrail") { };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir}         0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/uploads 0750 ${cfg.user} ${cfg.group} -"
    ];

    # ── airtrail-setup: apply SQL migrations on every boot (idempotent) ───────
    systemd.services.airtrail-setup = {
      description = "AirTrail — database migrations";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = commonServiceConfig // {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      environment = appEnv;
      script = "${cfg.package}/bin/airtrail-migrate";
    };

    # ── airtrail: SvelteKit (adapter-node) HTTP server ───────────────────────
    systemd.services.airtrail = {
      description = "AirTrail — flight tracker web server";
      after = [ "network-online.target" "airtrail-setup.service" ];
      wants = [ "network-online.target" ];
      requires = [ "airtrail-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = commonServiceConfig // {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/airtrail";
        Restart = "on-failure";
        RestartSec = "10s";
      };
      environment = appEnv;
    };
  };
}
