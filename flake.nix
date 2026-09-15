{
  description = "Lightweight NixOS container rootfs with automated timed MAC address rotator for LXC & systemd-nspawn";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Function to create container configuration per architecture
      mkContainerConfig = system: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          # Standard NixOS LXC container base profile
          "${nixpkgs}/nixos/modules/virtualisation/lxc-container.nix"
          # Standard NixOS tarball generator module
          "${nixpkgs}/nixos/modules/installer/cd-dvd/tarball.nix"
          # Automated MAC rotator module
          ./modules/network-mac-rotator.nix
          {
            # Base Container Host & Network Identity
            networking.hostName = "nixos-container";

            # Enable Automated Timed MAC Rotator
            services.macRotator = {
              enable = true;
              interface = "eth0";
              calendarWindow = "*-*-* 02:00:00";
              randomDelay = "3h";
              leaseWaitSec = 3;
            };

            # Disable non-essential packages and documentation for minimal footprint
            documentation.enable = false;
            documentation.nixos.enable = false;
            documentation.man.enable = false;
            documentation.info.enable = false;
            documentation.doc.enable = false;

            # Allow root login for container management (passwordless on local console)
            users.users.root.initialHashedPassword = "";

            # Container optimization settings
            boot.isContainer = true;
            system.stateVersion = "24.11";

            # Configure Tarball generation
            tarball.fileName = "nixos-container-rootfs";
          }
        ];
      };
    in
    {
      # Pre-configured container system definitions
      nixosConfigurations = {
        base-container = mkContainerConfig "x86_64-linux";
        base-container-aarch64 = mkContainerConfig "aarch64-linux";
      };

      # Output packages including rootfs tarball for LXC / nspawn
      packages = forAllSystems (system:
        let
          containerConfig = mkContainerConfig system;
        in
        {
          tarball = containerConfig.config.system.build.tarball;
          default = containerConfig.config.system.build.tarball;
        }
      );
    };
}
