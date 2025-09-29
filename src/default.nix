# SPDX-FileCopyrightText: © 2024 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs }:
let
  getanix = {
    attrsets = import ./attrsets.nix { inherit pkgs getanix; };
    build = import ./build.nix { inherit pkgs getanix; };
    closure = import ./closure.nix { inherit pkgs getanix; };
    sandbox = import ./sandbox.nix { inherit pkgs getanix; };
    service = import ./service.nix { inherit pkgs getanix; };
    strings = import ./strings.nix { inherit pkgs getanix; };

    legacy = import ./legacy.nix { inherit pkgs getanix; };
  };
in
getanix
