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
          # Automated MAC rotator module
          ./modules/network-mac-rotator.nix
          {
            # Base Container Host & Network Identity
            networking.hostName = "nixos-container";
            networking.useHostResolvConf = false;

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
          }
        ];
      };

      # Custom rootfs builder using standard closureInfo to avoid fragile installer module paths
      mkTarball = system:
        let
          pkgs = import nixpkgs { inherit system; };
          containerConfig = mkContainerConfig system;
          toplevel = containerConfig.config.system.build.toplevel;
          closure = pkgs.closureInfo { rootPaths = [ toplevel ]; };
        in
        pkgs.runCommand "nixos-container-rootfs" {
          nativeBuildInputs = [ pkgs.xz pkgs.gnutar ];
        } ''
          mkdir -p rootfs/nix/store
          mkdir -p rootfs/bin rootfs/run rootfs/etc rootfs/tmp rootfs/proc rootfs/sys rootfs/dev rootfs/root
          chmod 1777 rootfs/tmp

          echo "Populating Nix store closure..."
          while IFS= read -r path; do
            cp -a "$path" rootfs/nix/store/
          done < "${closure}/store-paths"

          # Basic Nix database structure
          mkdir -p rootfs/nix/var/nix/db
          mkdir -p rootfs/nix/var/nix/gcroots

          # Standard NixOS init symlinks
          ln -s ${toplevel}/init rootfs/init
          ln -s ${toplevel} rootfs/run/current-system

          echo "Compressing rootfs tarball..."
          mkdir -p $out
          tar --numeric-owner -c -C rootfs . | xz -T0 -6 > $out/nixos-container-rootfs.tar.xz
          echo "Tarball creation complete."
        '';
    in
    {
      # Pre-configured container system definitions
      nixosConfigurations = {
        base-container = mkContainerConfig "x86_64-linux";
        base-container-aarch64 = mkContainerConfig "aarch64-linux";
      };

      # Output packages including rootfs tarball for LXC / nspawn
      packages = forAllSystems (system: {
        tarball = mkTarball system;
        default = mkTarball system;
      });
    };
}
