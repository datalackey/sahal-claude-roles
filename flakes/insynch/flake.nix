{
  description = "Flake for testing nethack in nix shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

  outputs = { self, nixpkgs, ... }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;  # Insync is nonfree
    };
  in {
    nixosModules.default = import ./default.nix;

    packages.${system}.default = pkgs.insync;
  };
}

