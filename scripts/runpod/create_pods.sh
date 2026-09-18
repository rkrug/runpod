#!/usr/bin/env bash
# Create and start N RunPod pods from a config file (see
# config/pods.conf.tei.example / config/pods.conf.bertopic.example /
# config/pods.conf.nli.example / config/pods.conf.example). Uses the
# RunPod REST API directly (https://rest.runpod.io/v1/pods) — no runpodctl
# install required on the calling machine.
#
# Two pod shapes are supported via POD_KIND in the config file:
#
#   POD_KIND=http (default) — an HTTP service exposed through RunPod's proxy
#     (e.g. the TEI/SPECTER2 or NLI servers). Readiness = polling
#     https://<pod-id>-<PORT>.proxy.runpod.net<HEALTH_PATH> until it returns
#     HTTP 2xx — i.e. the service itself is serving, not merely the proxy
#     answering with a "pod starting" 502. Only once ready does it print the
#     ready-to-paste `host:` line for your project's config.
#
#   POD_KIND=tcp — a raw TCP service reached via RunPod's public-IP port
#     mapping (e.g. the bertopic pod's sshd on port 22). Readiness = polling
#     GET /pods/{id} until `publicIp` + `portMappings["<PORT>"]` are
#     populated. Prints a ready-to-paste `ssh_host:`/`ssh_port:` block.
#
# In both cases the script does not edit any project config itself — paste
# the printed block into your own project's config. Also writes
# hosts.generated.csv (id,name,host,port) for later teardown via
# stop_pods.sh.
#
# Usage:
#   export RUNPOD_API_KEY=...          # required: RunPod account API key
#   cp scripts/runpod/config/pods.conf.tei.example scripts/runpod/config/pods.conf
#   $EDITOR scripts/runpod/config/pods.conf
#   scripts/runpod/create_pods.sh -n 1
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: create_pods.sh -n <count> [-c <config-file>] [-o <output-csv>]

  -n <count>       Number of pods to create (required, positive integer).
  -c <config-file> Path to a pods.conf-style config (default: scripts/runpod/config/pods.conf).
  -o <output-csv>  Where to write id,name,host,port (default: scripts/runpod/hosts.generated.csv).
  -h               Show this help.

Set CREATE_DELAY_SEC in pods.conf to change the stagger between pod-creation
calls (default: 10s; set to 0 to disable).
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/pods.conf"
OUT_CSV="${SCRIPT_DIR}/hosts.generated.csv"
COUNT=""

while getopts "n:c:o:h" opt; do
  case "${opt}" in
    n) COUNT="${OPTARG}" ;;
    c) CONFIG_FILE="${OPTARG}" ;;
    o) OUT_CSV="${OPTARG}" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "${COUNT}" ]]; then
  echo "error: -n <count> is required" >&2
  usage
  exit 1
fi
if ! [[ "${COUNT}" =~ ^[0-9]+$ ]] || [[ "${COUNT}" -lt 1 ]]; then
  echo "error: -n must be a positive integer, got '${COUNT}'" >&2
  exit 1
fi

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

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "error: config file not found: ${CONFIG_FILE}" >&2
  echo "       copy scripts/runpod/config/pods.conf.tei.example, pods.conf.bertopic.example," >&2
  echo "       or pods.conf.nli.example to ${CONFIG_FILE} to get started." >&2
  exit 1
fi

# EXTRA_ENV may be set (as a bash array) by the sourced config; default to
# empty so `set -u`-style var checks below don't choke when it's absent.
EXTRA_ENV=()

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

: "${IMAGE:?IMAGE not set in ${CONFIG_FILE}}"
: "${GPU_TYPE_ID:?GPU_TYPE_ID not set in ${CONFIG_FILE}}"
: "${GPU_COUNT:=1}"
: "${PORT:=8080}"
: "${POD_KIND:=http}"
: "${HEALTH_PATH:=/health}"
: "${CONTAINER_DISK_GB:=10}"
: "${VOLUME_GB:=20}"
: "${VOLUME_MOUNT_PATH:=/workspace}"
: "${CLOUD_TYPE:=SECURE}"
: "${SUPPORT_PUBLIC_IP:=false}"
: "${POD_NAME_PREFIX:=runpod}"
: "${IDLE_MIN:=5}"
# Minutes a pod may live without ever serving a request. The idle watchdog does
# not start its IDLE_MIN countdown until the first real request arrives, so
# bringing up a pool no longer races the earliest pods' idle timers; this bounds
# the pod that is never used at all. See docker/nli-runpod/nli_idle_watchdog.sh.
: "${STARTUP_GRACE_MIN:=60}"
: "${POLL_SEC:=30}"
# Generous default: a cold pod must pull a multi-GB (model-baked-in) image
# and load the model before /health returns 2xx. Raise in pods.conf if your
# image/cold-start is slower.
: "${HEALTH_TIMEOUT_SEC:=900}"
: "${HEALTH_POLL_INTERVAL_SEC:=10}"
# Stagger pod-creation calls so N pods don't all start pulling the (multi-GB,
# model-baked-in) image at the exact same instant — mitigates possible
# shared-egress/registry contention if several pods land on nearby nodes.
: "${CREATE_DELAY_SEC:=10}"
# Partial-availability policy. Capacity for the requested GPU type is not
# guaranteed, so "-n 10" can legitimately yield fewer than 10 pods. MIN_READY
# is the number below which the result is useless to the caller and the script
# reports hard failure; at or above it, the run is a PARTIAL success and the
# pods that did come up are reported normally (exit 2).
: "${MIN_READY:=1}"
# Stop trying after this many CONSECUTIVE creation failures. Capacity errors
# repeat, so hammering the API 10 times to collect 10 copies of the same
# "no instances available" is noise; a one-off blip still gets retried.
: "${MAX_CONSECUTIVE_CREATE_FAILURES:=3}"
# Value injected as each pod's own RUNPOD_API_KEY env var (used by the idle
# watchdog's self-stop REST call from inside the pod). Defaults to the raw
# local RUNPOD_API_KEY, but pods.conf can override this with a RunPod
# Secret reference (e.g. POD_ENV_RUNPOD_API_KEY='{{ RUNPOD_SECRET_name }}')
# so the raw key never appears in the API payload or hosts.generated.*.
: "${POD_ENV_RUNPOD_API_KEY:=${RUNPOD_API_KEY}}"

if [[ "${POD_KIND}" != "http" && "${POD_KIND}" != "tcp" ]]; then
  echo "error: POD_KIND must be 'http' or 'tcp', got '${POD_KIND}'" >&2
  exit 1
fi

API_BASE="https://rest.runpod.io/v1"
timestamp="$(date +%Y%m%d%H%M%S)"

# Base env every pod gets; EXTRA_ENV (pods.conf array of "KEY=VALUE" strings)
# is merged on top so a config can inject e.g. PUBLIC_KEY / object-storage
# credentials without this script needing to know about them by name.
base_env_json="$(
  jq -n \
    --arg runpodApiKey "${POD_ENV_RUNPOD_API_KEY}" \
    --arg idleMin "${IDLE_MIN}" \
    --arg startupGraceMin "${STARTUP_GRACE_MIN}" \
    --arg pollSec "${POLL_SEC}" \
    '{RUNPOD_API_KEY: $runpodApiKey, IDLE_MIN: $idleMin, STARTUP_GRACE_MIN: $startupGraceMin, POLL_SEC: $pollSec}'
)"
extra_env_json="{}"
if [[ "${#EXTRA_ENV[@]}" -gt 0 ]]; then
  extra_env_json="$(
    printf '%s\n' "${EXTRA_ENV[@]}" \
      | jq -R 'capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}' \
      | jq -s 'add // {}'
  )"
fi
env_json="$(jq -n --argjson base "${base_env_json}" --argjson extra "${extra_env_json}" '$base * $extra')"

declare -a POD_IDS=()
declare -a POD_NAMES=()
declare -a POD_HOSTS=()   # http kind only: proxy hostname, computed at creation time
declare -a CREATE_FAILED=()
consecutive_failures=0

echo "Creating ${COUNT} pod(s) from ${CONFIG_FILE} (kind=${POD_KIND}, image=${IMAGE}, gpu=${GPU_TYPE_ID})..." >&2

for i in $(seq 1 "${COUNT}"); do
  name="$(printf '%s-%s-%02d' "${POD_NAME_PREFIX}" "${timestamp}" "${i}")"

  port_proto="http"
  [[ "${POD_KIND}" == "tcp" ]] && port_proto="tcp"

  payload="$(
    jq -n \
      --arg name "${name}" \
      --arg image "${IMAGE}" \
      --arg gpuTypeId "${GPU_TYPE_ID}" \
      --argjson gpuCount "${GPU_COUNT}" \
      --arg port "${PORT}" \
      --arg portProto "${port_proto}" \
      --argjson containerDiskInGb "${CONTAINER_DISK_GB}" \
      --argjson volumeInGb "${VOLUME_GB}" \
      --arg volumeMountPath "${VOLUME_MOUNT_PATH}" \
      --arg cloudType "${CLOUD_TYPE}" \
      --argjson supportPublicIp "${SUPPORT_PUBLIC_IP}" \
      --argjson env "${env_json}" \
      '{
        name: $name,
        imageName: $image,
        gpuTypeIds: [$gpuTypeId],
        gpuCount: $gpuCount,
        ports: [($port + "/" + $portProto)],
        containerDiskInGb: $containerDiskInGb,
        volumeInGb: $volumeInGb,
        volumeMountPath: $volumeMountPath,
        cloudType: $cloudType,
        supportPublicIp: $supportPublicIp,
        env: $env
      }'
  )"

  echo "  [${i}/${COUNT}] creating ${name}..." >&2
  response="$(
    curl -sS -X POST "${API_BASE}/pods" \
      -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "${payload}"
  )"

  pod_id="$(echo "${response}" | jq -r '.id // empty')"
  if [[ -z "${pod_id}" ]]; then
    # Do NOT exit here. Every pod created so far is already running and
    # billing; exiting would abandon them with no inventory CSV, no host list
    # and no teardown command -- the caller would have to find them in the
    # RunPod console by hand. Record the failure, keep going, and let the
    # reporting at the end decide whether what we got is usable.
    reason="$(echo "${response}" | jq -r '.error // .message // empty' 2>/dev/null || true)"
    [[ -z "${reason}" ]] && reason="$(echo "${response}" | tr -d '\n' | cut -c1-200)"
    echo "  [${i}/${COUNT}] FAILED to create ${name}: ${reason}" >&2
    CREATE_FAILED+=("${name}: ${reason}")
    consecutive_failures=$((consecutive_failures + 1))
    if [[ "${consecutive_failures}" -ge "${MAX_CONSECUTIVE_CREATE_FAILURES}" ]]; then
      echo "  giving up on the remaining pods after ${consecutive_failures} consecutive failures" >&2
      echo "  (capacity errors repeat; raise MAX_CONSECUTIVE_CREATE_FAILURES to keep trying)" >&2
      break
    fi
    if [[ "${i}" -lt "${COUNT}" && "${CREATE_DELAY_SEC}" -gt 0 ]]; then
      sleep "${CREATE_DELAY_SEC}"
    fi
    continue
  fi
  consecutive_failures=0

  POD_IDS+=("${pod_id}")
  POD_NAMES+=("${name}")
  if [[ "${POD_KIND}" == "http" ]]; then
    host="${pod_id}-${PORT}.proxy.runpod.net"
    echo "  [${i}/${COUNT}] created ${name} -> id=${pod_id} host=${host}" >&2
    POD_HOSTS+=("${host}")
  else
    echo "  [${i}/${COUNT}] created ${name} -> id=${pod_id} (waiting for public IP/port assignment)" >&2
    POD_HOSTS+=("")
  fi

  if [[ "${i}" -lt "${COUNT}" && "${CREATE_DELAY_SEC}" -gt 0 ]]; then
    sleep "${CREATE_DELAY_SEC}"
  fi
done

if [[ "${#CREATE_FAILED[@]}" -gt 0 ]]; then
  echo "" >&2
  echo "note: ${#CREATE_FAILED[@]} of ${COUNT} pod(s) could not be created:" >&2
  printf '  - %s\n' "${CREATE_FAILED[@]}" >&2
fi

if [[ "${#POD_IDS[@]}" -eq 0 ]]; then
  # Same reasoning as the n_ready == 0 path below: a previous run's host list
  # must never survive a failed run looking like this one's result.
  echo "# no pods created as of $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${SCRIPT_DIR}/hosts.generated.yaml"
  echo "" >&2
  echo "error: no pods were created at all — nothing to report or clean up." >&2
  echo "Check GPU availability for '${GPU_TYPE_ID}' in the ${CLOUD_TYPE} tier, or try another" >&2
  echo "GPU_TYPE_ID (valid ids: curl -s https://rest.runpod.io/v1/openapi.json |" >&2
  echo "  jq -r '.components.schemas.PodCreateInput.properties.gpuTypeIds.items.enum[]')." >&2
  exit 1
fi

echo "Waiting for ${#POD_IDS[@]} pod(s) to become ready (timeout ${HEALTH_TIMEOUT_SEC}s each)..." >&2

declare -a PUB_HOSTS=()
declare -a PUB_PORTS=()
declare -a NOT_READY=()
declare -a READY_IDX=()

for idx in "${!POD_IDS[@]}"; do
  id="${POD_IDS[$idx]}"
  name="${POD_NAMES[$idx]}"
  elapsed=0
  ready=0
  pub_host=""
  pub_port=""

  if [[ "${POD_KIND}" == "http" ]]; then
    host="${POD_HOSTS[$idx]}"
    while [[ "${elapsed}" -lt "${HEALTH_TIMEOUT_SEC}" ]]; do
      # -f: treat HTTP >= 400 (e.g. the proxy's 502 while the container is
      # still booting) as NOT ready, so we only succeed on a real 2xx from
      # the service itself.
      if curl -fsS --max-time 10 "https://${host}${HEALTH_PATH}" >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep "${HEALTH_POLL_INTERVAL_SEC}"
      elapsed=$((elapsed + HEALTH_POLL_INTERVAL_SEC))
    done
    pub_host="${host}"
    pub_port="${PORT}"
  else
    while [[ "${elapsed}" -lt "${HEALTH_TIMEOUT_SEC}" ]]; do
      info="$(curl -sS --max-time 10 "${API_BASE}/pods/${id}" -H "Authorization: Bearer ${RUNPOD_API_KEY}" 2>/dev/null || true)"
      pub_host="$(echo "${info}" | jq -r '.publicIp // empty' 2>/dev/null || true)"
      pub_port="$(echo "${info}" | jq -r --arg p "${PORT}" '.portMappings[$p] // empty' 2>/dev/null || true)"
      if [[ -n "${pub_host}" && -n "${pub_port}" ]]; then
        ready=1
        break
      fi
      sleep "${HEALTH_POLL_INTERVAL_SEC}"
      elapsed=$((elapsed + HEALTH_POLL_INTERVAL_SEC))
    done
  fi

  PUB_HOSTS+=("${pub_host}")
  PUB_PORTS+=("${pub_port}")

  if [[ "${ready}" -eq 1 ]]; then
    READY_IDX+=("${idx}")
    if [[ "${POD_KIND}" == "http" ]]; then
      echo "  ${name} (${pub_host}): ready after ~${elapsed}s" >&2
    else
      echo "  ${name} (${pub_host}:${pub_port}): public IP/port assigned after ~${elapsed}s" >&2
    fi
  else
    if [[ "${POD_KIND}" == "http" ]]; then
      echo "  ${name}: NOT ready after ${HEALTH_TIMEOUT_SEC}s — check the RunPod console/logs" >&2
    else
      echo "  ${name}: public IP/port NOT assigned after ${HEALTH_TIMEOUT_SEC}s — check the RunPod console/logs" >&2
    fi
    NOT_READY+=("${name}")
  fi
done

echo "id,name,host,port" > "${OUT_CSV}"
for idx in "${!POD_IDS[@]}"; do
  echo "${POD_IDS[$idx]},${POD_NAMES[$idx]},${PUB_HOSTS[$idx]},${PUB_PORTS[$idx]}" >> "${OUT_CSV}"
done
echo "Wrote pod inventory to ${OUT_CSV}" >&2

# Report whatever actually came up. Previously any not-ready pod suppressed the
# connection info entirely and exited 1 -- so a run that got 8 of 10 pods gave
# the caller nothing to paste, while leaving all 8 running and billing, and left
# hosts.generated.yaml holding the PREVIOUS run's hosts, which is worse than
# useless: it looks current and points at pods that no longer exist.
#
# Now the ready pods are always reported and hosts.generated.yaml is always
# rewritten from them (never left stale), with exit status distinguishing the
# three outcomes for callers that script this:
#   0  every requested pod is ready
#   2  PARTIAL -- at least MIN_READY are ready, but fewer than requested
#   1  fewer than MIN_READY are ready (or nothing was created at all)
n_ready="${#READY_IDX[@]}"

declare -a READY_HOSTS=()
declare -a READY_PORTS=()
declare -a READY_NAMES=()
declare -a READY_IDS=()
for idx in "${READY_IDX[@]}"; do
  READY_HOSTS+=("${PUB_HOSTS[$idx]}")
  READY_PORTS+=("${PUB_PORTS[$idx]}")
  READY_NAMES+=("${POD_NAMES[$idx]}")
  READY_IDS+=("${POD_IDS[$idx]}")
done

echo "" >&2
echo "Ready: ${n_ready}/${COUNT} requested pod(s)." >&2
if [[ "${#NOT_READY[@]}" -gt 0 ]]; then
  echo "Not ready (created but did not come up in ${HEALTH_TIMEOUT_SEC}s):" >&2
  printf '  - %s\n' "${NOT_READY[@]}" >&2
  echo "These are RUNNING AND BILLING. Stop them with scripts/runpod/stop_pods.sh -i <id> (ids in ${OUT_CSV})," >&2
  echo "or raise HEALTH_TIMEOUT_SEC if they were merely slow to pull the image." >&2
fi

if [[ "${n_ready}" -eq 0 ]]; then
  # Never leave a previous run's host list looking like this run's result.
  echo "# no pods ready as of $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${SCRIPT_DIR}/hosts.generated.yaml"
  echo "" >&2
  echo "error: no pod became ready. Inventory (for teardown) is in ${OUT_CSV}." >&2
  exit 1
fi

echo "" >&2
if [[ "${POD_KIND}" == "http" ]]; then
  if [[ "${n_ready}" -eq 1 ]]; then
    paste_block="host: ${READY_HOSTS[0]}"
  else
    host_list="$(printf '"%s", ' "${READY_HOSTS[@]}")"
    paste_block="host: [${host_list%, }]"
  fi
  echo "${paste_block}" > "${SCRIPT_DIR}/hosts.generated.yaml"
  echo "Paste this line into your project's active config (e.g. an embedding-backend host entry):" >&2
  echo "---" >&2
  echo "${paste_block}"
  echo "---" >&2
else
  {
    for k in "${!READY_IDS[@]}"; do
      echo "# ${READY_NAMES[$k]} (id=${READY_IDS[$k]})"
      echo "ssh_host: ${READY_HOSTS[$k]}"
      echo "ssh_port: ${READY_PORTS[$k]}"
      echo "ssh_user: root"
      echo "ssh_key_path: ~/.ssh/id_ed25519"
      echo ""
    done
  } > "${SCRIPT_DIR}/hosts.generated.yaml"
  echo "Paste the relevant block(s) into your project's SSH-target config:" >&2
  echo "---" >&2
  cat "${SCRIPT_DIR}/hosts.generated.yaml"
  echo "---" >&2
fi
echo "(also written to ${SCRIPT_DIR}/hosts.generated.yaml — READY pods only)" >&2
echo "Pod inventory (for teardown): ${OUT_CSV}" >&2
echo "Stop a pod with: scripts/runpod/stop_pods.sh   (or -i <pod-id>; ids are in ${OUT_CSV})" >&2

if [[ "${n_ready}" -lt "${MIN_READY}" ]]; then
  echo "" >&2
  echo "error: only ${n_ready} pod(s) ready, below MIN_READY=${MIN_READY}." >&2
  echo "The host list above is still valid for the pods that DID come up." >&2
  exit 1
fi

if [[ "${n_ready}" -lt "${COUNT}" ]]; then
  echo "" >&2
  echo "PARTIAL: ${n_ready} of ${COUNT} requested pod(s) are usable (>= MIN_READY=${MIN_READY})." >&2
  exit 2
fi
