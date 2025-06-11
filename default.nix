# SPDX-FileCopyrightText: © 2024 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs }:
let
  getanix = {
    legacy = import src/legacy.nix { inherit pkgs getanix; };
  };
in
getanix
