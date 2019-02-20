# To interact with this file:
# nix-repl lib.nix

let
  # iohk-nix can be overridden for debugging purposes by setting
  # NIX_PATH=iohk_nix=/path/to/iohk-nix
  mkIohkNix = iohkNixArgs: import (
    let try = builtins.tryEval <iohk_nix>;
    in if try.success
    then builtins.trace "using host <iohk_nix>" try.value
    else
      let
        spec = builtins.fromJSON (builtins.readFile ./iohk-nix.json);
      in builtins.fetchTarball {
        url = "${spec.url}/archive/${spec.rev}.tar.gz";
        inherit (spec) sha256;
      }) iohkNixArgs;
  iohkNix       = mkIohkNix { application = "iohk-ops"; };
  iohkNixGoguen = mkIohkNix { application = "goguen"; nixpkgsJsonOverride = ./goguen/pins/nixpkgs-src.json; };
  goguenNixpkgs = iohkNixGoguen.nixpkgs;

  # nixpkgs can be overridden for debugging purposes by setting
  # NIX_PATH=custom_nixpkgs=/path/to/nixpkgs
  pkgs = iohkNix.pkgs;
  lib = pkgs.lib;
in lib // (rec {
  inherit (iohkNix) nixpkgs;
  inherit mkIohkNix pkgs;
  inherit iohkNixGoguen goguenNixpkgs;

  ## nodeElasticIP :: Node -> EIP
  nodeElasticIP = node:
    { name = "${node.name}-ip";
      value = { inherit (node) region accessKeyId; };
    };
  ## repoSpec                = RepoSpec { name :: String, subdir :: FilePath, src :: Drv }
  ## fetchGitWithSubmodules :: Name -> Drv -> Map String RepoSpec -> Drv
  fetchGitWithSubmodules = mainName: mainSrc: subRepos:
    with builtins; with pkgs;
    let subRepoCmd = repo: ''
        chmod -R u+w $(dirname $out/${repo.subdir})
        rmdir $out/${repo.subdir}
        cp -R  ${repo.src} $out/${repo.subdir}
        '';
        cmd = ''

        cp -R ${mainSrc} $out

        '' + concatStringsSep "\n" (map subRepoCmd (attrValues subRepos));
    in runCommand "fetchGit-composite-src-${mainName}" { buildInputs = []; } cmd;

  pinFile = dir: name: dir + "/${name}.src-json";
  readPin = pin: let json = builtins.readFile pin;
    in builtins.fromJSON (builtins.trace json json);
  pinIsPrivate = pinJ: pinJ.url != builtins.replaceStrings ["git@github.com"] [""] pinJ.url;

  fetchGitPin = name: pinJ:
    builtins.fetchGit (pinJ // { name = name; });

  fetchGitPinWithSubmodules = pinRoot: name: { url, rev, submodules ? {} }:
    with builtins;
    let fetchSubmodule = subName: subDir: { subdir = subDir; src = pkgs.fetchgit (readPin (pinFile pinRoot subName)); };
    in fetchGitWithSubmodules name (fetchGitPin name { inherit url rev; }) (lib.mapAttrs fetchSubmodule submodules);

  ## Depending on whether the repo is private (URL has 'git@github' in it), we need to use fetchGit*
  fetchPinAuto = pinRoot: name:
    with builtins; let
      pinJ = readPin (pinFile pinRoot name);
    in if pinIsPrivate pinJ
    then fetchGitPinWithSubmodules pinRoot name pinJ
    else pkgs.fetchgit                          pinJ;

  centralRegion = "eu-central-1";
  centralZone   = "eu-central-1b";

  ## nodesElasticIPs :: Map NodeName Node -> Map EIPName EIP
  nodesElasticIPs = nodes: lib.flip lib.mapAttrs' nodes
    (name: node: nodeElasticIP node);

  resolveSGName = resources: name: resources.ec2SecurityGroups.${name};

  orgRegionKeyPairName = org: region: "cardano-keypair-${org}-${region}";

  goguenNodes = topology: nodeType: 
    lib.flatten (
      lib.mapAttrsToList
        (region: nodes: builtins.genList (n: "${nodeType}-" + region + "-" + toString n) nodes."${nodeType}")
        topology.regions
    );

  traceF   = f: x: builtins.trace                         (f x)  x;
  traceSF  = f: x: builtins.trace (builtins.seq     (f x) (f x)) x;
  traceDSF = f: x: builtins.trace (builtins.deepSeq (f x) (f x)) x;

  # Parse peers from a file
  #
  # > peersFromFile ./peers.txt
  # ["ip:port/dht" "ip:port/dht" ...]
  peersFromFile = file: lib.splitString "\n" (builtins.readFile file);

  # Given a list of NixOS configs, generate a list of peers (ip/dht mappings)
  genPeersFromConfig = configs:
    let
      f = c: "${c.networking.publicIPv4}:${toString c.services.cardano-node.port}";
    in map f configs;

  # modulo operator
  # mod 11 10 == 1
  # mod 1 10 == 1
  mod = base: int: base - (int * (builtins.div base int));

  # Removes files within a Haskell source tree which won't change the
  # result of building the package.
  # This is so that cached build products can be used whenever possible.
  # It also applies the lib.cleanSource filter from nixpkgs which
  # removes VCS directories, emacs backup files, etc.
  cleanSourceTree = src:
    if lib.canCleanSource src
      then lib.cleanSourceWith {
        filter = with pkgs.stdenv;
          name: type: let baseName = baseNameOf (toString name); in ! (
            # Filter out cabal build products.
            baseName == "dist" || baseName == "dist-newstyle" ||
            baseName == "cabal.project.local" ||
            lib.hasPrefix ".ghc.environment" baseName ||
            # Filter out stack build products.
            lib.hasPrefix ".stack-work" baseName ||
            # Filter out files which are commonly edited but don't
            # affect the cabal build.
            lib.hasSuffix ".nix" baseName
          );
        src = lib.cleanSource src;
      } else src;

} // (with (import ./lib/ssh-keys.nix { inherit lib; }); rec {
  #
  # Access
  #
  inherit devOps csl-developers;

  devOpsKeys = allKeysFrom devOps;
  devKeys = devOpsKeys ++ allKeysFrom csl-developers;
  mantisOpsKeys = allKeysFrom devOps ++ allKeysFrom mantis-devOps;

  # Access to login to CI infrastructure
  ciInfraKeys = devOpsKeys ++ allKeysFrom { inherit (csl-developers) angerman; };

  buildSlaveKeys = {
    macos = devOpsKeys ++ allKeysFrom remoteBuilderKeys;
    linux = remoteBuilderKeys.hydraBuildFarm;
  };

}))
