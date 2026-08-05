#!/usr/bin/env bash
# Live per-host throughput dashboard for a pool of HTTP-based RunPod hosts
# (tei-runpod, nli-runpod — anything exposing a monotonic request counter
# at /metrics). Not applicable to docker/bertopic-runpod/, which has no HTTP
# endpoint at all; use scripts/runpod/pod_watch.sh for that image instead.
#
# These images don't expose a GPU-utilization percentage — each exposes a
# cumulative request counter at /metrics (nli-runpod: nli_request_count;
# tei-runpod: te_request_count, spread across several Prometheus lines).
# This script polls that counter on every host and reports the DELTA per
# interval as a rate, which is the directly useful proxy for "is this GPU
# busy": a host doing real work shows a positive rate; an idle/starved host
# shows 0.0. Polling /metrics (a GET) does NOT reset any idle watchdog —
# only a real work request does — so this is safe to run alongside
# keep_alive.sh or a real workload.
#
# Hosts are passed in directly — this script has no knowledge of any
# project's own config format. If your project keeps its host(s) in its own
# config file, write a small wrapper there that extracts the URL(s) and
# calls this script with -u.
#
# Usage:
#   # nli-runpod (default metric):
#   scripts/runpod/http-pool/watch_gpu.sh -u https://<pod-id>-8080.proxy.runpod.net
#
#   # tei-runpod (override the counter name):
#   scripts/runpod/http-pool/watch_gpu.sh -u https://<pod-id>-8080.proxy.runpod.net \
#       --metric te_request_count --unit embeds/s
#
#   scripts/runpod/http-pool/watch_gpu.sh -u <url1> -u <url2>       # pool of hosts
#   scripts/runpod/http-pool/watch_gpu.sh --url-file hosts.txt -n 10
#   scripts/runpod/http-pool/watch_gpu.sh -u <url> --once            # single snapshot
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: watch_gpu.sh (-u <url>)... | --url-file <file> [-n <seconds>] [--once]
                    [--metric <name>] [--unit <label>] [--peak <n>]

  -u <url>          Base URL of a pod. Repeatable for multiple hosts.
  --url-file <file> Newline-delimited file of base URLs (alternative to -u).
  -n <seconds>      Refresh interval (default: 5).
  --once            Print one snapshot and exit (rates need >=2 passes, so the
                    first pass shows totals only).
  --metric <name>   /metrics counter to watch (default: nli_request_count).
                    Matches any line starting with <name>, excluding _bucket/
                    _sum suffixes, and sums them — same convention as this
                    repo's idle watchdogs (e.g. te_request_count for tei-runpod).
  --unit <label>    Display label for the rate (default: req/s).
  --peak <n>        Rate that fills a per-host throughput bar (default: 25).
  --no-color        Disable ANSI colour output.
  -h                Show this help.
EOF
}

declare -a URLS=()
URL_FILE=""
INTERVAL=5
ONCE=0
NOCOLOR="${NOCOLOR:-0}"
METRIC="nli_request_count"
UNIT="req/s"
BAR_PEAK=25

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) URLS+=("$2"); shift 2 ;;
    --url-file) URL_FILE="$2"; shift 2 ;;
    -n) INTERVAL="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --metric) METRIC="$2"; shift 2 ;;
    --unit) UNIT="$2"; shift 2 ;;
    --peak) BAR_PEAK="$2"; shift 2 ;;
    --no-color) NOCOLOR=1; shift ;;
    -h) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "${URL_FILE}" ]]; then
  if [[ ! -f "${URL_FILE}" ]]; then
    echo "error: url file not found: ${URL_FILE}" >&2
    exit 1
  fi
  while IFS= read -r u; do
    [[ -n "${u}" ]] && URLS+=("${u}")
  done < "${URL_FILE}"
fi

for bin in curl awk; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: required command '${bin}' not found on PATH" >&2
    exit 1
  fi
done

N=${#URLS[@]}
if [[ "${N}" -eq 0 ]]; then
  echo "error: no URLs given. Pass -u <url> (repeatable) or --url-file <file>." >&2
  usage
  exit 1
fi

# Short label = the leading pod id before "-8080.proxy...".
label_of() {
  local url="$1"
  local hostpart="${url#*://}"
  hostpart="${hostpart%%/*}"      # strip path
  hostpart="${hostpart%%.*}"      # strip .proxy.runpod.net
  echo "${hostpart%-*}"           # strip the -8080 port suffix -> bare pod id
}

# ── Colours (disabled if not a TTY, --no-color, or under --once) ─────────────
if [[ "${ONCE}" -eq 0 && -t 1 && "${NOCOLOR}" -eq 0 ]]; then
  C0=$'\033[0m'; CB=$'\033[1m'; CDIM=$'\033[2m'
  CG=$'\033[32m'; CR=$'\033[31m'; CC=$'\033[36m'; CGREY=$'\033[90m'
else
  C0=""; CB=""; CDIM=""; CG=""; CR=""; CC=""; CGREY=""
fi
# Cursor control for flicker-free in-place refresh (TTY, looping mode only):
# home the cursor, erase each line to its end (EOL), erase below the block (EOS).
if [[ "${ONCE}" -eq 0 && -t 1 ]]; then
  CUP=$'\033[H'; EOL=$'\033[K'; EOS=$'\033[J'
else
  CUP=""; EOL=""; EOS=""
fi

# Unicode block bar: value/max filled over `width` cells.
make_bar() {
  awk -v v="$1" -v m="$2" -v w="$3" 'BEGIN{
    f = (m > 0) ? int(w * v / m + 0.5) : 0;
    if (f > w) f = w; if (f < 0) f = 0;
    for (i = 0; i < f; i++) printf "\342\226\210";   # full block █
    for (i = f; i < w; i++) printf "\342\226\221";   # light shade ░
  }'
}

# Fetch the configured --metric counter for a base URL; echoes the summed
# integer, or "" on failure. Sums every matching, non-histogram-bucket/-sum
# line so this works whether the target exposes one synthetic counter line
# (nli-runpod) or several real Prometheus lines for the same family
# (tei-runpod's te_request_count).
fetch_count() {
  local base="$1"
  curl -sS --max-time 15 "${base}/metrics" 2>/dev/null \
    | awk -v m="^${METRIC}" '$0 ~ m && !/_bucket|_sum/ {sum += $NF} END {print (NR>0 && sum != "") ? sum+0 : ""}'
}

# Parallel indexed arrays for previous counts; single previous timestamp.
PREV=()
for ((i = 0; i < N; i++)); do PREV[i]=""; done
PREV_T=""

pass() {
  local now total_rate active
  now="$(date +%s)"
  local elapsed=0
  if [[ -n "${PREV_T}" ]]; then elapsed=$((now - PREV_T)); fi

  printf '%s' "${CUP}"
  printf '%s HTTP POOL %s%s· %s hosts · metric=%s · %s %s(refresh %ss)%s%s\n' \
    "${CB}${CC}" "${C0}" "${CDIM}" "${N}" "${METRIC}" "$(date '+%H:%M:%S')" "${CGREY}" "${INTERVAL}" "${C0}" "${EOL}"
  printf '%s%s%-8s%s%s\n' "${CGREY}" "  host              " "${UNIT}" "   throughput             state" "${C0}${EOL}"

  total_rate=0
  active=0
  local i base cnt prev rate state lbl sum_now=0 bar scol sdisp ratedisp
  for ((i = 0; i < N; i++)); do
    base="${URLS[i]}"
    lbl="$(label_of "${base}")"
    cnt="$(fetch_count "${base}")"
    if [[ -z "${cnt}" ]]; then
      bar="$(make_bar 0 "${BAR_PEAK}" 18)"
      printf '  %s%-16s%s %7s   %s%s%s   %sDOWN%s%s\n' \
        "${CC}" "${lbl}" "${C0}" "-" "${CR}" "${bar}" "${C0}" "${CR}${CB}" "${C0}" "${EOL}"
      PREV[i]=""
      continue
    fi
    sum_now=$((sum_now + cnt))
    prev="${PREV[i]}"
    rate=""
    state="idle"
    if [[ -n "${prev}" && "${elapsed}" -gt 0 ]]; then
      rate="$(awk -v d="$((cnt - prev))" -v e="${elapsed}" 'BEGIN{printf "%.1f", (e>0)?d/e:0}')"
      if awk -v r="${rate}" 'BEGIN{exit !(r>0)}'; then
        state="BUSY"; active=$((active + 1))
      fi
      total_rate="$(awk -v t="${total_rate}" -v r="${rate}" 'BEGIN{printf "%.1f", t+r}')"
      ratedisp="${rate}"
      bar="$(make_bar "${rate}" "${BAR_PEAK}" 18)"
    else
      ratedisp="—"
      bar="$(make_bar 0 "${BAR_PEAK}" 18)"
    fi
    if [[ "${state}" == "BUSY" ]]; then
      scol="${CG}"; sdisp="BUSY"
    else
      scol="${CGREY}"; sdisp="idle"
    fi
    printf '  %s%-16s%s %7s   %s%s%s   %s%-4s%s%s\n' \
      "${CC}" "${lbl}" "${C0}" "${ratedisp}" "${scol}" "${bar}" "${C0}" \
      "${scol}" "${sdisp}" "${C0}" "${EOL}"
    PREV[i]="${cnt}"
  done

  if [[ -n "${PREV_T}" && "${elapsed}" -gt 0 ]]; then
    printf '  %spool%s %s%s%s%s · %s%s/%s%s busy%s\n' \
      "${CGREY}" "${C0}" "${CB}" "${total_rate}" "${C0}" " ${UNIT}" \
      "${CB}" "${active}" "${N}" "${C0}" "${EOL}"
  else
    printf '  %s(rates appear after the next pass)%s%s\n' "${CDIM}" "${C0}" "${EOL}"
  fi
  printf '%s' "${EOS}"
  PREV_T="${now}"
}

if [[ "${ONCE}" -eq 1 ]]; then
  pass
  exit 0
fi

# Full clear once; subsequent passes home the cursor and overwrite in place.
# Hide the cursor while looping; restore it (and show cursor) on exit.
if [[ -t 1 ]]; then
  printf '\033[2J\033[H\033[?25l'
  trap 'printf "\033[?25h\n"; exit 0' INT TERM
fi
while true; do
  pass
  sleep "${INTERVAL}"
done
