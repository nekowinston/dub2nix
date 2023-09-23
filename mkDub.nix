{ pkgs ? import <nixpkgs> {},
  stdenv ? pkgs.stdenv,
  lib ? pkgs.lib,
  dtools ? pkgs.dtools or pkgs.rdmd,
  dmd ? pkgs.dmd,
  dcompiler ? dmd,
  dub ? pkgs.dub }:

with stdenv;
let
  # Filter function to remove the .dub package folder from src
  filterDub = name: type: let baseName = baseNameOf (toString name); in ! (
    type == "directory" && baseName == ".dub"
  );

  # Convert a GIT rev string (tag) to a simple semver version
  rev-to-version = builtins.replaceStrings ["v" "refs/tags/v"] ["" ""];

  dep2src = dubDep: pkgs.fetchgit { inherit (dubDep.fetch) url rev sha256 fetchSubmodules; };

  # Fetch a dependency (source only for now)
  fromDub = dubDep: mkDerivation rec {
    name = "${src.name}-${version}";
    version = rev-to-version dubDep.fetch.rev;
    # to patch dub.json if needed
    buildInputs = [pkgs.jq];
    nativeBuildInputs = [ dcompiler dtools dub ];
    src = dep2src dubDep;

    dontConfigure = true;
    dontBuild = true;

    patchPhase = ''
      runHook prePatch
      [ -f dub.json ] && jq 'del(.targetPath)' dub.json > dub.json.tmp && mv dub.json.tmp dub.json
      [ -f dub.sdl ] && sed -i '/targetPath/d' dub.sdl
      runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  # Adds a local package directory (e.g. a git repository) to Dub
  dub-add-local = dubDep: "dub add-local ${(fromDub dubDep).outPath} ${rev-to-version dubDep.fetch.rev}";

  # The target output of the Dub package
  targetOf = package: "${package.targetPath or "."}/${package.targetName or package.name}";

  # Remove reference to build tools and library sources
  disallowedReferences = deps: [ dcompiler dtools dub ] ++ builtins.map dep2src deps;

  removeExpr = refs: ''remove-references-to ${lib.concatMapStrings (ref: " -t ${ref}") refs}'';

  # Like split, but only keep the matches
  matches = regex: str: builtins.filter lib.isList (builtins.split regex str);

  # Very primitive parsing of SDL files, but suffices for name, description, homepage, etc.
  importSDL = path: builtins.foldl' (a: l: a // {"${lib.elemAt l 1}"=lib.elemAt l 2;}) {} (matches "(^|\n)([a-z]+) \"([^\"]+)\"" (builtins.readFile path));

  importPackage = sdl: json: if builtins.pathExists sdl then importSDL sdl else lib.importJSON json;

in {
  inherit fromDub;

  mkDubDerivation = lib.makeOverridable ({
    src,
    nativeBuildInputs ? [],
    dubJSON ? src + "/dub.json",
    dubSDL ? src + "/dub.sdl",
    buildType ? "release",
    dubFlags ? "--combined",
    extraDubFlags ? "",
    selections ? src + "/dub.selections.nix",
    deps ? import selections,
    package ? importPackage dubSDL dubJSON,
    passthru ? {},
    ...
  } @ attrs: stdenv.mkDerivation ({

    pname = package.name;

    nativeBuildInputs = [ dcompiler dtools dub pkgs.removeReferencesTo ] ++ nativeBuildInputs;
    disallowedReferences = disallowedReferences deps;

    passthru = passthru // {
      inherit dub dcompiler dtools pkgs;
    };

    src = lib.cleanSourceWith {
      filter = filterDub;
      src = lib.cleanSource src;
    };

    preFixup = ''
      find $out/bin -type f -exec ${removeExpr (disallowedReferences deps)} '{}' + || true
    '';

    buildPhase = ''
      runHook preBuild

      export HOME=$PWD
      ${lib.concatMapStringsSep "\n" dub-add-local deps}
      dub build -b ${buildType} ${dubFlags} --skip-registry=all ${extraDubFlags}

      runHook postBuild
    '';

    checkPhase = ''
      runHook preCheck

      export HOME=$PWD
      ${lib.concatMapStringsSep "\n" dub-add-local deps}
      dub test ${dubFlags} --skip-registry=all ${extraDubFlags}

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      cp -r "${targetOf package}" $out/bin

      runHook postInstall
    '';

    meta = lib.optionalAttrs (package ? description) {
      description = package.description;
    } // lib.optionalAttrs (package ? homepage) {
      homepage = package.homepage;
    } // attrs.meta or {};
  } // (lib.optionalAttrs (!(attrs ? version)) {
    # Use name from dub.json, unless pname and version are specified
    name = package.name;
  }) // (removeAttrs attrs ["package" "deps" "selections" "dubJSON" "dubSDL"])));
}
