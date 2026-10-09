{
  description = "Chris's NixOS Configuration with Flake Modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    insynch.url = "git+file:./flakes/insynch";
  };

  outputs = { self, nixpkgs, insynch, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        ./configuration.nix
        insynch.nixosModules.default

        # Add Flatpak support - required to run sandboxed images like idea
        {
          services.flatpak.enable = true;
          xdg.portal.enable = true; # recommended for desktop integration
          # RECOMMENDED>xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
        }
      ];
    };
  };
}

