#!/usr/bin/env bash
# sample_cwnd.sh — poll `ss -tin` inside each source container at a fixed
# interval and append rows to a CSV (schema: analysis/SCHEMA.md, ss.csv).
#
#   sample_cwnd.sh --shape topology/.deploy.shape.json --duration 60 \
#                  --interval 0.5 --out results/run/ss.csv [--port 5201]
#
# For every non-bridge node in the shape plan it runs `ss -tin state established`
# and extracts cwnd (segments), srtt (ms), and cumulative retransmits per
# socket. The `flow` label is "<node>-><peer>" resolved from the peer IP.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHAPE="${REPO_ROOT}/topology/.deploy.shape.json"
DURATION=60
INTERVAL=0.5
PORT=""
OUT=""

c_err() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

while [ $# -gt 0 ]; do
  case "$1" in
    --shape)    SHAPE="$2"; shift ;;
    --duration) DURATION="$2"; shift ;;
    --interval) INTERVAL="$2"; shift ;;
    --port)     PORT="$2"; shift ;;
    --out)      OUT="$2"; shift ;;
    -h|--help)  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) c_err "unknown argument: $1"; exit 1 ;;
  esac
  shift
done

[ -n "${OUT}" ] || { c_err "--out is required"; exit 1; }
[ -f "${SHAPE}" ] || { c_err "shape plan not found: ${SHAPE}"; exit 1; }
command -v jq >/dev/null 2>&1 || { c_err "jq is required"; exit 1; }

# ip -> node map from the plan (used to label flows by their peer)
declare -A NODE_AT
while IFS=$'\t' read -r node ip; do
  NODE_AT["${ip}"]="${node}"
done < <(jq -r '.ips | to_entries[] | "\(.key)\t\(.value)"' "${SHAPE}")

# source containers = non-bridge endpoints that appear on a link to a bridge
mapfile -t SRC_NODES < <(jq -r '
  [ .links[].endpoints[] | select(.netns == "container") | .node ] | unique[]' "${SHAPE}")
[ "${#SRC_NODES[@]}" -gt 0 ] || { c_err "no container nodes in the plan"; exit 1; }

declare -A CTR_OF
while IFS=$'\t' read -r node ctr; do CTR_OF["${node}"]="${ctr}"; done < <(jq -r '
  .links[].endpoints[] | select(.netns == "container") | "\(.node)\t\(.container)"' "${SHAPE}" | sort -u)

mkdir -p "$(dirname "${OUT}")"
[ -s "${OUT}" ] || echo "timestamp,flow,cwnd,rtt_ms,retrans" > "${OUT}"

filter=(state established)
[ -n "${PORT}" ] && filter+=( "(" dport "=" ":${PORT}" or sport "=" ":${PORT}" ")" )

# Parse `ss -tin` output. Records span two lines: a socket line with the peer
# address, then an indented metrics line containing cwnd:/rtt:/retrans:.
parse_ss() {
  local node="$1" ts="$2"
  awk -v node="${node}" -v ts="${ts}" '
    function flush(  n) {
      if (peer == "") return
      n = peernode[peer]; if (n == "") n = peer
      printf "%s,%s->%s,%s,%s,%s\n", ts, node, n, cwnd, rtt, retr
      peer = ""; cwnd = ""; rtt = ""; retr = ""
    }
    BEGIN {
      # peer-ip -> node table passed via environment PEERS="ip=node;ip=node"
      m = ENVIRON["PEERS"]; np = split(m, kv, ";")
      for (i = 1; i <= np; i++) { split(kv[i], a, "="); if (a[1] != "") peernode[a[1]] = a[2] }
    }
    /^ESTAB|ESTAB/ && $0 ~ /:/ {
      flush()
      # last two whitespace fields are local and peer addr:port
      paddr = $(NF); sub(/:[0-9]+$/, "", paddr)
      gsub(/[][]/, "", paddr)
      peer = paddr
    }
    /cwnd:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^cwnd:/)    { split($i, x, ":"); cwnd = x[2] }
        if ($i ~ /^rtt:/)     { split($i, x, ":"); split(x[2], y, "/"); rtt = y[1] }
        if ($i ~ /^retrans:/) { split($i, x, ":"); split(x[2], y, "/"); retr = y[2] }
      }
    }
    END { flush() }'
}

# build PEERS env string once
peers=""
for ip in "${!NODE_AT[@]}"; do peers="${peers}${ip}=${NODE_AT[$ip]};"; done
export PEERS="${peers}"

end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "${end}" ]; do
  now="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  for node in "${SRC_NODES[@]}"; do
    ctr="${CTR_OF[$node]:-}"; [ -n "${ctr}" ] || continue
    out="$($SUDO docker exec "${ctr}" ss -tin "${filter[@]}" 2>/dev/null || true)"
    [ -n "${out}" ] || continue
    printf '%s\n' "${out}" | parse_ss "${node}" "${now}" >> "${OUT}"
  done
  sleep "${INTERVAL}"
done
