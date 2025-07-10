# SPDX-FileCopyrightText: © 2025 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs, getanix }:

let
  inherit (pkgs) lib;
in

let
  check = builtins.mapAttrs getanix.strings.checkRegex {
    serviceName = ''[a-z][0-9a-z]{0,15}(-[0-9a-z]{1,16}){0,8}'';
    user = ''[a-z][0-9a-z-]{0,31}'';
    group = ''[a-z][0-9a-z-]{0,31}'';
    configString = ''[0-9a-zA-Z ./-]{0,64}'';
    uid = ''0|[1-9][0-9]{3}'';
    gid = ''0|[1-9][0-9]{3}'';
  };
in

let
  waitForPort = port: ''
    while ! ${pkgs.netcat}/bin/nc -N 127.0.0.1 -- ${lib.escapeShellArg (toString port)} </dev/null >/dev/null 2>/dev/null; do
      sleep 0.01
    done
  '';
in

let
  waitForUnixSocket = unixSocket: ''
    while ! ${pkgs.netcat}/bin/nc -UN -- ${lib.escapeShellArg unixSocket} </dev/null >/dev/null 2>/dev/null; do
      sleep 0.01
    done
  '';
in

let
  mkService =
    {
      name,
      dataDir,
      dependencies ? [ ],
      initDataDir ? "",
      waitForService ? null,
      execService,
      conf ? getanix.build.emptyFragment,
    }:
    with getanix.build;
    mkDeriv {
      name = check.serviceName name;
      out = mkDir {
        bin = mkDir {
          "run-${check.serviceName name}" = mkScript ''
            #!${pkgs.busybox}/bin/sh
            set -Cefu
            exec 3>&2 2>&1
            export PATH=${lib.makeBinPath [ pkgs.busybox ]}
            mkdir -p -- ${lib.escapeShellArg dataDir}
            cd       -- ${lib.escapeShellArg dataDir}
            rm -rf run
            mkdir  run
            ${initDataDir}
            ${
              if waitForService == null then
                ""
              else
                ''
                  {
                    ${waitForService}
                    echo Ready >&3 # Notify readiness to the original stderr
                  } &
                ''
            }
            ${execService}
          '';
        };
        inherit conf;
        run = mkSymlink "${dataDir}/run";
        service = mkDir {
          "${check.serviceName name}" = mkDir {
            type = mkFile "longrun";
            notification-fd = mkFile "2";
            producer-for = mkFile "${check.serviceName name}@log";
            "dependencies.d" = mkDir (
              builtins.foldl' lib.attrsets.unionOfDisjoint { } (
                builtins.map (dependency: {
                  "${check.serviceName (lib.getName dependency)}" = mkFile "${dependency}";
                }) dependencies
              )
            );
            run = mkFile ''
              #!${pkgs.busybox}/bin/sh
              exec ${out}/bin/run-${check.serviceName name}
            '';
          };
          "${check.serviceName name}@log" = mkDir {
            type = mkFile "longrun";
            consumer-for = mkFile "${check.serviceName name}";
            run = mkFile ''
              #!${pkgs.busybox}/bin/sh
              exec ${pkgs.s6}/bin/s6-log p${lib.escapeShellArg name}: 1
            '';
          };
        };
      };
    };
in

let
  mkServiceManager =
    {
      name ? "services",
      dataDir,
      mainService,
      extraServices ? [ ],
    }:
    let
      services = [ mainService ] ++ extraServices;
      allServiceDirsWithDependencies =
        builtins.filter lib.pathIsDirectory (
          builtins.map (drv: "${drv}/service") (getanix.closure.closureList services)
        );
    in
    with getanix.build;
    mkService {
      inherit name dataDir;
      initDataDir = ''
        cd run
        mkfifo .initial-notification
        exec 4<>.initial-notification
        exec 5<.initial-notification
        exec 6>.initial-notification
        exec 4<&-
        rm -f .initial-notification
        mkdir scandir
      '';
      waitForService = ''
        exec 6<&-
        read -r _INITIAL_NOTIFICATION <&5 >/dev/null
        # Workaround for https://github.com/skarnet/s6-rc/issues/10
        cp -Rp ${out}/conf/compiled compiled
        chmod -R u+w compiled
        ${pkgs.s6-rc}/bin/s6-rc-init \
          -c "$(pwd)"/compiled \
          -l "$(pwd)"/live \
          "$(pwd)"/scandir
        ${pkgs.s6-rc}/bin/s6-rc \
          -l live \
          -u change \
          ${lib.escapeShellArg (check.serviceName (lib.getName mainService))}
      '';
      execService = ''
        exec 5<&-
        exec ${pkgs.s6}/bin/s6-svscan -d 6 "$(pwd)"/scandir
      '';
      conf = mkDir {
        compiled = mkCommandFragment ''${pkgs.s6-rc}/bin/s6-rc-compile "$outSubPath" ${
          lib.concatStringsSep " " allServiceDirsWithDependencies
        }'';
      };
    };
in

let
  mkNginxService =
    {
      name ? "nginx",
      dataDir,
      nginx ? pkgs.nginx,
      extraDependencies ? [ ],
      mainPort,
      extraMainConfig ? "",
      extraHttpConfig,
    }:
    assert builtins.isInt mainPort;
    with getanix.build;
    mkService {
      inherit name dataDir;
      dependencies = extraDependencies;
      initDataDir = ''
        if [ ! -e certs/server.key ]; then
          echo "$(date +'%Y-%m-%d %H:%M:%S') Generating self-signed certificate ..."
          mkdir -p certs
          touch     certs/server.key
          chmod 600 certs/server.key
          ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 -sha256 -days 36500 -nodes \
            -keyout certs/server.key \
            -out    certs/server-with-intermediates.crt \
            -subj "/CN=localhost" \
            -addext "subjectAltName=DNS:localhost"
          echo "$(date +'%Y-%m-%d %H:%M:%S') Finished."
        fi
      '';
      waitForService = waitForPort mainPort;
      execService = ''
        exec ${nginx}/bin/nginx -e /dev/stdout -c ${out}/conf/nginx.conf
      '';
      conf = mkDir {
        certs = mkSymlink "${dataDir}/certs";
        "fastcgi_params" = mkSymlink "${nginx}/conf/fastcgi_params";
        "mime.types" = mkSymlink "${nginx}/conf/mime.types";
        "nginx.conf" = mkFile ''
          daemon off;
          error_log stderr error;
          pid ${out}/run/nginx.pid;
          ${extraMainConfig}
          http {
            client_body_temp_path ${out}/run/body;
            fastcgi_temp_path     ${out}/run/fastcgi;
            proxy_temp_path       ${out}/run/proxy;
            scgi_temp_path        ${out}/run/scgi;
            uwsgi_temp_path       ${out}/run/uwsgi;
            access_log /dev/stdout;
            include mime.types;
            default_type application/octet-stream;
            ${extraHttpConfig mainPort}
          }
        '';
      };
    };
in

let
  mkPhpFpmService =
    {
      name ? "php-fpm",
      dataDir,
      php ? pkgs.php,
      extraGlobalConfig ? "",
      extraPoolConfig ? "",
      extraPaths ? [ ],
      extraDependencies ? [ ],
      extraInitCommands ? "",
    }:
    let
      paths = extraPaths ++ [
        pkgs.busybox
        php
      ];
    in
    with getanix.build;
    mkService {
      inherit name dataDir;
      dependencies = extraDependencies;
      initDataDir = ''
        mkdir -p sessions
        ${extraInitCommands}
      '';
      waitForService = waitForUnixSocket "run/php-fpm.sock";
      execService = ''
        exec ${php}/bin/php-fpm -y ${out}/conf/php-fpm.conf
      '';
      conf = mkDir {
        "php-fpm.conf" = mkFile ''
          [global]
          daemonize = no
          error_log = /dev/stderr
          systemd_interval = 0
          ${extraGlobalConfig}
          [www]
          listen = ${out}/run/php-fpm.sock
          catch_workers_output = yes
          slowlog = /dev/stderr
          clear_env = yes
          env[PATH] = ${lib.makeBinPath paths}
          php_admin_value[session.save_path] = ${check.configString dataDir}/sessions
          ${extraPoolConfig}
        '';
      };
    };
in

let
  mkPostgresqlService =
    {
      name ? "postgresql",
      dataDir,
      postgresql ? pkgs.postgresql,
      extraConfig ? "",
    }:
    with getanix.build;
    mkService {
      inherit name dataDir;
      initDataDir = ''
        if [ ! -e certs/postgresql.key ]; then
          echo "$(date +'%Y-%m-%d %H:%M:%S') Generating self-signed certificate ..."
          mkdir -p certs
          touch     certs/postgresql.key
          chmod 600 certs/postgresql.key
          ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 -sha256 -days 36500 -nodes \
            -keyout certs/postgresql.key \
            -out    certs/postgresql.crt \
            -subj "/CN=localhost" \
            -addext "subjectAltName=DNS:localhost"
          echo "$(date +'%Y-%m-%d %H:%M:%S') PostgreSQL certificate generated."
        fi
        if [ ! -e data ]; then
          ${postgresql}/bin/initdb -D data -E UTF-8 -A peer
        fi
        ln -sf ${out}/conf/postgresql.conf data/
        ln -sf ${out}/conf/pg_hba.conf     data/
        rm -f data/postmaster.pid
        mkdir run/postgresql
      '';
      waitForService = ''
        cd run/postgresql
        while ! ${postgresql}/bin/pg_isready -h "$(pwd)" -p "$(find . -type s | cut -d. -f5)" >/dev/null; do
          sleep 0.01
        done
      '';
      execService = ''
        exec ${postgresql}/bin/postgres -D "$(pwd)"/data
      '';
      conf = mkDir {
        "postgresql.conf" = mkFile ''
          unix_socket_directories = '${out}/run/postgresql'
          ssl = on
          ssl_cert_file = '../certs/postgresql.crt'
          ssl_key_file  = '../certs/postgresql.key'
          log_timezone = 'UTC'
          datestyle = 'iso, mdy'
          timezone = 'UTC'
          lc_messages = 'C'
          lc_monetary = 'C'
          lc_numeric = 'C'
          lc_time = 'C'
          default_text_search_config = 'pg_catalog.english'
          ${extraConfig}
        '';
        "pg_hba.conf" = mkFile ''
          # type  database user address auth-method
          #------|--------|----|-------|-------------
          local   all      all          peer
          hostssl all      all  all     scram-sha-256
        '';
      };
    };
in

{
  inherit
    mkService
    mkServiceManager
    mkNginxService
    mkPhpFpmService
    mkPostgresqlService
    waitForPort
    ;
}
