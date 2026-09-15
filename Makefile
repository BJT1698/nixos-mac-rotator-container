# ==============================================================================
# Makefile - NixOS Container MAC Rotator Infrastructure
# Deployment orchestration for LXC and systemd-nspawn on Debian Host
# ==============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Default container identifier if not specified
ID ?= node-01

# Path helpers
NIX_OUTPUT_DIR := result
TARBALL_PATH = $(shell find -L $(NIX_OUTPUT_DIR) \( -name "*.tar.xz" -o -name "*.tar.gz" -o -name "*.tar" \) 2>/dev/null | head -n1)

.PHONY: help build host-setup spawn-nspawn spawn-lxc stop-nspawn stop-lxc destroy-nspawn destroy-lxc status-nspawn status-lxc test-rotation-nspawn test-rotation-lxc clean

## ----------------------------------------------------------------------
## Help & General Targets
## ----------------------------------------------------------------------
help:
	@echo "NixOS MAC Rotator Container Infrastructure"
	@echo "=========================================="
	@echo "Usage: make <target> [ID=<container_id>]"
	@echo ""
	@echo "Build Targets:"
	@echo "  make build                     Build the NixOS container rootfs tarball using Nix flakes"
	@echo "  make host-setup                Run Debian host provisioning script (requires sudo)"
	@echo ""
	@echo "systemd-nspawn Targets:"
	@echo "  make spawn-nspawn ID=node-01   Deploy and start container node in /var/lib/machines/<ID>"
	@echo "  make status-nspawn ID=node-01  Check status of the nspawn container"
	@echo "  make test-rotation-nspawn ID=node-01  Trigger manual MAC rotation and view status"
	@echo "  make stop-nspawn ID=node-01    Stop running nspawn container"
	@echo "  make destroy-nspawn ID=node-01 Stop and delete nspawn container rootfs and configs"
	@echo ""
	@echo "LXC Targets:"
	@echo "  make spawn-lxc ID=node-01      Deploy and start container node in /var/lib/lxc/<ID>"
	@echo "  make status-lxc ID=node-01     Check status of the LXC container"
	@echo "  make test-rotation-lxc ID=node-01  Trigger manual MAC rotation and view status"
	@echo "  make stop-lxc ID=node-01       Stop running LXC container"
	@echo "  make destroy-lxc ID=node-01    Stop and delete LXC container rootfs and configs"
	@echo ""
	@echo "Maintenance Targets:"
	@echo "  make clean                     Remove Nix build result symlink"

## ----------------------------------------------------------------------
## Build Targets
## ----------------------------------------------------------------------
build:
	@echo "==> Building NixOS rootfs tarball with Flakes..."
	@nix build .#tarball --extra-experimental-features "nix-command flakes"
	@echo "==> Build successful! Tarball located at:"
	@find -L $(NIX_OUTPUT_DIR) \( -name "*.tar.xz" -o -name "*.tar.gz" -o -name "*.tar" \) 2>/dev/null

host-setup:
	@echo "==> Running host provisioning script..."
	@sudo ./host/debian-setup.sh

## ----------------------------------------------------------------------
## systemd-nspawn Deployment
## ----------------------------------------------------------------------
spawn-nspawn:
	@if [ -z "$(ID)" ]; then echo "[ERROR] Please specify container ID: make spawn-nspawn ID=node-01"; exit 1; fi
	@if [ ! -d "$(NIX_OUTPUT_DIR)" ] || [ -z "$(TARBALL_PATH)" ]; then \
		echo "==> Rootfs tarball not found. Triggering build..."; \
		$(MAKE) build; \
	fi
	@echo "==> Deploying systemd-nspawn container '$(ID)' under /var/lib/machines/$(ID)..."
	@sudo mkdir -p /var/lib/machines/$(ID) /etc/systemd/nspawn
	@echo "==> Extracting rootfs tarball: $(TARBALL_PATH)..."
	@sudo tar -xf $(TARBALL_PATH) -C /var/lib/machines/$(ID) --numeric-owner
	@echo "==> Configuring nspawn settings..."
	@sudo cp host/nspawn-template.nspawn /etc/systemd/nspawn/$(ID).nspawn
	@echo "==> Starting container '$(ID)' via machinectl..."
	@sudo machinectl start $(ID) 2>/dev/null || sudo systemd-nspawn -b -M $(ID) -D /var/lib/machines/$(ID) --network-bridge=br0 --capability=CAP_NET_ADMIN &
	@echo "==> Waiting for container boot and initial DHCP lease..."
	@sleep 4
	@sudo machinectl status $(ID) || true

status-nspawn:
	@sudo machinectl status $(ID)

test-rotation-nspawn:
	@echo "==> Testing MAC rotation inside nspawn container '$(ID)'..."
	@sudo machinectl shell $(ID) /run/current-system/sw/bin/rotate-mac
	@echo "==> Current Network Status:"
	@sudo machinectl shell $(ID) /run/current-system/sw/bin/ip -br link
	@sudo machinectl shell $(ID) /run/current-system/sw/bin/ip -br addr

stop-nspawn:
	@echo "==> Stopping nspawn container '$(ID)'..."
	@sudo machinectl stop $(ID) 2>/dev/null || sudo machinectl poweroff $(ID) 2>/dev/null || true

destroy-nspawn: stop-nspawn
	@echo "==> Destroying nspawn container '$(ID)'..."
	@sudo rm -rf /var/lib/machines/$(ID) /etc/systemd/nspawn/$(ID).nspawn
	@echo "==> Container '$(ID)' removed."

## ----------------------------------------------------------------------
## LXC Deployment
## ----------------------------------------------------------------------
spawn-lxc:
	@if [ -z "$(ID)" ]; then echo "[ERROR] Please specify container ID: make spawn-lxc ID=node-01"; exit 1; fi
	@if [ ! -d "$(NIX_OUTPUT_DIR)" ] || [ -z "$(TARBALL_PATH)" ]; then \
		echo "==> Rootfs tarball not found. Triggering build..."; \
		$(MAKE) build; \
	fi
	@echo "==> Deploying LXC container '$(ID)' under /var/lib/lxc/$(ID)..."
	@sudo mkdir -p /var/lib/lxc/$(ID)/rootfs
	@echo "==> Extracting rootfs tarball: $(TARBALL_PATH)..."
	@sudo tar -xf $(TARBALL_PATH) -C /var/lib/lxc/$(ID)/rootfs --numeric-owner
	@echo "==> Generating LXC configuration from template..."
	@sed "s/@CONTAINER_ID@/$(ID)/g" host/lxc-template.conf | sudo tee /var/lib/lxc/$(ID)/config > /dev/null
	@echo "==> Starting LXC container '$(ID)'..."
	@sudo lxc-start -n $(ID) -d
	@echo "==> Waiting for container boot and initial DHCP lease..."
	@sleep 4
	@sudo lxc-info -n $(ID)

status-lxc:
	@sudo lxc-info -n $(ID)

test-rotation-lxc:
	@echo "==> Testing MAC rotation inside LXC container '$(ID)'..."
	@sudo lxc-attach -n $(ID) -- /run/current-system/sw/bin/rotate-mac
	@echo "==> Current Network Status:"
	@sudo lxc-attach -n $(ID) -- ip -br link
	@sudo lxc-attach -n $(ID) -- ip -br addr

stop-lxc:
	@echo "==> Stopping LXC container '$(ID)'..."
	@sudo lxc-stop -n $(ID) -k 2>/dev/null || true

destroy-lxc: stop-lxc
	@echo "==> Destroying LXC container '$(ID)'..."
	@sudo lxc-destroy -n $(ID) -f 2>/dev/null || true
	@sudo rm -rf /var/lib/lxc/$(ID)
	@echo "==> Container '$(ID)' removed."

## ----------------------------------------------------------------------
## Cleanup
## ----------------------------------------------------------------------
clean:
	@echo "==> Cleaning build artifacts..."
	@rm -rf $(NIX_OUTPUT_DIR)
	@echo "==> Clean complete."
