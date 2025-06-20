# SPDX-FileCopyrightText: © 2024 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs }:
let
  getanix = {
    build = import src/build.nix { inherit pkgs getanix; };
    closure = import src/closure.nix { inherit pkgs getanix; };
    strings = import src/strings.nix { inherit pkgs getanix; };

    legacy = import src/legacy.nix { inherit pkgs getanix; };
  };
in
getanix
