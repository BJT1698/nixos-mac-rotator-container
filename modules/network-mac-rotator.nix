{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.macRotator;

  # Shell script responsible for generating a random IEEE 802 LAA MAC address,
  # applying it to the interface, bouncing the link, and triggering DHCP renewal.
  rotatorScript = pkgs.writeShellApplication {
    name = "rotate-mac";
    runtimeInputs = [
      pkgs.iproute2
      pkgs.coreutils
      pkgs.systemd
      pkgs.gawk
      pkgs.gnused
    ];
    text = ''
      set -euo pipefail

      TARGET_IFACE="${cfg.interface}"

      # Auto-detect interface if target does not exist (e.g. host0 in nspawn vs eth0 in LXC)
      if ! ip link show "$TARGET_IFACE" >/dev/null 2>&1; then
        FALLBACK_IFACE=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}' | cut -d'@' -f1)
        if [ -n "$FALLBACK_IFACE" ] && ip link show "$FALLBACK_IFACE" >/dev/null 2>&1; then
          echo "[mac-rotator] Interface '$TARGET_IFACE' not found. Falling back to '$FALLBACK_IFACE'."
          TARGET_IFACE="$FALLBACK_IFACE"
        else
          echo "[mac-rotator] ERROR: Interface '$TARGET_IFACE' not found and no suitable fallback detected." >&2
          exit 1
        fi
      fi

      OLD_MAC=$(ip link show "$TARGET_IFACE" | awk '/link\/ether/ {print $2}')
      echo "[mac-rotator] Current MAC on $TARGET_IFACE: ''${OLD_MAC:-unknown}"

      # Extract 6 random bytes from /dev/urandom
      read -r -a HEX_BYTES < <(od -An -N6 -tx1 /dev/urandom)

      if [ "''${#HEX_BYTES[@]}" -ne 6 ]; then
        echo "[mac-rotator] ERROR: Failed to read 6 random bytes from /dev/urandom" >&2
        exit 1
      fi

      # IEEE 802 Standard for Locally Administered Address (LAA) Unicast:
      # - Bit 0 (I/G - Individual/Group): must be 0 (unicast)
      # - Bit 1 (U/L - Universal/Local): must be 1 (locally administered)
      # Formula: (byte0 & 0xFE) | 0x02
      # This strictly forces the second hexadecimal nibble of the first byte to be 2, 6, A, or E.
      FIRST_BYTE_DEC=$(( (0x''${HEX_BYTES[0]} & 0xFE) | 0x02 ))
      FIRST_BYTE_HEX=$(printf '%02x' "$FIRST_BYTE_DEC")

      NEW_MAC=$(printf '%s:%02x:%02x:%02x:%02x:%02x' \
        "$FIRST_BYTE_HEX" \
        "0x''${HEX_BYTES[1]}" \
        "0x''${HEX_BYTES[2]}" \
        "0x''${HEX_BYTES[3]}" \
        "0x''${HEX_BYTES[4]}" \
        "0x''${HEX_BYTES[5]}")

      echo "[mac-rotator] Generated IEEE 802 LAA Unicast MAC: $NEW_MAC"

      # Step 1: Bounce interface down
      echo "[mac-rotator] Bringing down $TARGET_IFACE..."
      ip link set dev "$TARGET_IFACE" down

      # Step 2: Apply new MAC address
      echo "[mac-rotator] Assigning new MAC $NEW_MAC to $TARGET_IFACE..."
      ip link set dev "$TARGET_IFACE" address "$NEW_MAC"

      # Step 3: Bring interface back up
      echo "[mac-rotator] Bringing up $TARGET_IFACE..."
      ip link set dev "$TARGET_IFACE" up

      # Step 4: Instruct systemd-networkd to reconfigure and request fresh DHCP lease
      if command -v networkctl >/dev/null 2>&1; then
        echo "[mac-rotator] Notifying systemd-networkd to renew DHCP lease for $TARGET_IFACE..."
        networkctl reconfigure "$TARGET_IFACE" 2>/dev/null || networkctl renew "$TARGET_IFACE" 2>/dev/null || true
      fi

      # Step 5: Brief grace period for DHCP handshake negotiation
      sleep ${toString cfg.leaseWaitSec}

      VERIFIED_MAC=$(ip link show "$TARGET_IFACE" | awk '/link\/ether/ {print $2}')
      CURRENT_IP=$(ip -4 -o addr show dev "$TARGET_IFACE" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 || echo "negotiating...")

      echo "[mac-rotator] MAC rotation completed successfully."
      echo "[mac-rotator] Result: ''${OLD_MAC} -> ''${VERIFIED_MAC} (Assigned IPv4: ''${CURRENT_IP})"
    '';
  };
in
{
  options.services.macRotator = {
    enable = mkEnableOption "automated timed MAC address rotation with fresh DHCP lease acquisition";

    interface = mkOption {
      type = types.str;
      default = "eth0";
      example = "eth0";
      description = "Target network interface to rotate MAC address on.";
    };

    calendarWindow = mkOption {
      type = types.str;
      default = "*-*-* 02:00:00";
      example = "*-*-* 02:00:00";
      description = "systemd OnCalendar expression defining the base execution time.";
    };

    randomDelay = mkOption {
      type = types.str;
      default = "3h";
      example = "3h";
      description = "systemd RandomizedDelaySec value specifying maximum random jitter applied to OnCalendar.";
    };

    leaseWaitSec = mkOption {
      type = types.int;
      default = 3;
      example = 5;
      description = "Grace period (seconds) to wait after link-up for DHCP negotiation.";
    };
  };

  config = mkIf cfg.enable {
    # Install CLI helper script into system environment for manual testing
    environment.systemPackages = [ rotatorScript ];

    # Configure systemd-networkd with DHCPv4 ClientIdentifier = "mac"
    networking = {
      useNetworkd = mkDefault true;
      useDHCP = mkDefault false;
    };

    systemd.network = {
      enable = true;
      networks."10-container-network" = {
        matchConfig = {
          Name = [ cfg.interface "eth*" "host*" "en*" ];
        };
        networkConfig = {
          DHCP = "ipv4";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = "no";
        };
        dhcpV4Config = {
          # Explicitly force MAC address identifier instead of machine-id derived DUID (RFC 4361)
          ClientIdentifier = "mac";
          SendHostname = true;
          UseDNS = true;
          UseRoutes = true;
          Anonymize = true;
          RapidCommit = false;
        };
      };
    };

    # systemd one-shot service executing the rotator script
    systemd.services.mac-rotator = {
      description = "Automated MAC Address Rotator";
      wants = [ "network.target" ];
      after = [ "systemd-networkd.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${rotatorScript}/bin/rotate-mac";
        RemainAfterExit = false;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # systemd timer triggering the rotator within the specified window + random jitter
    systemd.timers.mac-rotator = {
      description = "Timer for Automated MAC Address Rotation";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.calendarWindow;
        RandomizedDelaySec = cfg.randomDelay;
        Persistent = true;
      };
    };
  };
}
