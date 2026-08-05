#!/usr/bin/env bash
# Reset the idle-watchdog counter on one or more nli-runpod hosts, by sending
# a trivial /classify request. The watchdog
# (docker/nli-runpod/nli_idle_watchdog.sh) resets its idle timer whenever the
# server's cumulative request count changes — /health and /metrics don't
# count, only /classify does.
#
# Useful for keeping provisioned pods alive between real scoring runs, or
# while testing, without letting IDLE_MIN auto-stop them.
#
# Hosts are passed in directly — this script has no knowledge of any
# project's own config format. If your project keeps its NLI host(s) in its
# own config file, write a small wrapper there that extracts the URL(s) and
# calls this script with -u, e.g.:
#   scripts/runpod/nli/keep_alive.sh -u "$(my_project_get_nli_url)"
#
# Usage:
#   scripts/runpod/nli/keep_alive.sh -u https://<pod-id>-8080.proxy.runpod.net
#   scripts/runpod/nli/keep_alive.sh -u <url1> -u <url2>          # multiple hosts
#   scripts/runpod/nli/keep_alive.sh --url-file hosts.txt          # newline-delimited
#   scripts/runpod/nli/keep_alive.sh -u <url> --loop 240           # repeat every 240s
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: keep_alive.sh (-u <url>)... | --url-file <file> [--loop <seconds>]

  -u <url>          Base URL of an nli-runpod host (e.g. https://<pod-id>-8080.proxy.runpod.net).
                    Repeatable for multiple hosts.
  --url-file <file> Newline-delimited file of base URLs (alternative to -u).
  --loop <seconds>  Repeat indefinitely, sleeping <seconds> between passes. Omit for a single pass.
  -h                Show this help.
EOF
}

declare -a URLS=()
URL_FILE=""
LOOP_SECONDS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) URLS+=("$2"); shift 2 ;;
    --url-file) URL_FILE="$2"; shift 2 ;;
    --loop) LOOP_SECONDS="$2"; shift 2 ;;
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

if [[ "${#URLS[@]}" -eq 0 ]]; then
  echo "error: no URLs given. Pass -u <url> (repeatable) or --url-file <file>." >&2
  usage
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "error: required command 'curl' not found on PATH" >&2
  exit 1
fi

ping_once() {
  local n=0
  local ok=0
  for base_url in "${URLS[@]}"; do
    [[ -z "${base_url}" ]] && continue
    n=$((n + 1))
    http_code="$(
      curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
        -X POST "${base_url}/classify" \
        -H "Content-Type: application/json" \
        -d '{
          "sequences": ["keepalive"],
          "candidate_labels": ["supports", "refutes", "is not relevant to"],
          "hypothesis_template": "This example {} the following claim: keepalive.",
          "batch_size": 1
        }' 2>/dev/null || echo "000"
    )"
    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
      echo "  [$(date '+%H:%M:%S')] ${base_url} OK" >&2
      ok=$((ok + 1))
    else
      echo "  [$(date '+%H:%M:%S')] ${base_url} FAILED (HTTP ${http_code})" >&2
    fi
  done

  echo "pinged ${ok}/${n} host(s)" >&2
}

if [[ -n "${LOOP_SECONDS}" ]]; then
  echo "Looping every ${LOOP_SECONDS}s. Ctrl-C to stop." >&2
  while true; do
    ping_once
    sleep "${LOOP_SECONDS}"
  done
else
  ping_once
fi
