#!/usr/bin/env bash
# Pod entrypoint: launch TEI against the model baked into the image.
# All knobs come from env vars set in the Dockerfile (defaults) and overridable
# at `docker run -e` / RunPod template "Environment Variables" time.
#
# Mirrors docker/tei-runpod/entrypoint.sh (log rotation + idle watchdog); the
# differences are that pooling is an env var here rather than hardcoded, and
# the model-missing error message isn't SPECTER2-specific.
set -euo pipefail

: "${TEI_PORT:=8080}"
: "${TEI_MAX_BATCH_TOKENS:=32768}"
: "${TEI_MAX_CONCURRENT:=512}"
: "${TEI_MAX_CLIENT_BATCH:=128}"
: "${TEI_POOLING:=cls}"
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
    echo "Baked-in model not found at ${MODEL_PATH}/config.json" >&2
    exit 1
fi

# Warn (don't fail) if the weight format this TEI build reads isn't present:
# TEI would silently fall back to downloading it from the Hub at boot, which
# still works but throws away the whole point of baking the model in — and on
# a pod with no outbound Hub access it fails outright, several minutes in.
# CUDA/candle builds read model.safetensors; the CPU build reads
# onnx/model.onnx. We can't tell which backend this base image is from inside
# the entrypoint, so flag only the case where NEITHER exists.
if [ ! -f "${MODEL_PATH}/model.safetensors" ] && [ ! -f "${MODEL_PATH}/onnx/model.onnx" ]; then
    echo "[entrypoint] WARNING: neither ${MODEL_PATH}/model.safetensors nor" >&2
    echo "[entrypoint]          ${MODEL_PATH}/onnx/model.onnx is present — TEI will" >&2
    echo "[entrypoint]          try to download weights at boot. Check the" >&2
    echo "[entrypoint]          MODEL_WEIGHTS build arg matches TEI_TAG." >&2
fi

# Idle watchdog — pod-side auto-stop after IDLE_MIN idle minutes.
# Skipped if we're not on a real pod (no RUNPOD_POD_ID).
if [ -n "${RUNPOD_POD_ID:-}" ]; then
    /usr/local/bin/tei_idle_watchdog.sh &
    echo "[entrypoint] idle watchdog started (IDLE_MIN=${IDLE_MIN:-5} min)"
fi

echo "Starting TEI"
echo "  model:                    ${MODEL_PATH} (${MODEL_ID:-unknown})"
echo "  port:                     ${TEI_PORT}"
echo "  max-batch-tokens:         ${TEI_MAX_BATCH_TOKENS}"
echo "  max-client-batch-size:    ${TEI_MAX_CLIENT_BATCH}"
echo "  max-concurrent-requests:  ${TEI_MAX_CONCURRENT}"
echo "  pooling:                  ${TEI_POOLING}"
echo "  auto-truncate:            on"

exec text-embeddings-router \
    --model-id "${MODEL_PATH}" \
    --hostname 0.0.0.0 \
    --port "${TEI_PORT}" \
    --max-batch-tokens "${TEI_MAX_BATCH_TOKENS}" \
    --max-client-batch-size "${TEI_MAX_CLIENT_BATCH}" \
    --max-concurrent-requests "${TEI_MAX_CONCURRENT}" \
    --pooling "${TEI_POOLING}" \
    --auto-truncate
