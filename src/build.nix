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
  out = "/replace-with-out-${builtins.hashString "sha256" "${fragmentType}.out"}";
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
  mkFragment =
    { mkBuildCommand, mkFileArgs }:
    {
      type = fragmentType;
      mkBuildCommandList = [ mkBuildCommand ];
      mkFileArgsList = [ mkFileArgs ];
    };
in

let
  concatFragments =
    fragments:
    assert builtins.all isFragment fragments;
    {
      type = fragmentType;
      mkBuildCommandList = lib.concatMap (fragment: fragment.mkBuildCommandList) fragments;
      mkFileArgsList = lib.concatMap (fragment: fragment.mkFileArgsList) fragments;
    };
in

let
  emptyFragment = concatFragments [ ];
in

let
  mkOptional = cond: fragment: if cond then fragment else emptyFragment;
in

let
  mkCommandFragment =
    buildCommand:
    mkFragment {
      mkBuildCommand = i: buildCommand;
      mkFileArgs = i: { };
    };
in

let
  mkSymlink =
    sourcePath:
    mkFragment {
      mkBuildCommand = i: ''ln -sT -- $(sed "s:${out}:$out:g" <"$file${toString i}Path") "$outSubPath"'';
      mkFileArgs = i: { "file${toString i}" = sourcePath; };
    };
in

let
  mkFile =
    data:
    mkFragment {
      mkBuildCommand = i: ''sed "s:${out}:$out:g" <"$file${toString i}Path" >"$outSubPath"'';
      mkFileArgs = i: { "file${toString i}" = data; };
    };
in

let
  mkScript =
    data:
    concatFragments [
      (mkFile data)
      (mkCommandFragment ''chmod +x -- "$outSubPath"'')
    ];
in

let
  mkDir =
    entries:
    concatFragments [
      (mkCommandFragment ''mkdir -- "$outSubPath"'')
      (concatFragments (
        lib.mapAttrsToList (
          pathComponent: entry:
          assert isValidPathComponent pathComponent;
          concatFragments [
            (mkCommandFragment ''(outSubPath=$outSubPath/${lib.escapeShellArg pathComponent}'')
            entry
            (mkCommandFragment '')'')
          ]
        ) entries
      ))
    ];
in

let
  mkDeriv =
    { name, out }:
    let
      fragment = concatFragments [
        (mkCommandFragment ''outSubPath=$out'')
        out
      ];
      fileArgs = builtins.foldl' lib.attrsets.unionOfDisjoint { } (
        lib.lists.imap1 (i: mkFileArgs: mkFileArgs i) fragment.mkFileArgsList
      );
      derivationArgs = lib.attrsets.unionOfDisjoint fileArgs {
        passAsFile = builtins.attrNames fileArgs;
      };
      buildCommand = builtins.concatStringsSep "\n" (
        lib.lists.imap1 (i: mkBuildCommand: mkBuildCommand i) fragment.mkBuildCommandList
      );
    in
    pkgs.runCommand name derivationArgs buildCommand;
in

{
  inherit
    out
    emptyFragment
    mkOptional
    mkCommandFragment
    mkFile
    mkScript
    mkSymlink
    mkDir
    mkDeriv
    ;
}
