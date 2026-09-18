#!/usr/bin/env bash
# install.sh — take a fresh Ubuntu install to a NetPerf25-ready state.
# Installs: Docker Engine, Containerlab, a Python venv, and the kernel modules
# the labs need (sch_netem, tcp_vegas, tcp_bbr). Idempotent and arch-aware.
#
# Usage:  bash bootstrap/install.sh
# Then:   make check   (or bash bootstrap/preflight.sh)
set -euo pipefail

# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${REPO_ROOT}/.venv"
MODULES=(sch_netem tcp_vegas tcp_bbr)
MODULES_CONF="/etc/modules-load.d/netperf25.conf"

c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m•\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
step()   { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# Resolve a sudo prefix (empty when already root).
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
    c_err "Run as root or install sudo first."; exit 1
  fi
fi

# ---------------------------------------------------------------------------
step "Preflight: OS + architecture"
if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  c_warn "This installer targets Ubuntu. Detected: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")."
  c_warn "It may still work on Debian derivatives; other distros are unsupported."
fi
ARCH="$(dpkg --print-architecture)"   # amd64 | arm64
c_info "Architecture: ${ARCH}"
KREL="$(uname -r)"
c_info "Kernel: ${KREL}"

# ---------------------------------------------------------------------------
step "Base packages"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq \
  ca-certificates curl gnupg git make jq \
  iproute2 iputils-ping tcpdump bwm-ng iperf3 ethtool \
  python3 python3-venv python3-pip
c_ok "Base tooling installed"

# ---------------------------------------------------------------------------
step "Docker Engine"
if command -v docker >/dev/null 2>&1; then
  c_ok "Docker already present ($(docker --version 2>/dev/null || echo present))"
else
  c_info "Installing Docker via get.docker.com convenience script"
  curl -fsSL https://get.docker.com | $SUDO sh
  c_ok "Docker installed"
fi
# Add the invoking user to the docker group (effective after re-login).
TARGET_USER="${SUDO_USER:-$USER}"
if [ "${TARGET_USER}" != "root" ]; then
  if ! id -nG "${TARGET_USER}" | grep -qw docker; then
    $SUDO usermod -aG docker "${TARGET_USER}"
    c_warn "Added ${TARGET_USER} to the 'docker' group — log out/in (or run 'newgrp docker') for it to take effect."
  else
    c_ok "${TARGET_USER} already in the docker group"
  fi
fi
$SUDO systemctl enable --now docker 2>/dev/null || \
  c_warn "Could not enable the docker service via systemd (fine on WSL — start Docker Desktop / dockerd manually)."

# ---------------------------------------------------------------------------
step "Containerlab"
if command -v clab >/dev/null 2>&1 || command -v containerlab >/dev/null 2>&1; then
  c_ok "Containerlab already present ($(clab version 2>/dev/null | head -n1 || echo present))"
else
  c_info "Installing Containerlab via get.containerlab.dev"
  $SUDO bash -c "$(curl -sL https://get.containerlab.dev)"
  c_ok "Containerlab installed"
fi

# ---------------------------------------------------------------------------
step "Kernel modules (netem + congestion control)"
# sch_netem lives in linux-modules-extra on Ubuntu; install the matching package.
if apt-cache show "linux-modules-extra-${KREL}" >/dev/null 2>&1; then
  $SUDO apt-get install -y -qq "linux-modules-extra-${KREL}" || \
    c_warn "Could not install linux-modules-extra-${KREL}; modules may already be built in."
else
  c_warn "No linux-modules-extra-${KREL} package available for this kernel."
  c_warn "On WSL this is expected — see docs/environments.md for the custom-kernel steps."
fi

MODULES_OK=1
for m in "${MODULES[@]}"; do
  if $SUDO modprobe "$m" 2>/dev/null; then
    c_ok "module loaded: $m"
  else
    c_err "module NOT available: $m"
    MODULES_OK=0
  fi
done
# Persist the modules across reboots (best effort).
if [ "${MODULES_OK}" -eq 1 ]; then
  printf '%s\n' "${MODULES[@]}" | $SUDO tee "${MODULES_CONF}" >/dev/null
  c_ok "Modules will auto-load on boot (${MODULES_CONF})"
fi

# ---------------------------------------------------------------------------
step "Python virtual environment"
if [ ! -d "${VENV}" ]; then
  python3 -m venv "${VENV}"
  c_ok "Created venv at ${VENV}"
fi
# shellcheck disable=SC1091
"${VENV}/bin/pip" install --quiet --upgrade pip
# jinja2 + pyyaml: required by prepare_topology.py (core path).
# pytest: the offline test suite (maintainer; harmless for students).
# matplotlib/pandas/numpy: for plotting/ — students build their figures there.
"${VENV}/bin/pip" install --quiet jinja2 pyyaml pytest matplotlib pandas numpy
c_ok "Python dependencies installed (jinja2, pyyaml, pytest, matplotlib, pandas, numpy)"

# ---------------------------------------------------------------------------
step "Done"
if [ "${MODULES_OK}" -eq 1 ]; then
  c_ok "Install complete. Next: run 'make check' to verify the environment."
else
  c_warn "Install finished, but some kernel modules are missing."
  c_warn "Run 'make check' for details, and see docs/environments.md (WSL section)."
fi
