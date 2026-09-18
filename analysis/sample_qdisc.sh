#!/usr/bin/env bash
# sample_qdisc.sh — poll `tc -s qdisc` on the bottleneck interface(s) at a fixed
# interval and append rows to a CSV (schema: analysis/SCHEMA.md, qdisc.csv).
#
#   sample_qdisc.sh --shape topology/.deploy.shape.json --duration 60 \
#                   --interval 0.5 --out results/run/qdisc.csv
#
# With no --iface, every "bottleneck"-role link end in the shape plan is polled
# (host netns bridge veths). Pass --iface repeatedly to override.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHAPE="${REPO_ROOT}/topology/.deploy.shape.json"
DURATION=60
INTERVAL=0.5
OUT=""
declare -a IFACES=()

c_err() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

while [ $# -gt 0 ]; do
  case "$1" in
    --shape)    SHAPE="$2"; shift ;;
    --duration) DURATION="$2"; shift ;;
    --interval) INTERVAL="$2"; shift ;;
    --iface)    IFACES+=("$2"); shift ;;
    --out)      OUT="$2"; shift ;;
    -h|--help)  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) c_err "unknown argument: $1"; exit 1 ;;
  esac
  shift
done

[ -n "${OUT}" ] || { c_err "--out is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { c_err "jq is required"; exit 1; }

if [ "${#IFACES[@]}" -eq 0 ]; then
  [ -f "${SHAPE}" ] || { c_err "shape plan not found: ${SHAPE}"; exit 1; }
  mapfile -t IFACES < <(jq -r '
    .links[] | select(.role == "bottleneck")
    | .endpoints[] | select(.netns == "host") | .iface' "${SHAPE}")
fi
[ "${#IFACES[@]}" -gt 0 ] || { c_err "no bottleneck interfaces to sample"; exit 1; }

mkdir -p "$(dirname "${OUT}")"
[ -s "${OUT}" ] || echo "timestamp,iface,backlog_bytes,backlog_pkts,drops,overlimits" > "${OUT}"

# Parse one `tc -s qdisc show dev X` blob. The numbers we want appear as:
#   Sent N bytes P pkt (dropped D, overlimits O requeues R)
#   backlog 12345b 7p requeues 0
parse_tc() {
  awk -v ts="$1" -v ifc="$2" '
    /dropped/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "(dropped") { d = $(i+1); gsub(/,/, "", d) }
        if ($i == "overlimits") { o = $(i+1); gsub(/,/, "", o) }
      }
    }
    /^ backlog/ || /backlog [0-9]/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "backlog") {
          b = $(i+1); p = $(i+2)
          sub(/b$/, "", b); sub(/p$/, "", p)
        }
      }
    }
    END {
      printf "%s,%s,%s,%s,%s,%s\n", ts, ifc,
             (b == "" ? 0 : b), (p == "" ? 0 : p),
             (d == "" ? 0 : d), (o == "" ? 0 : o)
    }'
}

end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "${end}" ]; do
  now="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  for ifc in "${IFACES[@]}"; do
    blob="$($SUDO tc -s qdisc show dev "${ifc}" 2>/dev/null || true)"
    [ -n "${blob}" ] || continue
    printf '%s\n' "${blob}" | parse_tc "${now}" "${ifc}" >> "${OUT}"
  done
  sleep "${INTERVAL}"
done
