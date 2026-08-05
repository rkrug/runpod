#!/usr/bin/env bash
# Pod entrypoint: launch TEI against the merged model baked into the image.
# All knobs come from env vars set in the Dockerfile (defaults) and overridable
# at `docker run -e` / RunPod template "Environment Variables" time.
set -euo pipefail

: "${TEI_PORT:=8080}"
: "${TEI_MAX_BATCH_TOKENS:=131072}"
: "${TEI_MAX_CONCURRENT:=2048}"
: "${TEI_MAX_CLIENT_BATCH:=512}"
: "${TEI_SERVED_NAME:=allenai/specter2_proximity_merged}"
: "${MODEL_PATH:=/model}"
: "${LOG_DIR:=/workspace}"          # volume-mounted: logs survive stop/restart

# Persist logs to the volume so a crashed pod's last words survive a
# restart. Rotate one generation: <svc>-current.log → <svc>-previous.log
# at every boot. Old previous gets overwritten — no unbounded growth.
mkdir -p "${LOG_DIR}"
if [ -f "${LOG_DIR}/tei-current.log" ]; then
    mv -f "${LOG_DIR}/tei-current.log" "${LOG_DIR}/tei-previous.log"
fi
TEI_LOG="${LOG_DIR}/tei-current.log"

# Tee this shell's stdout+stderr (and everything that inherits its fds,
# including the watchdog launched below) into the persistent log file
# while still streaming to the RunPod Logs panel.
exec > >(tee -a "${TEI_LOG}") 2>&1
echo "[entrypoint] persisting logs to ${TEI_LOG} (prior: ${LOG_DIR}/tei-previous.log)"

if [ ! -f "${MODEL_PATH}/config.json" ]; then
    echo "Merged SPECTER2 model not found at ${MODEL_PATH}/config.json" >&2
    exit 1
fi

# Idle watchdog — pod-side auto-stop after IDLE_MIN idle minutes.
# Skipped if we're not on a real pod (no RUNPOD_POD_ID).
if [ -n "${RUNPOD_POD_ID:-}" ]; then
    /usr/local/bin/tei_idle_watchdog.sh &
    echo "[entrypoint] idle watchdog started (IDLE_MIN=${IDLE_MIN:-15} min)"
fi

echo "Starting TEI"
echo "  model:                    ${MODEL_PATH}"
echo "  port:                     ${TEI_PORT}"
echo "  max-batch-tokens:         ${TEI_MAX_BATCH_TOKENS}"
echo "  max-client-batch-size:    ${TEI_MAX_CLIENT_BATCH}"
echo "  max-concurrent-requests:  ${TEI_MAX_CONCURRENT}"
echo "  pooling:                  cls"
echo "  auto-truncate:            on"

# Note: TEI 1.5 dropped --served-model-name. The cosmetic served name is no
# longer settable; the model id from --model-id is reported instead.
exec text-embeddings-router \
    --model-id "${MODEL_PATH}" \
    --hostname 0.0.0.0 \
    --port "${TEI_PORT}" \
    --max-batch-tokens "${TEI_MAX_BATCH_TOKENS}" \
    --max-client-batch-size "${TEI_MAX_CLIENT_BATCH}" \
    --max-concurrent-requests "${TEI_MAX_CONCURRENT}" \
    --pooling cls \
    --auto-truncate
