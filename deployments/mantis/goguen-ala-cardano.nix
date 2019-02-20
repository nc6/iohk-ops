let localLib = import ./../../lib.nix; 
    topology = import ./../../topology.nix; in
with builtins; with localLib;
{ ... }:
let
  mkMantisMachine = vmType: nodeName: { nodes, resources, pkgs, config, ... }: {
    imports = [ ../../modules/mantis-service.pseudo.nix ];
    options = {
      cluster = mkOption {
        description = "Cluster parameters.";
        default = {};
        type = with types; submodule {
          options = {
            mantisNodeNames = mkOption {
              type = listOf str;
              description = "List of Mantis node names.";
              default = [ "mantis-a-0" "mantis-a-1" "mantis-b-0" "mantis-b-1" "mantis-c-0" ];
            };
          };
        };
      };
    };

    config = {
      deployment.keys.mantis-node = {
        keyFile = ../static + "/${nodeName}.key";
        user = "mantis";
        destDir = "/var/lib/keys";
      };
      services.mantis = {
        inherit nodeName vmType;
      };
    };
  };
in {
  network.description = "GMC";
} // listToAttrs (map 
      (mantisNode: nameValuePair mantisNode (mkMantisMachine "iele" mantisNode))
      (goguenNodes topology "mantis")
    )
