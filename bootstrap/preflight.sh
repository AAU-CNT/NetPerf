#!/usr/bin/env bash
# preflight.sh — verify this machine is ready to run the NetPerf25 labs.
# Safe to run anytime. Exits 0 and prints "ENV OK" when everything passes,
# otherwise prints what failed and exits non-zero.
set -uo pipefail   # NOTE: no -e; we want to run every check and report all.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${REPO_ROOT}/.venv"
MODULES=(sch_netem tcp_vegas tcp_bbr)

pass=0; fail=0
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '\033[31m  ✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
head() { printf '\n\033[1m%s\033[0m\n' "$*"; }

SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

head "Privileges"
if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; then
  ok "root or sudo available"
else
  bad "no root/sudo — the labs need NET_ADMIN for tc/netem"
fi

head "Core tools"
for t in docker git make jq tc ss iperf3; do
  if command -v "$t" >/dev/null 2>&1; then ok "found: $t"; else bad "missing: $t"; fi
done
if command -v clab >/dev/null 2>&1 || command -v containerlab >/dev/null 2>&1; then
  ok "found: containerlab ($(clab version 2>/dev/null | awk '/version/{print $2; exit}' || echo present))"
else
  bad "missing: containerlab"
fi

head "Docker daemon"
if docker info >/dev/null 2>&1; then
  ok "docker daemon reachable without sudo"
elif $SUDO docker info >/dev/null 2>&1; then
  warn "docker works only with sudo — run 'newgrp docker' or log out/in"
  ok "docker daemon reachable (via sudo)"
else
  bad "docker daemon not reachable (is it running?)"
fi

head "Kernel modules"
for m in "${MODULES[@]}"; do
  if $SUDO modprobe "$m" 2>/dev/null && lsmod 2>/dev/null | grep -qw "$m" \
     || $SUDO modprobe -n "$m" 2>/dev/null; then
    ok "available: $m"
  else
    bad "unavailable: $m  (WSL? see docs/environments.md)"
  fi
done

head "netem live test (add + delete on lo)"
if $SUDO tc qdisc add dev lo root netem delay 1ms 2>/dev/null; then
  $SUDO tc qdisc del dev lo root 2>/dev/null || true
  ok "tc netem works on lo"
else
  $SUDO tc qdisc del dev lo root 2>/dev/null || true
  bad "tc netem failed — sch_netem not usable on this kernel"
fi

head "Congestion control algorithms"
avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '')"
for cc in reno cubic vegas bbr; do
  if grep -qw "$cc" <<<"$avail"; then ok "cc available: $cc"; else warn "cc not loaded yet: $cc (modprobe tcp_$cc)"; fi
done

head "Python venv"
if [ -x "${VENV}/bin/python" ]; then
  if "${VENV}/bin/python" -c "import jinja2, yaml" 2>/dev/null; then
    ok "venv ready with jinja2 + pyyaml (prepare_topology.py)"
  else
    bad "venv exists but is missing jinja2/pyyaml — re-run 'make bootstrap'"
  fi
  if "${VENV}/bin/python" -c "import pytest" 2>/dev/null; then
    ok "venv has pytest (make test)"
  else
    warn "no pytest in the venv — 'make test' will not run"
  fi
  if "${VENV}/bin/python" -c "import matplotlib, pandas, numpy" 2>/dev/null; then
    ok "venv has matplotlib+pandas+numpy (plotting/)"
  else
    warn "no matplotlib/pandas/numpy — needed for plotting/ (re-run 'make bootstrap')"
  fi
else
  bad "no venv at ${VENV} — run 'make bootstrap'"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1mSummary:\033[0m %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '\033[32m\033[1mENV OK\033[0m — you are ready to run the labs.\n'
  exit 0
else
  printf '\033[31m\033[1mENV NOT READY\033[0m — fix the ✗ items above.\n'
  printf 'On WSL, missing modules usually mean a custom kernel is needed: see docs/environments.md\n'
  exit 1
fi
