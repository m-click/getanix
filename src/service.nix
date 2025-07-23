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
  simpleReadinessCheck =
    { sock, port }:
    assert (sock != null || port != null);
    if sock != null then
      ''${pkgs.netcat}/bin/nc -NU -- ${lib.escapeShellArg sock}''
    else
      ''${pkgs.netcat}/bin/nc -N -- 127.0.0.1 ${lib.escapeShellArg port}'';
in

let
  mkService =
    {
      name,
      data,
      run,
      sockFileName,
      port,
      spec,
    }:
    assert (port == null || builtins.isInt port);
    let
      portAsInt = port;
    in
    let
      port = toString portAsInt;
      sock = if sockFileName == null then null else "${run}/${sockFileName}";
      mkServiceFromSpec =
        {
          dependencies,
          serviceCreatesDataDir,
          serviceCreatesAndCleansRunDir,
          passthru ? { },
          externalReadinessCheck,
          initAndExecServiceWithStderrOnFd3,
          conf ? null,
        }:
        let
          externalReadinessCheckCommand =
            if externalReadinessCheck == null then null else externalReadinessCheck { inherit sock port; };
        in
        with getanix.build;
        mkDeriv {
          name = check.serviceName name;
          passthru = lib.attrsets.unionOfDisjoint passthru { inherit sock port; };
          out = mkDir {
            bin = mkDir {
              "run-${check.serviceName name}" = mkScript ''
                #!${pkgs.busybox}/bin/sh
                set -Cefu
                exec 3>&2 2>&1
                export PATH=${lib.makeBinPath [ pkgs.busybox ]}
                cd /
                ${lib.optionalString (!serviceCreatesDataDir) ''
                  mkdir -p -- ${lib.escapeShellArg data}
                ''}
                ${lib.optionalString (!serviceCreatesAndCleansRunDir) ''
                  mkdir -p -- ${lib.escapeShellArg run}
                  find ${lib.escapeShellArg run}/ -mindepth 1 -xdev -delete
                ''}
                ${lib.optionalString (externalReadinessCheckCommand != null) ''
                  {
                    sleep 0.01
                    while ! ${
                      assert (!lib.hasInfix "\n" externalReadinessCheckCommand);
                      externalReadinessCheckCommand
                    } </dev/null >/dev/null 2>/dev/null; do
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
    mkServiceFromSpec (spec {
      inherit
        data
        run
        sock
        port
        ;
    });
in

let
  mkServiceManager =
    {
      name ? "services",
      data,
      run,
      mainService,
      extraServices ? [ ],
    }:
    mkService {
      inherit name data run;
      sockFileName = null;
      port = null;
      spec =
        {
          data,
          run,
          sock,
          port,
        }:
        let
          services = [ mainService ] ++ extraServices;
          serviceDirsOfAllServicesWithDependencies = builtins.filter lib.pathIsDirectory (
            builtins.map (drv: "${drv}/service") (getanix.closure.closureList services)
          );
        in
        with getanix.build;
        {
          dependencies = [ ];
          serviceCreatesDataDir = false;
          serviceCreatesAndCleansRunDir = false;
          externalReadinessCheck = null;
          initAndExecServiceWithStderrOnFd3 = ''
            mkfifo  ${lib.escapeShellArg run}/initial-notification
            exec 4<>${lib.escapeShellArg run}/initial-notification
            exec 5< ${lib.escapeShellArg run}/initial-notification
            exec 6> ${lib.escapeShellArg run}/initial-notification
            exec 4<&-
            rm -f   ${lib.escapeShellArg run}/initial-notification
            mkdir   ${lib.escapeShellArg run}/scandir
            {
              exec 6<&-
              read -r _INITIAL_NOTIFICATION <&5 >/dev/null
              # Workaround for https://github.com/skarnet/s6-rc/issues/10
              cp -Rp ${out}/conf/compiled ${lib.escapeShellArg run}/compiled
              chmod -R u+w ${lib.escapeShellArg run}/compiled
              ${pkgs.s6-rc}/bin/s6-rc-init \
                -c ${lib.escapeShellArg run}/compiled \
                -l ${lib.escapeShellArg run}/live \
                ${lib.escapeShellArg run}/scandir
              ${pkgs.s6-rc}/bin/s6-rc \
                -l ${lib.escapeShellArg run}/live \
                -u change \
                ${lib.escapeShellArg (check.serviceName (lib.getName mainService))}
              echo Ready >&3 # Notify readiness to the original stderr
              exec 3<&-
            } &
            exec 5<&-
            exec ${pkgs.s6}/bin/s6-svscan -d 6 ${lib.escapeShellArg run}/scandir
          '';
          conf = mkDir {
            compiled = mkCommandFragment ''${pkgs.s6-rc}/bin/s6-rc-compile "$outSubPath" ${lib.concatStringsSep " " serviceDirsOfAllServicesWithDependencies}'';
          };
        };
    };
in

let
  mkNginxService =
    {
      name ? "nginx",
      data,
      run,
      port,
      nginx ? pkgs.nginx,
      extraDependencies ? [ ],
      selfSignedCertOptions ? "ed448 -days 36500",
      extraMainConfig ? null,
      extraHttpConfig,
    }:
    mkService {
      inherit name data run;
      sockFileName = null;
      inherit port;
      spec =
        {
          data,
          run,
          sock,
          port,
        }:
        let
          certs = "${data}/certs";
        in
        with getanix.build;
        {
          dependencies = extraDependencies;
          serviceCreatesDataDir = false;
          serviceCreatesAndCleansRunDir = false;
          externalReadinessCheck = simpleReadinessCheck;
          initAndExecServiceWithStderrOnFd3 = ''
            if [ ! -e   ${lib.escapeShellArg certs}/server.key ]; then
              echo "$(date +'%Y-%m-%d %H:%M:%S') Generating self-signed certificate ..."
              mkdir -p  ${lib.escapeShellArg certs}
              touch     ${lib.escapeShellArg certs}/server.key.tmp
              chmod 600 ${lib.escapeShellArg certs}/server.key.tmp
              ${pkgs.openssl}/bin/openssl req -x509 -newkey ${selfSignedCertOptions} -nodes \
                -keyout ${lib.escapeShellArg certs}/server.key.tmp \
                -out    ${lib.escapeShellArg certs}/server-with-intermediates.crt.tmp \
                -subj "/CN=localhost" \
                -addext "subjectAltName=DNS:localhost"
              mv        ${lib.escapeShellArg certs}/server.key.tmp \
                        ${lib.escapeShellArg certs}/server.key
              mv        ${lib.escapeShellArg certs}/server-with-intermediates.crt.tmp \
                        ${lib.escapeShellArg certs}/server-with-intermediates.crt
              echo "$(date +'%Y-%m-%d %H:%M:%S') Finished."
            fi
            echo "Listening on port ${port}"
            exec ${nginx}/bin/nginx -e /dev/stdout -c ${out}/conf/nginx.conf
          '';
          conf = mkDir {
            "nginx.conf" = mkFile ''
              daemon off;
              error_log stderr notice;
              pid "${run}/nginx.pid";
              ${lib.optionalString (extraMainConfig != null) extraMainConfig}
              http {
                client_body_temp_path "${data}/client_body_temp";
                fastcgi_temp_path     "${data}/fastcgi_temp";
                proxy_temp_path       "${data}/proxy_temp";
                scgi_temp_path        "${data}/scgi_temp";
                uwsgi_temp_path       "${data}/uwsgi_temp";
                access_log /dev/stdout;
                include "${nginx}/conf/mime.types";
                default_type application/octet-stream;
                ${extraHttpConfig {
                  inherit certs port;
                  fastcgi_params = "${nginx}/conf/fastcgi_params";
                }}
              }
            '';
          };
        };
    };
in

let
  mkPhpFpmService =
    {
      name ? "php-fpm",
      data,
      run,
      php ? pkgs.php,
      extraGlobalConfig ? "",
      extraPoolConfig ? "",
      extraPaths ? [ ],
      extraDependencies ? [ ],
      extraInitCommands ? "",
    }:
    mkService {
      inherit name data run;
      sockFileName = "php-fpm.sock";
      port = null;
      spec =
        {
          data,
          run,
          sock,
          port,
        }:
        let
          paths = extraPaths ++ [
            pkgs.busybox
            php
          ];
        in
        with getanix.build;
        {
          dependencies = extraDependencies;
          serviceCreatesDataDir = false;
          serviceCreatesAndCleansRunDir = false;
          externalReadinessCheck = simpleReadinessCheck;
          initAndExecServiceWithStderrOnFd3 = ''
            mkdir -p ${lib.escapeShellArg data}/sessions
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
              listen = ${sock}
              catch_workers_output = yes
              slowlog = /dev/stderr
              clear_env = yes
              env[PATH] = ${lib.makeBinPath paths}
              php_admin_value[session.save_path] = ${data}/sessions
              ${extraPoolConfig}
            '';
          };
        };
    };
in

let
  mkPostgresqlService =
    {
      name ? "postgresql",
      data,
      run,
      port ? 5432,
      postgresql ? pkgs.postgresql,
      selfSignedCertOptions ? "ed448 -days 36500",
      extraConfig ? "",
    }:
    mkService {
      inherit name data run;
      sockFileName = ".s.PGSQL.${toString port}";
      inherit port;
      spec =
        {
          data,
          run,
          sock,
          port,
        }:
        let
          certs = "${data}/certs";
        in
        with getanix.build;
        {
          dependencies = [ ];
          serviceCreatesDataDir = true;
          serviceCreatesAndCleansRunDir = false;
          passthru = {
            pghost = run;
          };
          externalReadinessCheck =
            { sock, port }:
            ''${postgresql}/bin/pg_isready -h ${lib.escapeShellArg run} -p ${lib.escapeShellArg port}'';
          initAndExecServiceWithStderrOnFd3 = ''
            if [ ! -e ${lib.escapeShellArg data} ]; then
              ${postgresql}/bin/initdb -D ${lib.escapeShellArg data} -E UTF-8 -A peer
            fi
            if [ ! -e   ${lib.escapeShellArg certs}/postgresql.key ]; then
              echo "$(date +'%Y-%m-%d %H:%M:%S') Generating self-signed certificate ..."
              mkdir -p  ${lib.escapeShellArg certs}
              touch     ${lib.escapeShellArg certs}/postgresql.key.tmp
              chmod 600 ${lib.escapeShellArg certs}/postgresql.key.tmp
              ${pkgs.openssl}/bin/openssl req -x509 -newkey ${selfSignedCertOptions} -nodes \
                -keyout ${lib.escapeShellArg certs}/postgresql.key.tmp \
                -out    ${lib.escapeShellArg certs}/postgresql.crt.tmp \
                -subj "/CN=localhost" \
                -addext "subjectAltName=DNS:localhost"
              mv        ${lib.escapeShellArg certs}/postgresql.key.tmp \
                        ${lib.escapeShellArg certs}/postgresql.key
              mv        ${lib.escapeShellArg certs}/postgresql.crt.tmp \
                        ${lib.escapeShellArg certs}/postgresql.crt
              echo "$(date +'%Y-%m-%d %H:%M:%S') PostgreSQL certificate generated."
            fi
            ln -sf ${out}/conf/postgresql.conf ${lib.escapeShellArg data}/
            ln -sf ${out}/conf/pg_hba.conf     ${lib.escapeShellArg data}/
            rm -f ${lib.escapeShellArg data}/postmaster.pid
            exec ${postgresql}/bin/postgres -D ${lib.escapeShellArg data}
          '';
          conf = mkDir {
            "postgresql.conf" = mkFile ''
              unix_socket_directories = '${run}'
              port = ${port}
              ssl = on
              ssl_cert_file = '${certs}/postgresql.crt'
              ssl_key_file  = '${certs}/postgresql.key'
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
    };
in

{
  inherit
    simpleReadinessCheck
    mkService
    mkServiceManager
    mkNginxService
    mkPhpFpmService
    mkPostgresqlService
    ;
}
