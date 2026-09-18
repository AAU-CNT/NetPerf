#!/usr/bin/env bash
# impair.sh — shape link ends with tc (frozen decision 4).
#
# Every shaped interface gets an egress chain:  htb (rate) -> netem
# (delay / jitter / loss / limit).  tc is egress-only, so both ends of a link
# are shaped for a symmetric bottleneck.  Re-running replaces the chain.
#
#   impair.sh apply                     apply the plan compiled from the *.clab.yml
#                                       (this is what `make deploy` runs)
#   impair.sh set  --rate 10mbit --delay 5ms --loss 1 [--jitter 1ms] [--limit 1000]
#                                       retune one link in place (default: the
#                                       bottleneck) — no redeploy
#   impair.sh show                      print `tc -s qdisc` for every shaped iface
#   impair.sh clear                     remove shaping from every iface in the plan
#
# Options:
#   --shape PATH   shape plan (default: topology/.deploy.shape.json)
#   --match NAME   with `set`: link role ("bottleneck") or "<a>-<b>" node pair
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHAPE="${REPO_ROOT}/topology/.deploy.shape.json"

c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m•\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || { c_err "need root or sudo"; exit 1; }
  SUDO="sudo"
fi
command -v jq >/dev/null 2>&1 || { c_err "jq is required"; exit 1; }

# --------------------------------------------------------------------------- #
# arg parsing
# --------------------------------------------------------------------------- #
ACTION=""
MATCH="bottleneck"
O_RATE="" O_DELAY="" O_JITTER="" O_LOSS="" O_LIMIT=""
have_override=0
while [ $# -gt 0 ]; do
  case "$1" in
    apply|set|show|clear) ACTION="$1" ;;
    --shape)  SHAPE="$2"; shift ;;
    --match)  MATCH="$2"; shift ;;
    --rate)   O_RATE="$2"; have_override=1; shift ;;
    --delay)  O_DELAY="$2"; have_override=1; shift ;;
    --jitter) O_JITTER="$2"; have_override=1; shift ;;
    --loss)   O_LOSS="$2"; have_override=1; shift ;;
    --limit)  O_LIMIT="$2"; have_override=1; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) c_err "unknown argument: $1"; exit 1 ;;
  esac
  shift
done
if [ -z "${ACTION}" ]; then
  if [ "${have_override}" -eq 1 ]; then ACTION="set"; else ACTION="apply"; fi
fi

[ -f "${SHAPE}" ] || { c_err "shape plan not found: ${SHAPE}"; exit 1; }

# normalise a rate: bare number -> kbit/s (matches the assignment + Makefile)
norm_rate() {
  local r="${1:-}"
  [ -z "${r}" ] && { echo ""; return; }
  case "${r}" in
    *[a-zA-Z]*) echo "${r}" ;;
    *)          echo "${r}kbit" ;;
  esac
}

# --------------------------------------------------------------------------- #
# per-interface tc application
# --------------------------------------------------------------------------- #
# runner for an endpoint: prints a command prefix that runs in its netns
endpoint_runner() {
  local netns="$1" container="$2"
  if [ "${netns}" = "host" ]; then
    echo "${SUDO}"
  else
    local pid
    pid="$($SUDO docker inspect -f '{{.State.Pid}}' "${container}" 2>/dev/null || true)"
    if [ -z "${pid}" ] || [ "${pid}" = "0" ]; then echo "__ERR__"; return; fi
    echo "${SUDO} nsenter -t ${pid} -n"
  fi
}

disable_offload() {
  local runner="$1" iface="$2"
  command -v ethtool >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2086
  $runner ethtool -K "${iface}" tso off gso off gro off 2>/dev/null || true
}

# clear_iface <runner...> <iface>
clear_iface() {
  local iface="${*: -1}"; local runner=("${@:1:$#-1}")
  "${runner[@]}" tc qdisc del dev "${iface}" root 2>/dev/null || true
}

# shape_iface <runner-string> <iface> <rate> <delay> <jitter> <loss> <limit>
shape_iface() {
  local runner_str="$1" iface="$2" rate="$3" delay="$4" jitter="$5" loss="$6" limit="$7"
  read -r -a runner <<<"${runner_str}"

  if [ "${runner_str}" = "__ERR__" ]; then
    c_warn "skip ${iface}: container not running"; return
  fi

  clear_iface "${runner[@]}" "${iface}"

  local has_loss=0
  awk "BEGIN{exit !(${loss:-0} > 0)}" && has_loss=1
  if [ -z "${rate}" ] && [ -z "${delay}" ] && [ "${has_loss}" -eq 0 ]; then
    c_info "${iface}: unshaped"; return
  fi

  disable_offload "${runner[*]}" "${iface}" >/dev/null 2>&1 || true
  read -r -a runner <<<"${runner_str}"

  local parent
  if [ -n "${rate}" ]; then
    "${runner[@]}" tc qdisc add dev "${iface}" root handle 1: htb default 10
    "${runner[@]}" tc class add dev "${iface}" parent 1: classid 1:10 htb rate "${rate}" ceil "${rate}"
    parent=(parent 1:10 handle 10:)
  else
    parent=(root handle 10:)
  fi

  local netem=(netem)
  [ -n "${delay}" ] && { netem+=(delay "${delay}"); [ -n "${jitter}" ] && netem+=("${jitter}"); }
  [ "${has_loss}" -eq 1 ] && netem+=(loss "${loss}%")
  [ -n "${limit}" ] && [ "${limit}" != "0" ] && netem+=(limit "${limit}")

  "${runner[@]}" tc qdisc add dev "${iface}" "${parent[@]}" "${netem[@]}"
  c_ok "${iface}: rate=${rate:-∞} delay=${delay:-0} jitter=${jitter:-0} loss=${loss:-0}% limit=${limit:-default}"
}

# iterate endpoints of link at json index $1, calling $2 with resolved params
each_endpoint() {
  local idx="$1" fn="$2"
  local n_ep; n_ep="$(jq -r ".links[${idx}].endpoints | length" "${SHAPE}")"
  local e
  for ((e = 0; e < n_ep; e++)); do
    local netns container iface
    netns="$(jq -r ".links[${idx}].endpoints[${e}].netns" "${SHAPE}")"
    container="$(jq -r ".links[${idx}].endpoints[${e}].container // \"\"" "${SHAPE}")"
    iface="$(jq -r ".links[${idx}].endpoints[${e}].iface" "${SHAPE}")"
    "${fn}" "$(endpoint_runner "${netns}" "${container}")" "${iface}" "${idx}"
  done
}

# --------------------------------------------------------------------------- #
# actions
# --------------------------------------------------------------------------- #
link_indices_all() { jq -r '.links | to_entries[] | .key' "${SHAPE}"; }

link_index_match() {
  # role match first, then "<a>-<b>" / "<b>-<a>" node-pair match
  local want="$1" idx
  idx="$(jq -r --arg r "${want}" 'first((.links | to_entries[] | select(.value.role == $r) | .key)) // empty' "${SHAPE}")"
  if [ -z "${idx}" ]; then
    local a="${want%%-*}" b="${want##*-}"
    idx="$(jq -r --arg a "$a" --arg b "$b" '
      first((.links | to_entries[] | select(
        ([.value.endpoints[].node] | sort) == ([$a,$b] | sort)) | .key)) // empty' "${SHAPE}")"
  fi
  echo "${idx}"
}

do_apply() {
  c_info "applying shape plan from ${SHAPE}"
  local idx
  while read -r idx; do
    local p; p="$(jq -c ".links[${idx}].params" "${SHAPE}")"
    local rate delay jitter loss limit
    rate="$(norm_rate "$(jq -r '.rate' <<<"$p")")"
    delay="$(jq -r '.delay' <<<"$p")"; [ "${delay}" = "null" ] && delay=""
    jitter="$(jq -r '.jitter' <<<"$p")"; [ "${jitter}" = "null" ] && jitter=""
    loss="$(jq -r '.loss' <<<"$p")"
    limit="$(jq -r '.limit' <<<"$p")"
    each_endpoint "${idx}" _apply_ep
  done < <(link_indices_all)
}
# shellcheck disable=SC2317
_apply_ep() { shape_iface "$1" "$2" "${rate}" "${delay}" "${jitter}" "${loss}" "${limit}"; }

do_set() {
  local idx; idx="$(link_index_match "${MATCH}")"
  [ -n "${idx}" ] || { c_err "no link matches --match ${MATCH}"; exit 1; }
  local rate delay jitter loss limit
  rate="$(norm_rate "${O_RATE}")"
  delay="${O_DELAY}"; jitter="${O_JITTER}"
  loss="${O_LOSS:-0}"
  limit="${O_LIMIT:-$(jq -r ".links[${idx}].params.limit" "${SHAPE}")}"
  c_info "shaping link #${idx} (--match ${MATCH})"
  each_endpoint "${idx}" _set_ep
}
# shellcheck disable=SC2317
_set_ep() { shape_iface "$1" "$2" "${rate}" "${delay}" "${jitter}" "${loss}" "${limit}"; }

do_show() {
  local idx
  while read -r idx; do each_endpoint "${idx}" _show_ep; done < <(link_indices_all)
}
# shellcheck disable=SC2317
_show_ep() {
  local runner_str="$1" iface="$2"
  [ "${runner_str}" = "__ERR__" ] && return
  read -r -a runner <<<"${runner_str}"
  printf '\033[1m── %s ──\033[0m\n' "${iface}"
  "${runner[@]}" tc -s qdisc show dev "${iface}" 2>/dev/null || true
  "${runner[@]}" tc class show dev "${iface}" 2>/dev/null || true
}

do_clear() {
  local idx
  while read -r idx; do each_endpoint "${idx}" _clear_ep; done < <(link_indices_all)
  c_ok "cleared shaping on all planned interfaces"
}
# shellcheck disable=SC2317
_clear_ep() {
  local runner_str="$1" iface="$2"
  [ "${runner_str}" = "__ERR__" ] && return
  read -r -a runner <<<"${runner_str}"
  clear_iface "${runner[@]}" "${iface}"
}

case "${ACTION}" in
  apply) do_apply ;;
  set)   do_set ;;
  show)  do_show ;;
  clear) do_clear ;;
esac
