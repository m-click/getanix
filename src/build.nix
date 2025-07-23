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
  out = getanix.strings.createReplacementMarker fragmentType "out";
in

let
  writeArgToStdout = getanix.strings.createReplacementMarker fragmentType "writeArgToStdout";
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
  mkCommandFragmentWithArg =
    buildCommand: arg:
    mkFragment {
      mkBuildCommand =
        i:
        let
          writeArgToStdoutCommand = ''sed "s:${out}:$out:g" <"$file${toString i}Path"'';
        in
        builtins.replaceStrings [ writeArgToStdout ] [ writeArgToStdoutCommand ] buildCommand;
      mkFileArgs = i: { "file${toString i}" = arg; };
    };
in

let
  mkFile = mkCommandFragmentWithArg ''${writeArgToStdout} >"$outSubPath"'';
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
  mkSymlink = mkCommandFragmentWithArg ''ln -sT -- $(${writeArgToStdout}) "$outSubPath"'';
in

let
  mkCopy = mkCommandFragmentWithArg ''cp -p -- $(${writeArgToStdout}) "$outSubPath"'';
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
    writeArgToStdout
    emptyFragment
    mkOptional
    mkCommandFragment
    mkCommandFragmentWithArg
    mkFile
    mkScript
    mkSymlink
    mkCopy
    mkDir
    mkDeriv
    ;
}
