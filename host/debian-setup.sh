#!/usr/bin/env bash
# ==============================================================================
# Host Provisioning Script for Debian Linux
# Configures LXC, systemd-nspawn, isolated bridge (br0), dnsmasq DHCP, and NAT
# ==============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This setup script must be run as root (or via sudo)." >&2
    exit 1
fi

BRIDGE_NAME="br0"
BRIDGE_IP="10.100.0.1"
BRIDGE_NETMASK="255.255.255.0"
BRIDGE_CIDR="10.100.0.1/24"
DHCP_START="10.100.0.10"
DHCP_END="10.100.0.250"
DHCP_LEASE="1h"

echo "=== [1/6] Installing Host Dependencies ==="
apt-get update -qq
apt-get install -y -qq \
    lxc \
    lxc-templates \
    systemd-container \
    bridge-utils \
    dnsmasq \
    iptables \
    iptables-persistent \
    netfilter-persistent \
    iproute2 \
    tar \
    xz-utils \
    curl \
    ca-certificates \
    >/dev/null

echo "=== [2/6] Configuring Persistent Bridge Interface ($BRIDGE_NAME) ==="
mkdir -p /etc/network/interfaces.d

cat <<EOF > "/etc/network/interfaces.d/$BRIDGE_NAME"
# Bridge interface for isolated NixOS container subnet
auto $BRIDGE_NAME
iface $BRIDGE_NAME inet static
    address $BRIDGE_IP
    netmask $BRIDGE_NETMASK
    bridge_ports none
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
EOF

# Create and bring up bridge dynamically if not already active
if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    ip link add name "$BRIDGE_NAME" type bridge
fi

ip addr flush dev "$BRIDGE_NAME"
ip addr add "$BRIDGE_CIDR" dev "$BRIDGE_NAME" 2>/dev/null || true
ip link set dev "$BRIDGE_NAME" up

echo "=== [3/6] Configuring dnsmasq DHCP on $BRIDGE_NAME ==="
mkdir -p /etc/dnsmasq.d /var/lib/misc

cat <<EOF > /etc/dnsmasq.d/br0-nixos-containers.conf
# Isolated DHCP Server for NixOS Containers on $BRIDGE_NAME
interface=$BRIDGE_NAME
bind-interfaces
except-interface=lo
listen-address=$BRIDGE_IP
dhcp-range=$DHCP_START,$DHCP_END,$BRIDGE_NETMASK,$DHCP_LEASE
dhcp-option=option:router,$BRIDGE_IP
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8
dhcp-leasefile=/var/lib/misc/dnsmasq.$BRIDGE_NAME.leases
dhcp-authoritative
EOF

# Restart dnsmasq to apply bridge DHCP configuration
systemctl restart dnsmasq
systemctl enable dnsmasq >/dev/null 2>&1 || true

echo "=== [4/6] Enabling Kernel IPv4 Forwarding ==="
mkdir -p /etc/sysctl.d
cat <<EOF > /etc/sysctl.d/99-nixos-containers-forward.conf
net.ipv4.ip_forward = 1
EOF
sysctl -q -p /etc/sysctl.d/99-nixos-containers-forward.conf

echo "=== [5/6] Setting up IPTables NAT & Forwarding ==="
# Detect primary outbound interface
EGRESS_IF=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)

if [ -z "$EGRESS_IF" ]; then
    echo "[WARN] No default egress route detected. NAT masquerading might require manual interface specification."
else
    echo "Detected egress interface: $EGRESS_IF"

    # Forwarding rules for container traffic
    iptables -C FORWARD -i "$BRIDGE_NAME" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$BRIDGE_NAME" -j ACCEPT

    iptables -C FORWARD -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Masquerade outbound traffic from container subnet
    iptables -t nat -C POSTROUTING -s 10.100.0.0/24 -o "$EGRESS_IF" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o "$EGRESS_IF" -j MASQUERADE

    # Persist rules across reboots
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
fi

echo "=== [6/6] Creating Container Management Directories ==="
mkdir -p /var/lib/machines /var/lib/lxc /etc/systemd/nspawn /etc/lxc

echo "=== Host Setup Complete! ==="
echo "Bridge $BRIDGE_NAME active on $BRIDGE_CIDR with dnsmasq DHCP ($DHCP_START - $DHCP_END)."
