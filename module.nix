{
  capev2Src,
  capev2Env,
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.capev2;

  settingsFormat = pkgs.formats.ini {
    # CAPE lit les listes sous forme "a,b,c"
    listToValue = lib.concatMapStringsSep "," toString;
  };

  confFiles = lib.mapAttrs (name: value: settingsFormat.generate "${name}.conf" value) cfg.settings;
in
{
  options.services.capev2 = {
    enable = lib.mkEnableOption "CAPEv2 malware sandbox";

    settings = lib.mkOption {
      type = lib.types.attrsOf settingsFormat.type;
      default = { };
      description = ''
        Contenu des fichiers de conf/ de CAPEv2, sous la forme
        `<fichier>.<section>.<clé>`. Chaque entrée génère
        `conf/<fichier>.conf`, réécrit à chaque sync.
      '';
      example = lib.literalExpression ''
        {
          kvm.kvm.machines = "cuckoo1";
        }
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "cape";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "cape";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/capev2";
      description = "Writable CAPEv2 state directory.";
    };

    rooterSocket = lib.mkOption {
      type = lib.types.path;
      default = "/var/run/capev2/rooter.sock";
    };

    web.bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8000";
    };

    processor.parallel = lib.mkOption {
      type = lib.types.str;
      default = "1";
    };

    processor.timeout = lib.mkOption {
      type = lib.types.int;
      default = 3600;
    };

    processor.restartInterval = lib.mkOption {
      type = lib.types.str;
      default = "1min";
    };
  };

  config = lib.mkIf cfg.enable {

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      extraGroups = [ "libvirtd" ];
    };

    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d /var/run/capev2 0750 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.capev2-sync = {
      description = "Sync CAPEv2 source tree into state directory";

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
      };

      script = ''
        set -euo pipefail

        ${pkgs.rsync}/bin/rsync -a \
          --no-perms \
          --no-owner \
          --no-group \
          --delete \
          --exclude 'conf/' \
          --exclude 'storage/' \
          --exclude 'log/' \
          --exclude 'db/' \
          --exclude '__pycache__/' \
          --exclude '*.pyc' \
          ${capev2Src}/share/capev2/ ${cfg.stateDir}/

        mkdir -p \
          ${cfg.stateDir}/data/feeds \
          ${cfg.stateDir}/storage \
          ${cfg.stateDir}/log \
          ${cfg.stateDir}/db

        if [ ! -e "${cfg.stateDir}/conf" ]; then
          cp -r --no-preserve=mode,ownership \
            "${capev2Src}/share/capev2/conf" \
            "${cfg.stateDir}/conf"
        fi
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: file: ''install -D -m 0640 ${file} "${cfg.stateDir}/conf/${name}.conf"''
          ) confFiles
        )}
        chown -R ${cfg.user}:${cfg.group} ${cfg.stateDir}
        chmod 0750 ${cfg.stateDir}
      '';
      restartTriggers = lib.attrValues confFiles;
    };

    systemd.services.cape-rooter = {
      description = "CAPE rooter";

      after = [
        "network.target"
        "capev2-sync.service"
      ];

      requires = [ "capev2-sync.service" ];

      wantedBy = [ "multi-user.target" ];
      environment.PYTHONDONTWRITEBYTECODE = "1";
      serviceConfig = {
        ExecStart = ''
          ${capev2Env}/bin/python3 \
          ${cfg.stateDir}/utils/rooter.py \
          --systemctl ${pkgs.systemd}/bin/systemctl \
          --sysctl ${pkgs.procps}/bin/sysctl \
          --iptables ${pkgs.iptables}/bin/iptables \
          --iptables-save ${pkgs.iptables}/bin/iptables-save \
          --iptables-restore ${pkgs.iptables}/bin/iptables-restore \
          --ip ${pkgs.iproute2}/bin/ip \
          -g ${cfg.group} \
          ${cfg.rooterSocket}
        '';

        User = "root";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.services.cape = {
      description = "CAPE scheduler";

      after = [
        "network.target"
        "postgresql.service"
        "capev2-sync.service"
        "cape-rooter.service"
      ];

      requires = [
        "capev2-sync.service"
        "cape-rooter.service"
      ];

      wants = [ "postgresql.service" ];

      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${capev2Env}/bin/python3 ${cfg.stateDir}/cuckoo.py";

        WorkingDirectory = cfg.stateDir;

        User = cfg.user;
        Group = cfg.group;

        Restart = "on-failure";
        RestartSec = "5s";
      };
      environment = {
        LD_LIBRARY_PATH = lib.makeLibraryPath [
          pkgs.file
        ];
      };
    };

    systemd.services.cape-processor = {
      description = "CAPE processor";

      after = [
        "capev2-sync.service"
        "cape.service"
      ];

      requires = [ "capev2-sync.service" ];

      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart =
          "${capev2Env}/bin/python3 "
          + "${cfg.stateDir}/utils/process.py "
          + "-p${cfg.processor.parallel} "
          + "-pt ${toString cfg.processor.timeout}";

        WorkingDirectory = cfg.stateDir;

        User = cfg.user;
        Group = cfg.group;

        Restart = "always";
        RestartSec = cfg.processor.restartInterval;
      };
    };

    systemd.services.cape-web = {
      description = "CAPE web";

      after = [
        "network.target"
        "postgresql.service"
        "capev2-sync.service"
        "cape.service"
      ];

      requires = [ "capev2-sync.service" ];

      wants = [ "postgresql.service" ];

      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart =
          "${capev2Env}/bin/python3 manage.py runserver_plus " + "--noreload ${cfg.web.bindAddress}";

        WorkingDirectory = "${cfg.stateDir}/web";

        User = cfg.user;
        Group = cfg.group;

        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    services.postgresql.enable = lib.mkDefault true;
    virtualisation.libvirtd.enable = lib.mkDefault true;
  };
}
