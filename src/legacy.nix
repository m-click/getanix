# SPDX-FileCopyrightText: © 2024 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{
  pkgs ?
    import
      (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/refs/tags/24.05.tar.gz";
        sha256 = "1lr1h35prqkd1mkmzriwlpvxcb34kmhc9dnr48gkm8hh089hifmx";
      })
      {
        config = { };
        overlays = [ ];
      },
  getanix,
}:

let
  staticBubblewrap = pkgs.pkgsStatic.bubblewrap;
  hosts = pkgs.writeText "hosts" ''
    127.0.0.1 localhost
    ::1       localhost
  '';
  cacert = pkgs.cacert;
  bash = pkgs.bash;
  bintools = pkgs.bintools;
  coreutils = pkgs.coreutils;
  findutils = pkgs.findutils;
  fontconfigOut = pkgs.fontconfig.out;
  fswatch = pkgs.fswatch;
  getClosure =
    packages:
    pkgs.lib.lists.remove "" (
      pkgs.lib.strings.splitString "\n" (builtins.readFile (pkgs.writeClosure packages))
    );
  symlinkJoinSubdirs =
    packages: subdir:
    pkgs.symlinkJoin {
      name = subdir;
      paths = builtins.filter builtins.pathExists (
        builtins.map (package: "${package}/${subdir}") packages
      );
    };
  mkPortableEnv =
    {
      user ? "sandbox",
      group ? user,
      uid ? 1000,
      gid ? uid,
      packages,
    }:
    assert builtins.isInt uid;
    assert builtins.isInt gid;
    let
      passwdFile = pkgs.writeText "passwd" ''
        ${user}:x:${toString uid}:${toString gid}:,,,:/:/sbin/nologin
      '';
      groupFile = pkgs.writeText "group" ''
        ${group}:x:${toString gid}:
      '';
      packagesClosure = getClosure packages;
      binDir = symlinkJoinSubdirs packages "bin";
      emacsDir = symlinkJoinSubdirs packagesClosure "share/emacs";
      emacsVersionLispDir =
        pkgs.lib.lists.findSingle pkgs.lib.filesystem.pathIsDirectory "" "error-multiple-emacs-versions"
          (pkgs.lib.mapAttrsToList (name: type: "${emacsDir}/${name}/lisp") (builtins.readDir emacsDir));
      emacsSiteLispDir =
        if pkgs.lib.filesystem.pathIsDirectory "${emacsDir}/site-lisp" then "${emacsDir}/site-lisp" else "";
      emacsLoadPathOrEmpty = builtins.concatStringsSep ":" (
        builtins.filter (pathEntry: pathEntry != "") [
          emacsVersionLispDir
          emacsSiteLispDir
        ]
      );
      fontsDir = symlinkJoinSubdirs packagesClosure "share/fonts";
      fontsConf = pkgs.writeText "fonts.conf" (
        if builtins.readDir fontsDir == { } then
          ""
        else
          ''
            <fontconfig>
              <description>Environment configuration file</description>
              <dir>${fontsDir}</dir>
              <include>${fontconfigOut}/etc/fonts/fonts.conf</include>
            </fontconfig>
          ''
      );
      libDir = symlinkJoinSubdirs packagesClosure "lib";
      ocamlSiteLibDirOrEmpty =
        pkgs.lib.lists.findSingle pkgs.lib.filesystem.pathIsDirectory "" "error-multiple-ocaml-versions"
          (
            pkgs.lib.mapAttrsToList (name: type: "${libDir}/ocaml/${name}/site-lib") (
              if pkgs.lib.filesystem.pathIsDirectory "${libDir}/ocaml" then
                builtins.readDir "${libDir}/ocaml"
              else
                { }
            )
          );
    in
    pkgs.writeScript "env" ''
      #!/bin/sh
      set -eu
      if [ "$#" = 0 ]; then
        echo "Usage: $0 COMMAND ARGS..." >&2
        exit 1
      fi
      basedir=$(realpath -- "$(dirname -- "$(realpath -- "$0")")/../..")
      mkdir -p -- "$basedir/homedir"
      mkdir -p -- "$basedir/run"
      mkdir -p -- "$basedir/tmp"
      mkdir -p -- "$basedir/var"
      exec "$basedir${staticBubblewrap}/bin/bwrap" \
        --unshare-all \
        --share-net \
        --clearenv \
        --forward-signals \
        --die-with-parent \
        --uid ${toString uid} \
        --gid ${toString gid} \
        --dev /dev \
        --bind /dev/log /dev/log \
        --proc /proc \
        --bind "$basedir/nix" /nix \
        --bind "$basedir/homedir" /homedir \
        --bind "$basedir/run" /run \
        --bind "$basedir/tmp" /tmp \
        --bind "$basedir/var" /var \
        --symlink usr/bin /bin \
        --symlink ${binDir} /usr/bin \
        --symlink ${hosts} /etc/hosts \
        --symlink ${passwdFile} /etc/passwd \
        --symlink ${groupFile} /etc/group \
        --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
        --bind . "$(pwd)" \
        --remount-ro / \
        --setenv DISPLAY "''${DISPLAY:-}" \
        --setenv EMACSLOADPATH '${emacsLoadPathOrEmpty}' \
        --setenv FONTCONFIG_FILE ${fontsConf} \
        --setenv HOME /homedir \
        --setenv LIBRARY_PATH ${libDir} \
        --setenv NIXPKGS_ALLOW_INSECURE "''${NIXPKGS_ALLOW_INSECURE:-0}" \
        --setenv NIX_SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt \
        --setenv OCAMLPATH '${ocamlSiteLibDirOrEmpty}' \
        --setenv PATH /usr/bin \
        --setenv TERM "''${TERM:-}" \
        -- \
        ${bash}/bin/sh -euc '
          case "$(${coreutils}/bin/basename -- "$2")" in
            nix|nix-*)
              echo "$0: [getanix] Recognized Nix command, enabling convenience features." >&2
              if [ -e /nix/var/nix/db-refs ]; then
                echo "$0: [getanix] Initializing Nix database ..." >&2
                if [ -e /nix/var/nix/db ]; then
                  echo "Error: Nix database already exists." >&2
                  exit 1
                fi
                "$(${coreutils}/bin/dirname -- "$(command -v "$2")")/nix-store" --register-validity </nix/var/nix/db-refs
                ${coreutils}/bin/rm -f /nix/var/nix/db-refs
                echo "$0: [getanix] Nix database successfully initialized." >&2
              fi
              ${fswatch}/bin/fswatch -l 0.1 -m inotify_monitor -0 --event MovedTo . \
              | ${findutils}/bin/xargs -0 -I {} -- ${bash}/bin/sh -euc '"'"'
                if [ -s "$2" ] && [ "$(${coreutils}/bin/readlink -- "$2" | ${coreutils}/bin/head -c 1)" = / ]; then
                  echo "$0: [getanix] Adjusting symlink: $2" >&2
                  ${coreutils}/bin/ln -rsfT -- "$1$(${coreutils}/bin/readlink -- "$2")" "$2"
                fi
              '"'"' "$0" "$1" {} &
              ;;
            *) ;;
          esac
          shift
          exec "$@"
        ' \
        "$0" \
        "$basedir" \
        "$@"
    '';
  mkPortableEnvTarCompressed =
    {
      env,
      compressionCommand,
      suffix,
      nativeBuildInputs,
    }:
    let
      closure = pkgs.writeClosure [ env ];
    in
    pkgs.runCommand "env.${suffix}"
      {
        inherit nativeBuildInputs;
        exportReferencesGraph = [
          "refs"
          env
        ];
      }
      ''
        mkdir -p tmp/.envroot/nix/store
        cat ${closure} | while read dep; do
          cp -a $dep tmp/.envroot/nix/store/
        done
        mkdir -p tmp/.envroot/nix/var/nix
        cat refs >tmp/.envroot/nix/var/nix/db-refs
        ln -sf .envroot${env} tmp/env
        ./tmp/env nix-store --optimise
        chmod -R u+w tmp/.envroot/nix/store/.links
        rm -rf tmp/.envroot/nix/store/.links
        mkdir -p .envroot/nix
        mv tmp/.envroot/nix/store .envroot/nix/
        mv tmp/env ./
        mkdir -p .envroot/nix/var/nix
        cat refs >.envroot/nix/var/nix/db-refs
        tar c --sort=name --owner 0 --group 0 --numeric-owner --mtime=@1 -- .envroot env | ${compressionCommand} >$out
      '';
  mkPortableEnvTgz =
    { env }:
    mkPortableEnvTarCompressed {
      inherit env;
      compressionCommand = "gzip -9nv";
      suffix = "tgz";
      nativeBuildInputs = [ ];
    };
  mkPortableEnvTarZst =
    { env }:
    mkPortableEnvTarCompressed {
      inherit env;
      compressionCommand = "zstd --ultra -22v";
      suffix = "tar.zst";
      nativeBuildInputs = [ pkgs.zstd ];
    };
  bootstrapEnvTgz = mkPortableEnvTgz { env = mkPortableEnv { packages = [ pkgs.nix ]; }; };
in
{
  inherit
    bootstrapEnvTgz
    mkPortableEnv
    mkPortableEnvTgz
    mkPortableEnvTarZst
    ;
}
