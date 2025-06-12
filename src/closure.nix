# SPDX-FileCopyrightText: © 2025 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs, getanix }:

let
  inherit (pkgs) lib;
in

let
  closureList = paths: lib.splitString "\n" (lib.fileContents (pkgs.writeClosure paths));
in

let
  mapClosureLines =
    indent: paths: f:
    getanix.strings.mapLines indent (closureList paths) f;
in

{
  inherit closureList mapClosureLines;
}
