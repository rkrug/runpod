# `docker/nli-runpod-bge-m3/` — multilingual, long-context zero-shot NLI inference server

A self-contained Docker image that serves a HuggingFace
`zero-shot-classification`-style model (default
`MoritzLaurer/bge-m3-zeroshot-v2.0-c`) over a tiny FastAPI app. Drop it into
a RunPod GPU pod; the model is baked into the image at build time, so there
is no first-request download and no volume mount needed for weights.

Sibling of [`docker/nli-runpod/`](../nli-runpod/README.md) — identical
`/health`/`/metrics`/`/classify` contract and file layout, self-contained
per this repo's own `docker/CLAUDE.md` convention rather than sharing code
across the two directories. The only real difference is which model gets
baked in, and why: `bge-m3-zeroshot-v2.0-c` trades a bigger, heavier model
for **multilingual, cross-lingual entailment** (built on `BAAI/bge-m3-retromae`,
100+ languages) and a **much longer context window**
(`max_position_embeddings` ~8194, vs. `nli-runpod`'s DeBERTa-v3-large at a
hard 512) — for a use case where the hypothesis/claim is always in one
language but the premise text being checked against it can be in any
language the source document was written in. An English-only long-context
alternative (`MoritzLaurer/ModernBERT-large-zeroshot-v2.0`, also ~8k
context) was considered and rejected for exactly that reason.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | CUDA + torch base; installs transformers/fastapi/uvicorn; bakes the model in via `download_model.py`; adds the idle watchdog. |
| `server.py` | FastAPI app: `/health`, `/metrics`, `/classify`. Holds one model for the process lifetime. Byte-for-byte the same logic as `nli-runpod/server.py` (entailment index derived from the model's own `config.label2id`, not hardcoded) — only the default model-id strings differ. |
| `download_model.py` | Build-time model + tokenizer download into the HF cache. |
| `entrypoint.sh` | Log rotation, idle watchdog, `exec uvicorn`. |
| `nli_idle_watchdog.sh` | Polls `/metrics`; stops the pod after `IDLE_MIN` idle minutes via the RunPod REST API. |
| `.dockerignore` | Keeps the build context to this directory's own files. |

## GPU

**Not yet measured.** `bge-m3-zeroshot-v2.0-c` is a larger model (~568M
params) than `nli-runpod`'s DeBERTa-v3-large (~435M), and this image's
intended use sends much longer sequences (`NLI_MAX_LENGTH=2048` baked in,
vs. `nli-runpod`'s `512`) — an L4 (24 GB) is the starting point (same as
`nli-runpod`'s proven pool), not a validated one. Measure real throughput
and memory headroom before sizing a pod pool the way `nli-runpod`'s README
can, with actual numbers, for DeBERTa-v3-large.

## Build (from repo root)

```bash
docker buildx build --platform linux/amd64 \
    -t ghcr.io/<you>/nli-runpod-bge-m3:v0.1.0 \
    --build-arg IMAGE_SOURCE_URL=https://github.com/<you>/<your-fork> \
    -f docker/nli-runpod-bge-m3/Dockerfile .

docker push ghcr.io/<you>/nli-runpod-bge-m3:v0.1.0
```

`--platform linux/amd64` matters on Apple Silicon — RunPod nodes are amd64.

Swap the model at build time with `--build-arg NLI_MODEL=<hf-id>` (e.g. to
benchmark a different multilingual/long-context zero-shot NLI model) — same
mechanism as `nli-runpod`'s `Dockerfile`.

### Tagging

**Don't use moving tags** (`:latest`) for the pod template's Container Image —
RunPod's docs warn against them (caching surprises, no rollback). Use a semantic
version (`:v0.1.0`) or, strongest, the immutable digest:

```bash
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/<you>/nli-runpod-bge-m3:v0.1.0
```

## Use in RunPod

1. Push to a token-accessible registry (GHCR public, or with credentials).
2. Create pods with `scripts/runpod/create_pods.sh` (see the top-level
   [`docs/RunPodSetup.md`](../../docs/RunPodSetup.md)), or configure
   manually via RunPod → **GPU Pod** → "Edit Template":
   - Container Image: `ghcr.io/<you>/nli-runpod-bge-m3:v0.1.0` (or the `@sha256:…` digest)
   - Container Start Command: *(leave blank — entrypoint launches uvicorn)*
   - Expose HTTP port: `8080`
   - **Environment Variables**:
     - `RUNPOD_API_KEY` = your RunPod API key — **required** for the idle watchdog
     - `IDLE_MIN` = `5` (optional), `POLL_SEC` = `30` (optional)
3. Launch the pod. Health-check (the proxy host maps the exposed port into the
   hostname, so no `:8080`):
   ```bash
   HOST=<pod-id>-8080.proxy.runpod.net
   curl -s https://$HOST/health && echo
   curl -s https://$HOST/classify -H 'Content-Type: application/json' -d '{
     "sequences": ["Les stocks de carbone du sol ont fortement diminué après la conversion des terres."],
     "candidate_labels": ["supports", "refutes", "is not relevant to"],
     "hypothesis_template": "This example {} the following claim: Land-use change reduces terrestrial carbon storage.",
     "multi_label": false
   }' | jq
   ```
   (a non-English premise against an English claim, to exercise the
   cross-lingual case this image exists for — `nli-runpod`'s README's own
   example is English-only)
4. Point your project's NLI client at `$HOST`.

## Runtime tuning (no rebuild)

Set in the pod template **Environment Variables**:

| Var | Default | Notes |
|---|---|---|
| `NLI_PORT` | `8080` | Must match RunPod's exposed port. |
| `NLI_DEVICE` | `0` (CPU `-1` if no CUDA) | GPU index. |
| `NLI_MAX_LENGTH` | `2048` | Tokenizer truncation length. The model's own ceiling is ~8194 — this default is set to what this project's `nli.configs.bge_m3_zeroshot` actually sends, not the model's max. |
| `IDLE_MIN` | `5` | Idle minutes before the watchdog stops the pod. `0` (or unset `RUNPOD_API_KEY`) disables it. |
| `POLL_SEC` | `30` | Watchdog poll cadence. |
| `LOG_DIR` | `/workspace` | Volume-mounted path for persistent logs. |

## Local smoke test (CPU)

```bash
docker build -f docker/nli-runpod-bge-m3/Dockerfile -t nli-runpod-bge-m3:dev .
docker run --rm -p 8080:8080 -e NLI_DEVICE=-1 nli-runpod-bge-m3:dev
# then in another shell:
curl -s localhost:8080/health
```

CPU is slow (a few pairs/sec, and this model is larger than DeBERTa-v3-large)
— fine for a smoke test, not for a full run.
