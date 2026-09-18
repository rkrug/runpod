#!/usr/bin/env bash
# Pod entrypoint: launch the NLI uvicorn server. Knobs come from env vars set in
# the Dockerfile (defaults) and overridable at RunPod template / docker run time.
# Mirrors docker/tei-runpod/entrypoint.sh (log rotation + idle watchdog).
set -euo pipefail

: "${NLI_PORT:=8080}"
: "${LOG_DIR:=/workspace}"          # volume-mounted: logs survive stop/restart

# Persist logs to the volume; rotate one generation at every boot.
mkdir -p "${LOG_DIR}"
if [ -f "${LOG_DIR}/nli-current.log" ]; then
    mv -f "${LOG_DIR}/nli-current.log" "${LOG_DIR}/nli-previous.log"
fi
NLI_LOG="${LOG_DIR}/nli-current.log"

exec > >(tee -a "${NLI_LOG}") 2>&1
echo "[entrypoint] persisting logs to ${NLI_LOG} (prior: ${LOG_DIR}/nli-previous.log)"

# Idle watchdog — pod-side auto-stop after IDLE_MIN idle minutes.
if [ -n "${RUNPOD_POD_ID:-}" ]; then
    /usr/local/bin/nli_idle_watchdog.sh &
    echo "[entrypoint] idle watchdog started (startup grace ${STARTUP_GRACE_MIN:-60} min until first request, then IDLE_MIN=${IDLE_MIN:-5} min)"
fi

echo "Starting NLI server"
echo "  model: ${NLI_MODEL:-MoritzLaurer/deberta-v3-large-zeroshot-v2.0}"
echo "  port:  ${NLI_PORT}"

exec uvicorn server:app \
    --app-dir /opt/app \
    --host 0.0.0.0 \
    --port "${NLI_PORT}"
