# SPDX-FileCopyrightText: © 2025 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs, getanix }:

let
  inherit (pkgs) lib;
in

let
  mergeDisjointAttrSets = attrSetList: builtins.foldl' lib.attrsets.unionOfDisjoint { } attrSetList;
in

let
  binAttrSetOfPath =
    path:
    if lib.pathIsDirectory path then
      let
        binDir = "${if lib.isDerivation path then lib.getBin path else path}/bin";
      in
      lib.concatMapAttrs (
        name: fileType: if lib.hasPrefix "." name then { } else { ${name} = "${binDir}/${name}"; }
      ) (builtins.readDir binDir)
    else if lib.isDerivation path then
      { ${lib.getName path} = path; }
    else
      { ${builtins.unsafeDiscardStringContext (baseNameOf path)} = path; };
in

let
  binAttrSetOfPaths = paths: mergeDisjointAttrSets (builtins.map binAttrSetOfPath paths);
in

let
  mapBinAttrSetOfPaths = paths: f: builtins.mapAttrs (name: path: f path) (binAttrSetOfPaths paths);
in

{
  inherit
    mergeDisjointAttrSets
    binAttrSetOfPath
    binAttrSetOfPaths
    mapBinAttrSetOfPaths
    ;
}
