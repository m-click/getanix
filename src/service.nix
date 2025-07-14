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
  checkReadyPort = port:
    ''${pkgs.netcat}/bin/nc -N -- 127.0.0.1 ${lib.escapeShellArg (toString port)}'';
in

let
  checkReadyUnixSocket = unixSocketFileName:
    ''${pkgs.netcat}/bin/nc -NU -- ${getanix.build.out}/run/${lib.escapeShellArg unixSocketFileName}'';
in

let
  mkService =
    {
      name,
      dataDir,
      runDir,
      dependencies,
      serviceCreatesDataDir,
      serviceCreatesAndCleansRunDir,
      externalReadinessCheck,
      initAndExecServiceWithStderrOnFd3,
      conf ? null,
    }:
    assert (externalReadinessCheck == null || !lib.hasInfix "\n" externalReadinessCheck);
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
            cd /
            ${lib.optionalString (!serviceCreatesDataDir) ''
              mkdir -p -- "$(readlink ${out}/data)"
            ''}
            ${lib.optionalString (!serviceCreatesAndCleansRunDir) ''
              mkdir -p -- "$(readlink ${out}/run)"
              find ${out}/run/ -mindepth 1 -xdev -delete
            ''}
            ${lib.optionalString (externalReadinessCheck != null) ''
              {
                sleep 0.01
                while ! ${externalReadinessCheck} </dev/null >/dev/null 2>/dev/null; do
                  sleep 0.01
                done
                echo Ready >&3 # Notify readiness to the original stderr
                exec 3<&-
              } &
            ''}
            ${initAndExecServiceWithStderrOnFd3}
          '';
        };
        conf = mkOptional (conf != null) conf;
        data = mkSymlink dataDir;
        run = mkSymlink runDir;
        service = mkDir {
          "${check.serviceName name}" = mkDir {
            type = mkFile "longrun";
            notification-fd = mkFile "3";
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
              exec ${out}/bin/run-${check.serviceName name} 2>&3
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
      runDir,
      mainService,
      extraServices ? [ ],
    }:
    let
      services = [ mainService ] ++ extraServices;
      serviceDirsOfAllServicesWithDependencies = builtins.filter lib.pathIsDirectory (
        builtins.map (drv: "${drv}/service") (getanix.closure.closureList services)
      );
    in
    with getanix.build;
    mkService {
      inherit name dataDir runDir;
      dependencies = [ ];
      serviceCreatesDataDir = false;
      serviceCreatesAndCleansRunDir = false;
      externalReadinessCheck = null;
      initAndExecServiceWithStderrOnFd3 = ''
        mkfifo  ${out}/run/initial-notification
        exec 4<>${out}/run/initial-notification
        exec 5< ${out}/run/initial-notification
        exec 6> ${out}/run/initial-notification
        exec 4<&-
        rm -f   ${out}/run/initial-notification
        mkdir   ${out}/run/scandir
        {
          exec 6<&-
          read -r _INITIAL_NOTIFICATION <&5 >/dev/null
          # Workaround for https://github.com/skarnet/s6-rc/issues/10
          cp -Rp ${out}/conf/compiled ${out}/run/compiled
          chmod -R u+w ${out}/run/compiled
          ${pkgs.s6-rc}/bin/s6-rc-init \
            -c ${out}/run/compiled \
            -l ${out}/run/live \
            ${out}/run/scandir
          ${pkgs.s6-rc}/bin/s6-rc \
            -l ${out}/run/live \
            -u change \
            ${lib.escapeShellArg (check.serviceName (lib.getName mainService))}
          echo Ready >&3 # Notify readiness to the original stderr
          exec 3<&-
        } &
        exec 5<&-
        exec ${pkgs.s6}/bin/s6-svscan -d 6 ${out}/run/scandir
      '';
      conf = mkDir {
        compiled = mkCommandFragment ''${pkgs.s6-rc}/bin/s6-rc-compile "$outSubPath" ${lib.concatStringsSep " " serviceDirsOfAllServicesWithDependencies}'';
      };
    };
in

let
  mkNginxService =
    {
      name ? "nginx",
      dataDir,
      runDir,
      nginx ? pkgs.nginx,
      extraDependencies ? [ ],
      mainPort,
      selfSignedCertOptions ? "ed448 -days 36500",
      extraMainConfig ? null,
      extraHttpConfig,
    }:
    assert builtins.isInt mainPort;
    with getanix.build;
    mkService {
      inherit name dataDir runDir;
      dependencies = extraDependencies;
      serviceCreatesDataDir = false;
      serviceCreatesAndCleansRunDir = false;
      externalReadinessCheck = checkReadyPort mainPort;
      initAndExecServiceWithStderrOnFd3 = ''
        if [ ! -e   ${out}/data/certs/server.key ]; then
          echo "$(date +'%Y-%m-%d %H:%M:%S') Generating self-signed certificate ..."
          mkdir -p  ${out}/data/certs
          touch     ${out}/data/certs/server.key.tmp
          chmod 600 ${out}/data/certs/server.key.tmp
          ${pkgs.openssl}/bin/openssl req -x509 -newkey ${selfSignedCertOptions} -nodes \
            -keyout ${out}/data/certs/server.key.tmp \
            -out    ${out}/data/certs/server-with-intermediates.crt.tmp \
            -subj "/CN=localhost" \
            -addext "subjectAltName=DNS:localhost"
          mv        ${out}/data/certs/server.key.tmp \
                    ${out}/data/certs/server.key
          mv        ${out}/data/certs/server-with-intermediates.crt.tmp \
                    ${out}/data/certs/server-with-intermediates.crt
          echo "$(date +'%Y-%m-%d %H:%M:%S') Finished."
        fi
        exec ${nginx}/bin/nginx -e /dev/stdout -c ${out}/conf/nginx.conf
      '';
      conf = mkDir {
        certs = mkSymlink "${out}/data/certs";
        "fastcgi_params" = mkSymlink "${nginx}/conf/fastcgi_params";
        "mime.types" = mkSymlink "${nginx}/conf/mime.types";
        "nginx.conf" = mkFile ''
          daemon off;
          error_log stderr error;
          pid ${out}/run/nginx.pid;
          ${lib.optionalString (extraMainConfig != null) extraMainConfig}
          http {
            client_body_temp_path ${out}/data/client_body_temp;
            fastcgi_temp_path     ${out}/data/fastcgi_temp;
            proxy_temp_path       ${out}/data/proxy_temp;
            scgi_temp_path        ${out}/data/scgi_temp;
            uwsgi_temp_path       ${out}/data/uwsgi_temp;
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
      runDir,
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
      inherit name dataDir runDir;
      dependencies = extraDependencies;
      serviceCreatesDataDir = false;
      serviceCreatesAndCleansRunDir = false;
      externalReadinessCheck = checkReadyUnixSocket "php-fpm.sock";
      initAndExecServiceWithStderrOnFd3 = ''
        mkdir -p ${out}/data/sessions
        ${extraInitCommands}
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
          php_admin_value[session.save_path] = ${out}/data/sessions
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
      runDir,
      postgresql ? pkgs.postgresql,
      selfSignedCertOptions ? "ed448 -days 36500",
      extraConfig ? "",
    }:
    with getanix.build;
    mkService {
      inherit name dataDir runDir;
      dependencies = [ ];
      serviceCreatesDataDir = true;
      serviceCreatesAndCleansRunDir = false;
      externalReadinessCheck =
        ''${postgresql}/bin/pg_isready -h ${out}/run -p "$(cd ${out}/run && find . -type s | cut -d. -f5)"'';
      initAndExecServiceWithStderrOnFd3 = ''
        if [ ! -e ${lib.escapeShellArg dataDir} ]; then
          ${postgresql}/bin/initdb -D ${lib.escapeShellArg dataDir} -E UTF-8 -A peer
        fi
        if [ ! -e   ${lib.escapeShellArg dataDir}/certs/postgresql.key ]; then
          echo "$(date +'%Y-%m-%d %H:%M:%S') Generating self-signed certificate ..."
          mkdir -p  ${lib.escapeShellArg dataDir}/certs
          touch     ${lib.escapeShellArg dataDir}/certs/postgresql.key.tmp
          chmod 600 ${lib.escapeShellArg dataDir}/certs/postgresql.key.tmp
          ${pkgs.openssl}/bin/openssl req -x509 -newkey ${selfSignedCertOptions} -nodes \
            -keyout ${lib.escapeShellArg dataDir}/certs/postgresql.key.tmp \
            -out    ${lib.escapeShellArg dataDir}/certs/postgresql.crt.tmp \
            -subj "/CN=localhost" \
            -addext "subjectAltName=DNS:localhost"
          mv        ${lib.escapeShellArg dataDir}/certs/postgresql.key.tmp \
                    ${lib.escapeShellArg dataDir}/certs/postgresql.key
          mv        ${lib.escapeShellArg dataDir}/certs/postgresql.crt.tmp \
                    ${lib.escapeShellArg dataDir}/certs/postgresql.crt
          echo "$(date +'%Y-%m-%d %H:%M:%S') PostgreSQL certificate generated."
        fi
        ln -sf ${out}/conf/postgresql.conf ${lib.escapeShellArg dataDir}/
        ln -sf ${out}/conf/pg_hba.conf     ${lib.escapeShellArg dataDir}/
        rm -f ${lib.escapeShellArg dataDir}/postmaster.pid
        exec ${postgresql}/bin/postgres -D ${lib.escapeShellArg dataDir}
      '';
      conf = mkDir {
        "postgresql.conf" = mkFile ''
          unix_socket_directories = '${out}/run'
          ssl = on
          ssl_cert_file = '${out}/data/certs/postgresql.crt'
          ssl_key_file  = '${out}/data/certs/postgresql.key'
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
    checkReadyPort
    checkReadyUnixSocket
    mkService
    mkServiceManager
    mkNginxService
    mkPhpFpmService
    mkPostgresqlService
    ;
}
