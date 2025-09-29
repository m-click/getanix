# SPDX-FileCopyrightText: © 2025 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs, getanix }:

let
  inherit (pkgs) lib;
in

let
  mergeDisjointAttrSets = attrSetList: builtins.foldl' lib.attrsets.unionOfDisjoint { } attrSetList;
in

{
  inherit mergeDisjointAttrSets;
}
