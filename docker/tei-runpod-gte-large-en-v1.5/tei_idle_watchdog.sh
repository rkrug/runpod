#!/usr/bin/env bash
# Self-stop the RunPod pod when TEI has been idle for IDLE_MIN minutes.
#
# Watches TEI's Prometheus metrics endpoint for the cumulative request
# counter. If it stops moving for IDLE_MIN consecutive minutes, it stops the
# pod via the RunPod REST API (POST /v1/pods/<id>/stop) to pause billing. The
# pod can be restarted from the RunPod UI (or via API) — the network volume +
# image cache survive.
#
# Identical to docker/tei-runpod/tei_idle_watchdog.sh — TEI's te_request_count
# metric is the same whichever model is baked in — kept as its own copy per
# this repo's self-contained-per-image convention, not a shared file.
#
# Required env (set by the pod template):
#   RUNPOD_POD_ID    Automatically set by RunPod.
#   RUNPOD_API_KEY   Add via the pod template "Environment Variables" UI.
#
# Optional env:
#   IDLE_MIN            Idle minutes before stop, AFTER the pod has served at
#                       least one request (default: 5). 0 disables the idle
#                       timer.
#   STARTUP_GRACE_MIN   Minutes a pod may live without EVER serving a request
#                       before it stops itself (default: 60). 0 disables it --
#                       but then a pod that is never used, or whose model never
#                       loads, runs until stopped by hand.
#   POLL_SEC            Polling cadence in seconds (default: 30).
#   METRICS_URL         TEI prometheus endpoint (default: http://localhost:8080/metrics).
set -euo pipefail

IDLE_MIN="${IDLE_MIN:-5}"
STARTUP_GRACE_MIN="${STARTUP_GRACE_MIN:-60}"
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

# Two phases, because "has not been asked to do anything yet" and "has finished
# the work it was given" need very different timeouts.
#
# STARTUP phase — the pod has never served a request, so the idle timer is NOT
# running. This is what makes bringing up a POOL safe: creating N pods takes
# N x CREATE_DELAY_SEC, they then boot concurrently, and the caller still has to
# collect their hostnames and point a client at them. Under the old single timer
# the first pod's IDLE_MIN was already counting down throughout all of that -- it
# started the moment /metrics first answered -- so a large enough pool could not
# be brought up at all: the earliest pods stopped themselves before the last were
# ready. The health polling in scripts/runpod/create_pods.sh does not help,
# because only a real work request moves the counter watched here.
#
# The startup phase is bounded by STARTUP_GRACE_MIN, so the failure mode it
# replaces (pod runs forever, billing, never used) is still covered -- and it now
# also covers a case the old logic missed entirely: if the model never loads,
# /metrics never answers, no counter ever advanced and the pod ran until stopped
# by hand.
#
# IDLE phase — armed permanently by the first request; the original IDLE_MIN
# behaviour then applies.
served=0
last_count=-1
idle_seconds=0
startup_seconds=0
idle_limit=$((IDLE_MIN * 60))
startup_limit=$((STARTUP_GRACE_MIN * 60))

echo "[idle-watchdog] watching ${METRICS_URL} for pod ${RUNPOD_POD_ID}"
echo "[idle-watchdog]   startup grace: ${STARTUP_GRACE_MIN} min (until the first request)"
echo "[idle-watchdog]   idle timeout:  ${IDLE_MIN} min (after the first request)"

while true; do
	# Sum all te_request_count_* counter samples reported by TEI. Robust to
	# version differences (counters were renamed across TEI releases).
	count=$(curl -fsS "${METRICS_URL}" 2>/dev/null |
		awk '/^te_request_count/ && !/_bucket|_sum/ {sum += $NF} END {print sum+0}' ||
		echo "-1")

	# "-1" is the unreachable sentinel, not a reading. Anything else from the awk
	# above is a non-negative integer; the case guard keeps a malformed scrape
	# from reaching an arithmetic test.
	case "${count}" in
	'' | *[!0-9]*) readable=0 ;;
	*) readable=1 ;;
	esac

	if [ "${served}" -eq 0 ] && [ "${readable}" -eq 1 ] && [ "${count}" -gt 0 ]; then
		echo "[idle-watchdog] first request(s) observed (count=${count}) — idle timer armed (IDLE_MIN=${IDLE_MIN} min)"
		served=1
		last_count="${count}"
		idle_seconds=0
	fi

	if [ "${served}" -eq 0 ]; then
		startup_seconds=$((startup_seconds + POLL_SEC))
		if [ "${readable}" -eq 0 ]; then
			echo "[idle-watchdog] TEI not answering yet (still warming up?); startup grace $((startup_seconds / 60))/${STARTUP_GRACE_MIN} min"
		else
			echo "[idle-watchdog] TEI up, no requests yet; startup grace $((startup_seconds / 60))/${STARTUP_GRACE_MIN} min"
		fi
		if [ "${startup_limit}" -gt 0 ] && [ "${startup_seconds}" -ge "${startup_limit}" ]; then
			echo "[idle-watchdog] startup grace exhausted without ever serving a request, stopping pod ${RUNPOD_POD_ID}"
			stop_pod
			exit 0
		fi
	else
		if [ "${readable}" -eq 0 ]; then
			# Unreachable AFTER the pod has served: a crash or restart, not
			# idleness. Hold the timer rather than advancing it -- stopping here
			# would race a server that is coming back up.
			echo "[idle-watchdog] metrics unreachable (TEI restarting?); idle timer held at $((idle_seconds / 60)) min"
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

		# Guarded by > 0 so IDLE_MIN=0 really does disable the idle timer.
		# It did not: idle_seconds starts at 0, so the old unguarded
		# "-ge $((IDLE_MIN * 60))" was true on the very first poll.
		if [ "${idle_limit}" -gt 0 ] && [ "${idle_seconds}" -ge "${idle_limit}" ]; then
			echo "[idle-watchdog] idle threshold reached, stopping pod ${RUNPOD_POD_ID}"
			stop_pod
			exit 0
		fi
	fi

	sleep "${POLL_SEC}"
done
