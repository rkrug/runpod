#!/usr/bin/env bash
# Self-stop the BERTopic pod when /work/.heartbeat has not been touched for
# IDLE_MIN minutes.
#
# The GPU script (run_bertopic_gpu.py) touches the heartbeat at start +
# after every step, so an actively-running job keeps the pod alive. SSH
# sessions can also touch it via a manual `touch /work/.heartbeat` at the
# start of a long interactive session, or via a small SSH command wrapper
# if desired.
#
# Required env:
#   RUNPOD_POD_ID    Set automatically by RunPod.
#   RUNPOD_API_KEY   Add via the pod template "Environment Variables" UI.
#
# Optional env:
#   IDLE_MIN         Idle minutes before stop (default: 5).
#   POLL_SEC         Polling cadence in seconds (default: 30).
#   HEARTBEAT_PATH   File whose mtime is treated as last activity (default: /work/.heartbeat).
set -euo pipefail

IDLE_MIN="${IDLE_MIN:-5}"
POLL_SEC="${POLL_SEC:-30}"
HEARTBEAT_PATH="${HEARTBEAT_PATH:-/work/.heartbeat}"

if [ -z "${RUNPOD_POD_ID:-}" ]; then
    echo "[idle-watchdog] RUNPOD_POD_ID not set — not on a RunPod pod, exiting" >&2
    exit 0
fi
if [ -z "${RUNPOD_API_KEY:-}" ]; then
    echo "[idle-watchdog] RUNPOD_API_KEY not set — the self-stop REST call will be skipped" >&2
fi

# Stop the pod via the RunPod REST API — the same mechanism as
# scripts/runpod/stop_pods.sh. This needs only RUNPOD_API_KEY in the env; it
# does NOT use runpodctl (which requires a `runpodctl config` file the pod
# doesn't have — that path fails with "Runpod config file not found"). The
# call is guarded so a failure logs instead of killing the watchdog under
# `set -e`.
stop_pod() {
    if [ -z "${RUNPOD_API_KEY:-}" ]; then
        echo "[idle-watchdog] RUNPOD_API_KEY not set — cannot stop pod ${RUNPOD_POD_ID}" >&2
        return 0
    fi
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
        "https://rest.runpod.io/v1/pods/${RUNPOD_POD_ID}/stop" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" 2>/dev/null || echo 000)"
    if [ "${code}" -ge 200 ] && [ "${code}" -lt 300 ]; then
        echo "[idle-watchdog] stop request accepted (HTTP ${code}) for pod ${RUNPOD_POD_ID}"
    else
        echo "[idle-watchdog] warning: stop request failed (HTTP ${code}) for pod ${RUNPOD_POD_ID}" >&2
    fi
}

# Initialise heartbeat so the watchdog doesn't immediately conclude "idle"
mkdir -p "$(dirname "${HEARTBEAT_PATH}")"
touch "${HEARTBEAT_PATH}"

echo "[idle-watchdog] watching ${HEARTBEAT_PATH}; will stop pod ${RUNPOD_POD_ID} after ${IDLE_MIN} idle minutes"

while true; do
    if [ ! -f "${HEARTBEAT_PATH}" ]; then
        touch "${HEARTBEAT_PATH}"
    fi

    # Seconds since heartbeat last modified.
    mtime_epoch=$(stat -c '%Y' "${HEARTBEAT_PATH}" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    idle_seconds=$(( now_epoch - mtime_epoch ))
    idle_minutes=$(( idle_seconds / 60 ))

    echo "[idle-watchdog] heartbeat idle for $((idle_minutes)) min ($((idle_seconds)) s)"

    if [ "${idle_seconds}" -ge "$(( IDLE_MIN * 60 ))" ]; then
        echo "[idle-watchdog] threshold reached, stopping pod ${RUNPOD_POD_ID}"
        stop_pod
        exit 0
    fi

    sleep "${POLL_SEC}"
done
