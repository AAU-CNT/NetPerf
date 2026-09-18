#!/usr/bin/env bash
# bridges.sh — create or delete the kind:bridge Linux bridges a topology needs.
#
# containerlab does NOT create `kind: bridge` bridges (frozen decision 3), so
# `make deploy` runs `bridges.sh up` before `clab deploy`, and `make destroy`
# runs `bridges.sh down` after `clab destroy`. Idempotent and safe to re-run.
#
# Usage:
#   bridges.sh up   [--shape topology/.deploy.shape.json]
#   bridges.sh down [--shape topology/.deploy.shape.json]
#   bridges.sh list
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHAPE="${REPO_ROOT}/topology/.deploy.shape.json"

c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m•\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || { c_err "need root or sudo"; exit 1; }
  SUDO="sudo"
fi

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    up|down|list) ACTION="$1" ;;
    --shape) SHAPE="$2"; shift ;;
    -h|--help) usage 0 ;;
    *) c_err "unknown argument: $1"; usage 1 ;;
  esac
  shift
done
[ -n "${ACTION}" ] || usage 1

[ -f "${SHAPE}" ] || { c_err "shape plan not found: ${SHAPE} (run 'make deploy' first)"; exit 1; }
command -v jq >/dev/null 2>&1 || { c_err "jq is required"; exit 1; }

mapfile -t BRIDGES < <(jq -r '.bridges[]' "${SHAPE}")
[ "${#BRIDGES[@]}" -gt 0 ] || { c_info "topology has no bridges — nothing to do"; exit 0; }

bridge_up() {
  local br="$1"
  if ip link show "${br}" >/dev/null 2>&1; then
    c_info "bridge ${br} already exists"
  else
    $SUDO ip link add name "${br}" type bridge
    c_ok "created bridge ${br}"
  fi
  $SUDO ip link set "${br}" up
  # 802.1d STP + forwarding delay stalls the first ~15 s of every flow; the lab
  # wants an instant-forwarding hub, so disable both.
  $SUDO ip link set "${br}" type bridge stp_state 0 2>/dev/null || true
  $SUDO ip link set "${br}" type bridge forward_delay 0 2>/dev/null || true
}

bridge_down() {
  local br="$1"
  if ip link show "${br}" >/dev/null 2>&1; then
    $SUDO ip link set "${br}" down
    $SUDO ip link del "${br}"
    c_ok "removed bridge ${br}"
  else
    c_info "bridge ${br} not present"
  fi
}

case "${ACTION}" in
  up)   for b in "${BRIDGES[@]}"; do bridge_up "$b"; done ;;
  down) for b in "${BRIDGES[@]}"; do bridge_down "$b"; done ;;
  list) for b in "${BRIDGES[@]}"; do
          if ip link show "$b" >/dev/null 2>&1; then echo "$b  up"; else echo "$b  absent"; fi
        done ;;
esac
