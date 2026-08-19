# Multilingual, long-context zero-shot NLI inference server, ready to drop
# into a RunPod GPU pod. Sibling of docker/nli-runpod/ (same server.py/
# entrypoint/watchdog contract, self-contained per docker/CLAUDE.md's
# "one directory per image" convention) with a different model baked in:
# MoritzLaurer/bge-m3-zeroshot-v2.0-c, chosen over an English-only
# long-context alternative (MoritzLaurer/ModernBERT-large-zeroshot-v2.0)
# because the premise text a caller sends can be in any language, even
# though the hypothesis is English -- this needs cross-lingual entailment,
# not just a longer context window. The model is baked into the image at
# build time so the pod is ready seconds after boot (no first-request
# download). Conventions (idle watchdog, persistent logs, GHCR + immutable
# tags) mirror docker/tei-runpod/ and docker/nli-runpod/.
#
# Build (from repo root):
#   docker buildx build --platform linux/amd64 \
#     -t ghcr.io/<you>/nli-runpod-bge-m3:v0.1.0 \
#     --build-arg IMAGE_SOURCE_URL=https://github.com/<you>/<your-fork> \
#     -f docker/nli-runpod-bge-m3/Dockerfile .
#   docker push ghcr.io/<you>/nli-runpod-bge-m3:v0.1.0
#
# `--platform linux/amd64` matters on Apple Silicon — RunPod nodes are amd64.
#
# RunPod pod template:
#   Container Image: ghcr.io/<you>/nli-runpod-bge-m3:v0.1.0 (or an immutable @sha256 digest)
#   Expose HTTP port: 8080
#   Container Start Command: (leave blank — entrypoint launches uvicorn)
#   Env: RUNPOD_API_KEY (required for the idle watchdog), IDLE_MIN, POLL_SEC

# CUDA runtime base with a recent Python. cu121 wheels match the L4/L40S/A100
# GPU families on RunPod. GPU sizing here is a starting point, not a
# measured one: bge-m3-zeroshot-v2.0-c is a larger model (~568M params) than
# docker/nli-runpod/'s DeBERTa-v3-large (~435M), and this image's intended
# use (NLI_MAX_LENGTH below, and the max_length this project's own
# nli.configs.bge_m3_zeroshot sends per-request) is several times longer
# sequences too -- measure real throughput/memory before trusting the same
# L4 pool sizing docker/nli-runpod/'s README documents.
FROM pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime AS runtime

# Override at build time so a consuming project's fork links its GHCR
# package back to its own fork instead of this repo.
ARG IMAGE_SOURCE_URL=https://github.com/rkrug/runpod
ARG IMAGE_DESCRIPTION="Multilingual zero-shot NLI server for RunPod (bge-m3-zeroshot)."
LABEL org.opencontainers.image.source=${IMAGE_SOURCE_URL} \
      org.opencontainers.image.description=${IMAGE_DESCRIPTION}

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/opt/hf-cache \
    NLI_PORT=8080 \
    NLI_MAX_LENGTH=2048 \
    NLI_DTYPE=float16 \
    IDLE_MIN=5

ARG NLI_MODEL=MoritzLaurer/bge-m3-zeroshot-v2.0-c
ENV NLI_MODEL=${NLI_MODEL}

# Server deps. torch ships in the base image. sentencepiece is needed by
# this model's XLM-RoBERTa-based tokenizer (same package docker/nli-runpod/
# installs for DeBERTa's own tokenizer -- unrelated model, same requirement).
RUN pip install --no-cache-dir \
        "transformers>=4.40,<5" \
        "sentencepiece>=0.2" \
        "fastapi>=0.110" \
        "uvicorn>=0.29" \
        "pydantic>=2"

# curl for the watchdog's RunPod REST API call; ca-certificates for HTTPS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/app

# Bake the model into the HF cache at build time.
COPY docker/nli-runpod-bge-m3/download_model.py /opt/app/download_model.py
RUN python /opt/app/download_model.py

COPY docker/nli-runpod-bge-m3/server.py /opt/app/server.py

# Idle watchdog: stops the pod after IDLE_MIN minutes with no /classify calls,
# via the RunPod REST API (needs only RUNPOD_API_KEY in the pod env — see
# nli_idle_watchdog.sh). No runpodctl dependency.
COPY docker/nli-runpod-bge-m3/nli_idle_watchdog.sh /usr/local/bin/nli_idle_watchdog.sh
RUN chmod +x /usr/local/bin/nli_idle_watchdog.sh

COPY docker/nli-runpod-bge-m3/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
