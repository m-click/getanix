# SPDX-FileCopyrightText: © 2025 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs, getanix }:

let
  inherit (pkgs) lib;
in

let
  defaultBubblewrapStatic = pkgs.pkgsStatic.bubblewrap;
  defaultForwardSignals = false;
  defaultNixSslCertFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
in

let
  bubblewrapStaticWithForwardSignals = pkgs.pkgsStatic.bubblewrap.overrideAttrs (old: {
    preInstallPhases = (old.preInstallPhases or [ ]) ++ [ "extraCheckPhase" ];
    extraCheckPhase = ''
      runHook preExtraCheckPhase
      echo 'Checking for option "--forward-signals" ...'
      ./bwrap --help | grep -- '--forward-signals'
      runHook postExtraCheckPhase
    '';
    patches = (old.patches or [ ]) ++ [
      (pkgs.fetchpatch {
        # Provide --forward-signals
        name = "bubblewrap-pr-586";
        url = "https://github.com/containers/bubblewrap/pull/586.diff";
        hash = "sha256-Tc/COQwzKNt1VEthWG1nF8Qy1SfzgWdW7bWAy9VTTB4=";
      })
    ];
  });
in

let
  adjustNixSymlinks =
    with getanix.build;
    mkDeriv {
      name = "adjust-nix-symlinks";
      out = mkScript ''
        #!/bin/sh
        set -Cefu
        if [ $# = 0 ]; then
          echo "Usage: $0 SYMLINK ..." >&2
          exit 1
        fi
        nixstoredir=$(dirname -- "$(readlink -f -- "$0")")
        if [ "$nixstoredir" = /nix/store ]; then
          echo "Error: Unable to detect the actual nix store, perhaps running inside the chnixroot sandbox."
          exit 0
        fi
        for symlink in "$@"; do
          relpath=$(readlink -v -- "$symlink" | sed -n s,^/nix/store/,,p)
          if [ -z "$relpath" ]; then
            echo "Error: Not a symlink that points into /nix/store: $symlink" >&2
            exit 1
          fi
          ln -sfrvT -- "$nixstoredir/$relpath" "$symlink"
        done
      '';
    };
in

let
  mkChNixRootWrapper =
    {
      bubblewrapStatic ? defaultBubblewrapStatic,
      forwardSignals ? defaultForwardSignals,
      nixSslCertFile ? defaultNixSslCertFile,
    }:
    path:
    getanix.build.mkScript ''
      #!/bin/sh
      set -Cefu
      export NIX_SSL_CERT_FILE=''${NIX_SSL_CERT_FILE:-${lib.escapeShellArg nixSslCertFile}}
      nixdir=$(readlink -f -- "$(dirname -- "$(readlink -f -- "$0")")/../../..")
      if [ "$nixdir" = /nix ]; then
        exec ${lib.escapeShellArg path} "$@"
      fi
      exec 3<&0
      find \
        / \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name nix \
        -exec printf -- '--dev-bind\000' \; \
        -print0 \
        -print0 \
      | exec "$nixdir"/${lib.escapeShellArg (lib.removePrefix "/nix/" bubblewrapStatic)}/bin/bwrap \
        --die-with-parent \
        ${lib.optionalString forwardSignals "--forward-signals "}\
        --args 4 \
        --bind "$nixdir" /nix \
        --remount-ro / \
        -- \
        ${lib.escapeShellArg path} "$@" \
        4<&0 <&3
    '';
in

let
  mkChNixRootEnv =
    {
      name ? "chnixroot-env",
      binSymlinkPaths ? [ ],
      binSandboxPaths ? [ ],
      bubblewrapStatic ? defaultBubblewrapStatic,
      forwardSignals ? defaultForwardSignals,
      nixSslCertFile ? defaultNixSslCertFile,
    }:
    with getanix.build;
    mkDeriv {
      inherit name;
      out = mkDir {
        bin = mkDir (
          getanix.attrsets.mergeDisjointAttrSets [
            (getanix.attrsets.mapBinAttrSetOfPaths binSymlinkPaths mkRelSymlink)
            (getanix.attrsets.mapBinAttrSetOfPaths binSandboxPaths (mkChNixRootWrapper {
              inherit bubblewrapStatic forwardSignals nixSslCertFile;
            }))
          ]
        );
      };
    };
in

let
  packChNixRootEnv =
    {
      name ? "chnixroot-env.tgz",
      outputHash,
      nix ? pkgs.nix,
      bubblewrapStatic ? defaultBubblewrapStatic,
      forwardSignals ? defaultForwardSignals,
      nixSslCertFile ? defaultNixSslCertFile,
    }:
    let
      chNixRootEnv = mkChNixRootEnv {
        binSymlinkPaths = [ adjustNixSymlinks ];
        binSandboxPaths = [ nix ];
        inherit bubblewrapStatic forwardSignals nixSslCertFile;
      };
      chNixRootEnvClosure = pkgs.writeClosure [ chNixRootEnv ];
      derivationArgs = {
        exportReferencesGraph = [
          "refs"
          chNixRootEnv
        ];
        inherit outputHash;
      };
      buildCommand = ''
        install -d nixe/nix/store
        xargs -a ${chNixRootEnvClosure} cp -at nixe/nix/store
        chmod -R a=rX nixe/nix/store
        chmod 755 nixe/nix/store
        ln -s ${lib.removePrefix "/" chNixRootEnv}/bin nixe/bin
        install -D /dev/stdin tmp/libfaketimeMT.so.1 <${pkgs.libfaketime}/lib/libfaketimeMT.so.1
        FAKETIME_FMT=%s FAKETIME=1 LD_PRELOAD=$(pwd)/tmp/libfaketimeMT.so.1 ./nixe/bin/nix-store --register-validity <refs
        ./nixe/bin/nix-store --optimise
        chmod -R u+w nixe/nix/store/.links
        rm -rf nixe/nix/store/.links
        rm -f nixe/nix/var/nix/db/big-lock
        rm -f nixe/nix/var/nix/gc.lock
        tar c --sort=name --owner 0 --group 0 --numeric-owner --mtime=@1 nixe | gzip -9n >$out
      '';
    in
    pkgs.runCommand name derivationArgs buildCommand;
in

{
  inherit
    adjustNixSymlinks
    bubblewrapStaticWithForwardSignals
    mkChNixRootWrapper
    mkChNixRootEnv
    packChNixRootEnv
    ;
}
