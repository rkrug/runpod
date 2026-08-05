#!/usr/bin/env bash
# Stop or delete pods created by create_pods.sh, using the RunPod REST API
# (https://rest.runpod.io/v1) — no runpodctl install required.
#
# By default STOPS pods (GPU billing stops; pod stays allocated and can be
# resumed later, e.g. via the RunPod console or POST /pods/{id}/start).
# Pass -d/--delete to permanently remove pods instead (stops ALL billing,
# including storage, but the pod cannot be resumed afterward).
#
# Usage:
#   export RUNPOD_API_KEY=...
#   scripts/runpod/stop_pods.sh                      # stop every pod in hosts.generated.csv
#   scripts/runpod/stop_pods.sh -d                    # delete every pod in hosts.generated.csv
#   scripts/runpod/stop_pods.sh -i podid1 -i podid2   # target specific pod ids instead
#   scripts/runpod/stop_pods.sh -f other_hosts.csv    # use a different inventory file
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: stop_pods.sh [-f <hosts-csv>] [-i <pod-id>]... [-d|--delete]

  -f <hosts-csv>  Inventory CSV with an `id` column (default: scripts/runpod/hosts.generated.csv).
  -i <pod-id>     Target this pod id instead of reading the CSV. Repeatable.
  -d, --delete    Permanently delete pods instead of just stopping them.
  -h              Show this help.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_CSV="${SCRIPT_DIR}/hosts.generated.csv"
DELETE=0
declare -a EXPLICIT_IDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) HOSTS_CSV="$2"; shift 2 ;;
    -i) EXPLICIT_IDS+=("$2"); shift 2 ;;
    -d|--delete) DELETE=1; shift ;;
    -h) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
  esac
done

for bin in curl jq; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: required command '${bin}' not found on PATH" >&2
    exit 1
  fi
done

if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
  echo "error: RUNPOD_API_KEY is not set. export RUNPOD_API_KEY=... first." >&2
  exit 1
fi

declare -a POD_IDS=()
declare -a POD_NAMES=()
USED_CSV=0

if [[ "${#EXPLICIT_IDS[@]}" -gt 0 ]]; then
  POD_IDS=("${EXPLICIT_IDS[@]}")
  POD_NAMES=("${EXPLICIT_IDS[@]}")
else
  if [[ ! -f "${HOSTS_CSV}" ]]; then
    echo "error: inventory file not found: ${HOSTS_CSV}" >&2
    echo "       pass -i <pod-id> to target pods directly, or -f <csv> for a different inventory." >&2
    exit 1
  fi
  USED_CSV=1
  while IFS=, read -r id name host; do
    [[ "${id}" == "id" ]] && continue   # skip header
    [[ -z "${id}" ]] && continue
    POD_IDS+=("${id}")
    POD_NAMES+=("${name}")
  done < "${HOSTS_CSV}"
fi

if [[ "${#POD_IDS[@]}" -eq 0 ]]; then
  echo "No pods to act on." >&2
  exit 0
fi

API_BASE="https://rest.runpod.io/v1"
if [[ "${DELETE}" -eq 1 ]]; then
  ACTION_VERB="Deleting"
  ACTION_METHOD="DELETE"
  ACTION_PATH_SUFFIX=""
else
  ACTION_VERB="Stopping"
  ACTION_METHOD="POST"
  ACTION_PATH_SUFFIX="/stop"
fi

echo "${ACTION_VERB} ${#POD_IDS[@]} pod(s)..." >&2

failures=0
for idx in "${!POD_IDS[@]}"; do
  id="${POD_IDS[$idx]}"
  name="${POD_NAMES[$idx]}"

  http_code="$(
    curl -sS -o /tmp/stop_pods_resp.json -w '%{http_code}' \
      -X "${ACTION_METHOD}" "${API_BASE}/pods/${id}${ACTION_PATH_SUFFIX}" \
      -H "Authorization: Bearer ${RUNPOD_API_KEY}"
  )"

  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    echo "  [$((idx + 1))/${#POD_IDS[@]}] ${ACTION_VERB%ing}ed ${name} (${id})" >&2
  else
    echo "  [$((idx + 1))/${#POD_IDS[@]}] FAILED for ${name} (${id}) — HTTP ${http_code}:" >&2
    jq . /tmp/stop_pods_resp.json >&2 2>/dev/null || cat /tmp/stop_pods_resp.json >&2
    failures=$((failures + 1))
  fi
done
rm -f /tmp/stop_pods_resp.json

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures}/${#POD_IDS[@]} pod(s) failed — see above." >&2
  exit 1
fi

# All pods actioned successfully via the generated inventory (not explicit
# -i ids) — the inventory now refers to pods that no longer exist/are
# stopped, so remove it to avoid accidentally reusing stale pod ids.
if [[ "${USED_CSV}" -eq 1 ]]; then
  rm -f "${HOSTS_CSV}"
  rm -f "${SCRIPT_DIR}/hosts.generated.yaml"
  echo "Removed ${HOSTS_CSV} and hosts.generated.yaml." >&2
fi

echo "Done." >&2
