#!/usr/bin/env bash
# Reset the idle-watchdog counter on one or more HTTP-pool RunPod hosts, by
# sending a real work request. Every idle watchdog in this repo
# (tei_idle_watchdog.sh, nli_idle_watchdog.sh) resets its idle timer only when
# the server's cumulative REQUEST counter changes — polling /health or
# /metrics does NOT count, only a real work request does.
#
# Because each image's work endpoint has a different contract, the endpoint
# path and request body are parameters, not hardcoded. Defaults below match
# nli-runpod's /classify; pass --path/--body to target a different image
# (see examples).
#
# Hosts are passed in directly — this script has no knowledge of any
# project's own config format. If your project keeps its host(s) in its own
# config file, write a small wrapper there that extracts the URL(s) and
# calls this script with -u, e.g.:
#   scripts/runpod/http-pool/keep_alive.sh -u "$(my_project_get_host_url)"
#
# Not applicable to docker/bertopic-runpod/ — that image has no HTTP
# endpoint at all (SSH-only); keep it alive by touching /work/.heartbeat
# over SSH instead, or see scripts/runpod/pod_watch.sh.
#
# Usage:
#   # nli-runpod (default path/body):
#   scripts/runpod/http-pool/keep_alive.sh -u https://<pod-id>-8080.proxy.runpod.net
#
#   # tei-runpod (override path/body for its /embed contract):
#   scripts/runpod/http-pool/keep_alive.sh -u https://<pod-id>-8080.proxy.runpod.net \
#       --path /embed --body '{"inputs":"keepalive"}'
#
#   scripts/runpod/http-pool/keep_alive.sh -u <url1> -u <url2>     # multiple hosts
#   scripts/runpod/http-pool/keep_alive.sh --url-file hosts.txt   # newline-delimited
#   scripts/runpod/http-pool/keep_alive.sh -u <url> --loop 240    # repeat every 240s
set -euo pipefail

DEFAULT_BODY='{
  "sequences": ["keepalive"],
  "candidate_labels": ["supports", "refutes", "is not relevant to"],
  "hypothesis_template": "This example {} the following claim: keepalive.",
  "batch_size": 1
}'

usage() {
  cat <<EOF
Usage: keep_alive.sh (-u <url>)... | --url-file <file> [--loop <seconds>]
                     [--method <verb>] [--path <path>] [--body <json> | --body-file <file>]

  -u <url>          Base URL of a pod (e.g. https://<pod-id>-8080.proxy.runpod.net).
                    Repeatable for multiple hosts.
  --url-file <file> Newline-delimited file of base URLs (alternative to -u).
  --loop <seconds>  Repeat indefinitely, sleeping <seconds> between passes. Omit for a single pass.
  --method <verb>   HTTP method (default: POST).
  --path <path>     Work endpoint path (default: /classify — nli-runpod's contract).
  --body <json>     Request body (default: an nli-runpod /classify keepalive payload).
  --body-file <file> Read the request body from a file instead of --body.
  -h                Show this help.

Examples:
  --path /classify --body '${DEFAULT_BODY}'   (nli-runpod, the default)
  --path /embed    --body '{"inputs":"keepalive"}'   (tei-runpod)
EOF
}

declare -a URLS=()
URL_FILE=""
LOOP_SECONDS=""
METHOD="POST"
PATH_SUFFIX="/classify"
BODY="${DEFAULT_BODY}"
BODY_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) URLS+=("$2"); shift 2 ;;
    --url-file) URL_FILE="$2"; shift 2 ;;
    --loop) LOOP_SECONDS="$2"; shift 2 ;;
    --method) METHOD="$2"; shift 2 ;;
    --path) PATH_SUFFIX="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    -h) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "${BODY_FILE}" ]]; then
  if [[ ! -f "${BODY_FILE}" ]]; then
    echo "error: body file not found: ${BODY_FILE}" >&2
    exit 1
  fi
  BODY="$(cat "${BODY_FILE}")"
fi

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
        -X "${METHOD}" "${base_url}${PATH_SUFFIX}" \
        -H "Content-Type: application/json" \
        -d "${BODY}" 2>/dev/null || echo "000"
    )"
    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
      echo "  [$(date '+%H:%M:%S')] ${base_url}${PATH_SUFFIX} OK" >&2
      ok=$((ok + 1))
    else
      echo "  [$(date '+%H:%M:%S')] ${base_url}${PATH_SUFFIX} FAILED (HTTP ${http_code})" >&2
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
