# TEI embedding server with BAAI/bge-large-en-v1.5 baked in, ready to drop
# into a RunPod pod (no first-boot model download, no volume mount required).
#
# Sibling of docker/tei-runpod/ (which serves a *merged SPECTER2 adapter* and
# therefore needs a build-time adapter-merge stage). This image serves a plain
# off-the-shelf HuggingFace embedding model, so the first stage is just a
# download — no merge, no `adapters` dependency. Self-contained per this
# repo's one-directory-per-image convention.
#
# Build (from repo root):
#   docker buildx build --platform linux/amd64 \
#     -t ghcr.io/<you>/tei-runpod-bge-large-en-v1.5:v0.1.0 \
#     -f docker/tei-runpod-bge-large-en-v1.5/Dockerfile .
#   docker push ghcr.io/<you>/tei-runpod-bge-large-en-v1.5:v0.1.0
#
# RunPod pod template:
#   Container Image: ghcr.io/<you>/tei-runpod-bge-large-en-v1.5:v0.1.0
#   Expose HTTP port: 8080
#   (no Container Start Command — entrypoint launches TEI)

# ----------------------------------------------------------------------------
# Global build args — must be declared BEFORE any FROM line so they can be
# interpolated into the runtime stage's image reference.
#
# TEI_TAG and MODEL_WEIGHTS must agree: TEI's CUDA/candle backends read
# `model.safetensors`, its CPU backend reads `onnx/model.onnx`. Mismatch them
# and the pod silently re-downloads the format it actually wants on first
# boot, defeating the point of baking the model in.
#   GPU (default):  TEI_TAG=89-1.5   MODEL_WEIGHTS=safetensors
#   CPU (local test): TEI_TAG=cpu-1.6  MODEL_WEIGHTS=onnx
# ----------------------------------------------------------------------------
ARG TEI_TAG=89-1.5
ARG MODEL_ID=BAAI/bge-large-en-v1.5
ARG MODEL_WEIGHTS=safetensors

# ----------------------------------------------------------------------------
# Stage 1 — download the model into /model.
# ----------------------------------------------------------------------------
FROM python:3.11-slim AS downloader

ARG MODEL_ID
ARG MODEL_WEIGHTS
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# >=0.23 so snapshot_download(local_dir=...) materialises real files rather
# than symlinks into a blob cache that won't survive the COPY below.
RUN pip install --no-cache-dir "huggingface_hub>=0.23,<1"

WORKDIR /work
COPY docker/tei-runpod-bge-large-en-v1.5/download_model.py /work/download_model.py

RUN python /work/download_model.py \
        --model-id "${MODEL_ID}" \
        --weights "${MODEL_WEIGHTS}" \
        --out-dir /model

# ----------------------------------------------------------------------------
# Stage 2 — TEI runtime with the downloaded model copied in.
# Pick the TEI tag matching your RunPod GPU family:
#   89-1.5  → Ada / Hopper / RTX 4090 / H100 / L40S
#   86-1.5  → Ampere / A100 / A6000
#   80-1.5  → A100 (compute 8.0)
#   cpu-1.6 → CPU only (used by test/smoke-test.sh for local verification)
# Pass via --build-arg TEI_TAG=<tag>.
# ----------------------------------------------------------------------------
FROM ghcr.io/huggingface/text-embeddings-inference:${TEI_TAG} AS runtime

ARG MODEL_ID
# Override at build time (--build-arg IMAGE_SOURCE_URL=... --build-arg
# IMAGE_DESCRIPTION=...) so a consuming project's fork of this image links
# its GHCR package back to its own fork instead of this repo.
ARG IMAGE_SOURCE_URL=https://github.com/rkrug/runpod
ARG IMAGE_DESCRIPTION="TEI server with BAAI/bge-large-en-v1.5 baked in, ready for RunPod."
LABEL org.opencontainers.image.source=${IMAGE_SOURCE_URL} \
      org.opencontainers.image.description=${IMAGE_DESCRIPTION}

# Model lives at /model inside the image.
COPY --from=downloader /model /model

# TEI server-side tuning — overridable at runtime via -e.
#
# TEI_POOLING is cls because that's what this model's own
# 1_Pooling/config.json specifies (pooling_mode_cls_token: true); serving it
# with mean pooling would produce quietly wrong embeddings, not an error.
#
# TEI_MAX_BATCH_TOKENS is deliberately lower than docker/tei-runpod/'s
# 131072: that value was tuned for A100/H100-class cards, and this image's
# default GPU sizing is smaller (see README). Raise it if you run on bigger
# hardware and have measured the headroom.
ENV TEI_PORT=8080 \
    TEI_MAX_BATCH_TOKENS=32768 \
    TEI_MAX_CONCURRENT=512 \
    TEI_MAX_CLIENT_BATCH=128 \
    TEI_POOLING=cls \
    MODEL_ID=${MODEL_ID}

# curl is needed by the watchdog to poll TEI /metrics and to call the RunPod
# REST API; the runtime base image ships without it. awk is in coreutils →
# already present.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Idle watchdog: stops the pod after IDLE_MIN minutes with no TEI requests,
# via the RunPod REST API (needs only RUNPOD_API_KEY in the pod env — see
# tei_idle_watchdog.sh). No runpodctl dependency.
COPY docker/tei-runpod-bge-large-en-v1.5/tei_idle_watchdog.sh /usr/local/bin/tei_idle_watchdog.sh
RUN chmod +x /usr/local/bin/tei_idle_watchdog.sh

COPY docker/tei-runpod-bge-large-en-v1.5/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV IDLE_MIN=5

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
