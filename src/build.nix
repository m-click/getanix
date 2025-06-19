# SPDX-FileCopyrightText: © 2025 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

{ pkgs, getanix }:

let
  inherit (pkgs) lib;
in

let
  fragmentType = "getanix.build.fragment";
in

let
  isValidPathComponent =
    name:
    (builtins.match ''[ -~]+'' name != null)
    && !(builtins.match ''.*[\/:].*'' name != null)
    && !(builtins.match ''.*[.]'' name != null)
    && !(builtins.match ''.*[.][.].*'' name != null);
in

let
  isFragment = arg: builtins.isAttrs arg && arg ? type && arg.type == fragmentType;
in

let
  mkFragment = buildCommand: dataArgs: {
    type = fragmentType;
    normalizedBuildCommand = getanix.strings.ensureSuffix "\n" buildCommand;
    inherit dataArgs;
  };
in

let
  emptyFragment = mkFragment "" { };
in

let
  concatFragments =
    fragments:
    assert builtins.all isFragment fragments;
    let
      buildCommand = lib.concatMapStrings (fragment: fragment.normalizedBuildCommand) fragments;
      dataArgs = lib.mergeAttrsList (builtins.map (fragment: fragment.dataArgs) fragments);
    in
    mkFragment buildCommand dataArgs;
in

let
  forEachAttrToFragment = attrs: f: concatFragments (lib.mapAttrsToList f attrs);
in

let
  mkDataPath =
    data:
    let
      hash = builtins.hashString "sha256" data;
    in
    mkFragment ''dataPath=$_data_${hash}Path'' { "_data_${hash}" = data; };
in

let
  out = "@out-${builtins.hashString "sha256" "${fragmentType}.out"}@";
in

let
  mkFile =
    data:
    concatFragments [
      (mkDataPath data)
      (mkFragment ''sed "s:${out}:$out:g" <"$dataPath" >"$outSubPath"'' { })
    ];
in

let
  mkScript =
    data:
    concatFragments [
      (mkFile data)
      (mkFragment ''chmod +x -- "$outSubPath"'' { })
    ];
in

let
  mkSymlink = sourcePath: mkFragment ''ln -sT -- ${lib.escapeShellArg sourcePath} "$outSubPath"'' { };
in

let
  mkDir =
    entries:
    concatFragments [
      (mkFragment ''mkdir -p -- "$outSubPath"'' { })
      (forEachAttrToFragment entries (
        pathComponent: entry:
        assert isValidPathComponent pathComponent;
        concatFragments [
          (mkFragment ''(outSubPath=$outSubPath/${lib.escapeShellArg pathComponent}'' { })
          entry
          (mkFragment '')'' { })
        ]
      ))
    ];
in

let
  mkDeriv =
    { name, out }:
    let
      fragment = concatFragments [
        (mkFragment ''outSubPath=$out'' { })
        out
      ];
      derivationArgs = fragment.dataArgs // {
        passAsFile = builtins.attrNames fragment.dataArgs;
      };
    in
    pkgs.runCommand name derivationArgs fragment.normalizedBuildCommand;
in

{
  inherit
    isFragment
    mkFragment
    emptyFragment
    concatFragments
    forEachAttrToFragment
    mkDataPath
    out
    mkFile
    mkScript
    mkSymlink
    mkDir
    mkDeriv
    ;
}
