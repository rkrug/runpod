#!/usr/bin/env bash
# Self-stop the RunPod pod when the NLI server has been idle for IDLE_MIN
# minutes. Watches the server's /metrics counter; if it stops moving for
# IDLE_MIN consecutive minutes, stops the pod via the RunPod REST API
# (POST /v1/pods/<id>/stop) to pause billing. Restart from the RunPod UI —
# the volume + image cache survive.
#
# Required env (set by the pod template):
#   RUNPOD_POD_ID    Automatically set by RunPod.
#   RUNPOD_API_KEY   Add via the pod template "Environment Variables" UI.
#
# Optional env:
#   IDLE_MIN         Idle minutes before stop (default: 5).
#   POLL_SEC         Polling cadence in seconds (default: 30).
#   METRICS_URL      NLI metrics endpoint (default: http://localhost:8080/metrics).
set -euo pipefail

IDLE_MIN="${IDLE_MIN:-5}"
POLL_SEC="${POLL_SEC:-30}"
METRICS_URL="${METRICS_URL:-http://localhost:8080/metrics}"

if [ -z "${RUNPOD_POD_ID:-}" ]; then
	echo "[idle-watchdog] RUNPOD_POD_ID not set — not on a RunPod pod, exiting" >&2
	exit 0
fi
if [ -z "${RUNPOD_API_KEY:-}" ]; then
	echo "[idle-watchdog] RUNPOD_API_KEY not set — the self-stop REST call will be skipped. Add it to the pod template env." >&2
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

last_count=-1
idle_seconds=0
echo "[idle-watchdog] watching ${METRICS_URL}; will stop pod ${RUNPOD_POD_ID} after ${IDLE_MIN} idle minutes"

while true; do
	count=$(curl -fsS "${METRICS_URL}" 2>/dev/null |
		awk '/^nli_request_count/ {sum += $NF} END {print sum+0}' ||
		echo "-1")

	if [ "${count}" = "-1" ]; then
		echo "[idle-watchdog] metrics unreachable — NLI server may still be loading the model"
	elif [ "${count}" = "${last_count}" ]; then
		idle_seconds=$((idle_seconds + POLL_SEC))
		echo "[idle-watchdog] no new requests; idle for $((idle_seconds / 60)) min (count=${count})"
	else
		if [ "${idle_seconds}" -gt 0 ]; then
			echo "[idle-watchdog] activity resumed (${last_count} → ${count})"
		fi
		idle_seconds=0
		last_count="${count}"
	fi

	if [ "${idle_seconds}" -ge "$((IDLE_MIN * 60))" ]; then
		echo "[idle-watchdog] idle threshold reached, stopping pod ${RUNPOD_POD_ID}"
		stop_pod
		exit 0
	fi

	sleep "${POLL_SEC}"
done
