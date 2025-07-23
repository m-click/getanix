# SPDX-FileCopyrightText: © 2025 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs, getanix }:

let
  inherit (pkgs) lib;
in

let
  checkRegex =
    name: regex: s:
    if builtins.match regex s == null then
      abort "Invalid ${name}: ${lib.strings.escapeNixString s} (does not match regex ${lib.strings.escapeNixString regex})"
    else
      s;
in

let
  createReplacementMarker =
    namespace: name: "/replace-with-${name}-${builtins.hashString "sha256" "${namespace}.${name}"}";
in

let
  mapLines =
    indent: list: f:
    lib.concatMapStringsSep "\n" (
      elem: indent + builtins.replaceStrings [ "\n" ] [ "\n${indent}" ] (lib.removeSuffix "\n" (f elem))
    ) list;
in

{
  inherit checkRegex createReplacementMarker mapLines;
}
