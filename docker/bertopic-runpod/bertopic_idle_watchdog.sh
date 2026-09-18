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
#   IDLE_MIN            Idle minutes before stop, AFTER the heartbeat has been
#                       touched by something other than this watchdog's own
#                       initialisation (default: 5). 0 disables the idle timer.
#   STARTUP_GRACE_MIN   Minutes the pod may live without the heartbeat EVER being
#                       touched by a job or an SSH session (default: 60). 0
#                       disables it -- but then a pod nobody ever connects to
#                       runs until stopped by hand.
#   POLL_SEC            Polling cadence in seconds (default: 30).
#   HEARTBEAT_PATH   File whose mtime is treated as last activity (default: /work/.heartbeat).
set -euo pipefail

IDLE_MIN="${IDLE_MIN:-5}"
STARTUP_GRACE_MIN="${STARTUP_GRACE_MIN:-60}"
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

# Initialise heartbeat so the watchdog doesn't immediately conclude "idle".
# Its mtime here is also the "nobody has used this pod yet" marker: the pod is
# in the STARTUP phase until something ELSE touches the file (run_bertopic_gpu.py
# does at job start and after every step; an interactive session can
# `touch /work/.heartbeat`). Until then IDLE_MIN does not run, and the pod is
# bounded by STARTUP_GRACE_MIN instead.
#
# Without that split the pod started its IDLE_MIN countdown at boot, so a caller
# who took longer than IDLE_MIN to provision the pod, connect over SSH and start
# a job found it had already stopped itself -- the same bring-up race the HTTP
# images had, and the reason this pod's IDLE_MIN could not safely be set low.
mkdir -p "$(dirname "${HEARTBEAT_PATH}")"
touch "${HEARTBEAT_PATH}"
initial_mtime=$(stat -c '%Y' "${HEARTBEAT_PATH}" 2>/dev/null || echo 0)
served=0
startup_seconds=0
idle_limit=$((IDLE_MIN * 60))
startup_limit=$((STARTUP_GRACE_MIN * 60))

echo "[idle-watchdog] watching ${HEARTBEAT_PATH} for pod ${RUNPOD_POD_ID}"
echo "[idle-watchdog]   startup grace: ${STARTUP_GRACE_MIN} min (until the heartbeat is first touched)"
echo "[idle-watchdog]   idle timeout:  ${IDLE_MIN} min (after that)"

while true; do
    if [ ! -f "${HEARTBEAT_PATH}" ]; then
        touch "${HEARTBEAT_PATH}"
    fi

    # Seconds since heartbeat last modified.
    mtime_epoch=$(stat -c '%Y' "${HEARTBEAT_PATH}" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    idle_seconds=$(( now_epoch - mtime_epoch ))
    idle_minutes=$(( idle_seconds / 60 ))

    # Anything newer than the mtime this watchdog itself wrote means a real job
    # or session has touched the file: arm the idle timer permanently.
    if [ "${served}" -eq 0 ] && [ "${mtime_epoch}" -gt "${initial_mtime}" ]; then
        echo "[idle-watchdog] heartbeat touched — idle timer armed (IDLE_MIN=${IDLE_MIN} min)"
        served=1
    fi

    if [ "${served}" -eq 0 ]; then
        startup_seconds=$(( startup_seconds + POLL_SEC ))
        echo "[idle-watchdog] heartbeat never touched yet; startup grace $((startup_seconds / 60))/${STARTUP_GRACE_MIN} min"
        if [ "${startup_limit}" -gt 0 ] && [ "${startup_seconds}" -ge "${startup_limit}" ]; then
            echo "[idle-watchdog] startup grace exhausted without the heartbeat ever being touched, stopping pod ${RUNPOD_POD_ID}"
            stop_pod
            exit 0
        fi
    else
        echo "[idle-watchdog] heartbeat idle for $((idle_minutes)) min ($((idle_seconds)) s)"

        # Guarded by > 0 so IDLE_MIN=0 disables the idle timer instead of
        # stopping the pod on the first poll.
        if [ "${idle_limit}" -gt 0 ] && [ "${idle_seconds}" -ge "${idle_limit}" ]; then
            echo "[idle-watchdog] threshold reached, stopping pod ${RUNPOD_POD_ID}"
            stop_pod
            exit 0
        fi
    fi

    sleep "${POLL_SEC}"
done
