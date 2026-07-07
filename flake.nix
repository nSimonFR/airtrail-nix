{
  description = "Nix packaging for AirTrail — self-hosted personal flight tracker (johanohly/AirTrail)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { pkgs, system, ... }:
        let airtrail = pkgs.callPackage ./package.nix { }; in {
          packages.airtrail = airtrail;
          packages.default = airtrail;
        };

      flake = {
        nixosModules.airtrail = import ./module.nix self;
        nixosModules.default = self.nixosModules.airtrail;

        # Overlay exposing `pkgs.airtrail`
        overlays.default = final: prev: {
          airtrail = final.callPackage ./package.nix { };
        };
      };
    };
}
