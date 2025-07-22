# SPDX-FileCopyrightText: © 2025 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs, getanix }:

let
  inherit (pkgs) lib;
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

{
  inherit bubblewrapStaticWithForwardSignals;
}
