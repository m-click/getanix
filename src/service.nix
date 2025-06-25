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
  getAllTransitiveDependencyServices = services: services;
in

let
  mkServiceManager =
    {
      name ? "service-manager",
      dataDir ? "/var/lib/${name}",
      initialService,
      extraServices ? [ ],
    }:
    let
      allServices = getAllTransitiveDependencyServices ([ initialService ] ++ extraServices);
    in
    with getanix.build;
    mkDeriv {
      inherit name;
      out = mkDir {
        bin = mkDir {
          "run-${check.serviceName name}" = mkScript ''
            #!${pkgs.busybox}/bin/sh
            set -Cefu
            exec 3>&2 2>&1
            export PATH=${
              lib.makeBinPath [
                pkgs.busybox
                pkgs.s6
                pkgs.s6-rc
              ]
            }
            datadir=${lib.escapeShellArg dataDir}
            rm -rf   -- "$datadir"
            mkdir -p -- $(dirname -- "$datadir")
            mkdir    -- "$datadir"
            cd       -- "$datadir"
            mkfifo .initial-notification
            exec 4<>.initial-notification
            exec 5<.initial-notification
            exec 6>.initial-notification
            exec 4<&-
            rm -f .initial-notification
            {
              exec 6<&-
              read -r _INITIAL_NOTIFICATION <&5 >/dev/null
              # Workaround for https://github.com/skarnet/s6-rc/issues/10
              cp -Rp ${out}/compiled compiled
              chmod -R u+w compiled
              s6-rc-init \
                -c "$datadir"/compiled \
                -l "$datadir"/live \
                "$datadir"/scandir
              s6-rc \
                -l live \
                -u change \
                ${lib.escapeShellArg (check.serviceName (lib.getName initialService))}
              echo Ready >&3 # Notify readiness to the original stderr
            } &
            exec 5<&-
            mkdir scandir
            cd /
            exec s6-svscan -d 6 "$datadir"/scandir
          '';
        };
        compiled = mkCommandFragment ''${pkgs.s6-rc}/bin/s6-rc-compile "$outSubPath" ${
          lib.concatMapStringsSep " " (service: "${service}/service") allServices
        }'';
      };
    };
in

let
  mkNginxService =
    {
      name ? "nginx",
      dataDir ? "/var/lib/${name}",
      nginx ? pkgs.nginx,
      checkPort,
      extraDependencies ? [ ],
      extraMainConfig ? "",
      extraHttpConfig ? "",
    }:
    let
      dependencies = extraDependencies;
    in
    with getanix.build;
    mkDeriv {
      inherit name;
      out = mkDir {
        bin = mkDir {
          "run-${check.serviceName name}" = mkScript ''
            #!${pkgs.busybox}/bin/sh
            set -Cefu
            exec 3>&2 2>&1
            export PATH=${
              lib.makeBinPath [
                pkgs.netcat
                pkgs.busybox
                pkgs.openssl
                pkgs.nginx
              ]
            }
            datadir=${lib.escapeShellArg dataDir}
            mkdir -p -- "$datadir"
            cd       -- "$datadir"
            if [ ! -e certs/server.key ]; then
              echo "$(date +'%Y-%m-%d %H:%M:%S') Generating self-signed certificate ..."
              mkdir -p certs
              touch     certs/server.key
              chmod 600 certs/server.key
              openssl req -x509 -newkey rsa:4096 -sha256 -days 36500 -nodes \
                -keyout certs/server.key \
                -out    certs/server-with-intermediates.crt \
                -subj "/CN=localhost" \
                -addext "subjectAltName=DNS:localhost"
              echo "$(date +'%Y-%m-%d %H:%M:%S') Finished."
            fi
            rm -rf tmp
            mkdir  tmp
            {
              while ! nc -N 127.0.0.1 ${lib.escapeShellArg (toString checkPort)} </dev/null >/dev/null 2>/dev/null; do
                sleep 0.01
              done
              echo Ready >&3 # Notify readiness to the original stderr
            } &
            cd /
            exec nginx -e /dev/stdout -c ${out}/conf/nginx.conf
          '';
        };
        conf = mkDir {
          certs = mkSymlink "${dataDir}/certs";
          "fastcgi_params" = mkSymlink "${nginx}/conf/fastcgi_params";
          "mime.types" = mkSymlink "${nginx}/conf/mime.types";
          "nginx.conf" = mkFile ''
            daemon off;
            error_log stderr error;
            pid ${check.configString dataDir}/tmp/nginx.pid;
            ${extraMainConfig}
            http {
              client_body_temp_path ${check.configString dataDir}/tmp/body;
              fastcgi_temp_path     ${check.configString dataDir}/tmp/fastcgi;
              proxy_temp_path       ${check.configString dataDir}/tmp/proxy;
              scgi_temp_path        ${check.configString dataDir}/tmp/scgi;
              uwsgi_temp_path       ${check.configString dataDir}/tmp/uwsgi;
              access_log /dev/stdout;
              include mime.types;
              default_type application/octet-stream;
              ${extraHttpConfig}
            }
          '';
        };
        service = mkDir {
          "${check.serviceName name}" = mkDir {
            type = mkFile "longrun";
            notification-fd = mkFile "2";
            producer-for = mkFile "${check.serviceName name}@log";
            "dependencies.d" = mkDir (
              builtins.foldl' lib.attrsets.unionOfDisjoint { } (
                builtins.map (dependency: {
                  "${check.serviceName (lib.getName dependency)}" = mkFile "";
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
  mkPhpFpmService =
    {
      name ? "php-fpm",
      dataDir ? "/var/lib/${name}",
      php ? pkgs.php,
      extraGlobalConfig ? "",
      extraPoolConfig ? "",
      extraPaths ? [ ],
      extraDependencies ? [ ],
      extraInitCommands ? "",
    }:
    let
      paths = [
        pkgs.netcat
        pkgs.busybox
        php
      ] ++ extraPaths;
      dependencies = extraDependencies;
    in
    with getanix.build;
    mkDeriv {
      inherit name;
      out = mkDir {
        bin = mkDir {
          "run-${check.serviceName name}" = mkScript ''
            #!${pkgs.busybox}/bin/sh
            set -Cefu
            exec 3>&2 2>&1
            export PATH=${lib.makeBinPath paths}
            datadir=${lib.escapeShellArg dataDir}
            mkdir -p -- "$datadir"
            cd       -- "$datadir"
            rm -rf run
            mkdir  run
            mkdir -p sessions
            ${extraInitCommands}
            {
              while ! nc -UN run/php-fpm.sock </dev/null >/dev/null 2>/dev/null; do
                sleep 0.01
              done
              echo Ready >&3 # Notify readiness to the original stderr
            } &
            cd /
            exec php-fpm -y ${out}/conf/php-fpm.conf
          '';
        };
        run = mkSymlink "${dataDir}/run";
        conf = mkDir {
          "php-fpm.conf" = mkFile ''
            [global]
            daemonize = no
            error_log = /dev/stderr
            systemd_interval = 0
            ${extraGlobalConfig}
            [www]
            listen = ${check.configString dataDir}/run/php-fpm.sock
            catch_workers_output = yes
            slowlog = /dev/stderr
            clear_env = yes
            env[PATH] = $PATH
            php_admin_value[session.save_path] = ${check.configString dataDir}/sessions
            ${extraPoolConfig}
          '';
        };
        service = mkDir {
          "${check.serviceName name}" = mkDir {
            type = mkFile "longrun";
            notification-fd = mkFile "2";
            producer-for = mkFile "${check.serviceName name}@log";
            "dependencies.d" = mkDir (
              builtins.foldl' lib.attrsets.unionOfDisjoint { } (
                builtins.map (dependency: {
                  "${check.serviceName (lib.getName dependency)}" = mkFile "";
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
  mkPostgresqlService =
    {
      name ? "postgresql",
      dataDir ? "/var/lib/${name}",
      postgresql ? pkgs.postgresql,
      extraConfig ? "",
    }:
    let
      dependencies = [ ];
    in
    with getanix.build;
    mkDeriv {
      inherit name;
      out = mkDir {
        bin = mkDir {
          "run-${check.serviceName name}" = mkScript ''
            #!${pkgs.busybox}/bin/sh
            set -Cefu
            exec 3>&2 2>&1
            export PATH=${
              lib.makeBinPath [
                pkgs.busybox
                pkgs.openssl
                postgresql
              ]
            }
            datadir=${lib.escapeShellArg dataDir}
            mkdir -p -- "$datadir"
            cd       -- "$datadir"
            if [ ! -e certs/postgresql.key ]; then
              echo "$(date +'%Y-%m-%d %H:%M:%S') Generating self-signed certificate ..."
              mkdir -p certs
              touch     certs/postgresql.key
              chmod 600 certs/postgresql.key
              openssl req -x509 -newkey rsa:4096 -sha256 -days 36500 -nodes \
                -keyout certs/postgresql.key \
                -out    certs/postgresql.crt \
                -subj "/CN=localhost" \
                -addext "subjectAltName=DNS:localhost"
              echo "$(date +'%Y-%m-%d %H:%M:%S') PostgreSQL certificate generated."
            fi
            if [ ! -e data ]; then
              initdb -D data -E UTF-8 -A peer
            fi
            ln -sf ${out}/conf/postgresql.conf data/
            ln -sf ${out}/conf/pg_hba.conf     data/
            rm -f data/postmaster.pid
            rm -rf run
            mkdir  run
            mkdir  run/postgresql
            {
              cd run/postgresql
              while ! pg_isready -h "$(pwd)" -p "$(find . -type s | cut -d. -f5)" >/dev/null; do
                sleep 0.01
              done
              echo Ready >&3 # Notify readiness to the original stderr
            } &
            cd /
            exec postgres -D "$datadir"/data
          '';
        };
        run = mkSymlink "${dataDir}/run";
        conf = mkDir {
          "postgresql.conf" = mkFile ''
            unix_socket_directories = '${check.configString dataDir}/run/postgresql'
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
        service = mkDir {
          "${check.serviceName name}" = mkDir {
            type = mkFile "longrun";
            notification-fd = mkFile "2";
            producer-for = mkFile "${check.serviceName name}@log";
            "dependencies.d" = mkDir (
              builtins.foldl' lib.attrsets.unionOfDisjoint { } (
                builtins.concatMap (dependency: {
                  "${check.serviceName (lib.getName dependency)}" = mkFile "";
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

{
  inherit
    mkServiceManager
    mkNginxService
    mkPhpFpmService
    mkPostgresqlService
    ;
}
