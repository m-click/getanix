# SPDX-FileCopyrightText: © 2025 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs, getanix }:

let
  inherit (pkgs) lib;
in

let
  ensureSuffix = suffix: s: if s == "" || lib.hasSuffix s "\n" then s else s + "\n";
in

let
  mapLines =
    indent: list: f:
    lib.concatMapStringsSep "\n" (
      elem: indent + builtins.replaceStrings [ "\n" ] [ "\n${indent}" ] (lib.removeSuffix "\n" (f elem))
    ) list;
in

{
  inherit ensureSuffix mapLines;
}
