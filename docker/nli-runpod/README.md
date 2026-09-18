# `docker/nli-runpod/` — zero-shot NLI inference server

A self-contained Docker image that serves a HuggingFace
`zero-shot-classification`-style model (default
`MoritzLaurer/deberta-v3-large-zeroshot-v2.0`) over a tiny FastAPI app. Drop it
into a RunPod GPU pod; the model is baked into the image at build time, so there
is no first-request download and no volume mount needed for weights.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | CUDA + torch base; installs transformers/fastapi/uvicorn; bakes the model in via `download_model.py`; adds the idle watchdog. |
| `server.py` | FastAPI app: `/health`, `/metrics`, `/classify`. Holds one model for the process lifetime. **This is the CANONICAL copy** — `docker/nli-runpod-bge-m3/server.py` is derived from it and must be re-derived (not hand-ported) after any change here; `test/smoke-test.sh` asserts the two stay byte-identical apart from that image's docstring, `NLI_MODEL`/`NLI_MAX_LENGTH` defaults and FastAPI title. |
| `download_model.py` | Build-time model + tokenizer download into the HF cache. |
| `entrypoint.sh` | Log rotation, idle watchdog, `exec uvicorn`. |
| `nli_idle_watchdog.sh` | Polls `/metrics`. Two phases: until the first request it stops the pod only after `STARTUP_GRACE_MIN`; once a request has been served it stops after `IDLE_MIN` idle minutes. Both via the RunPod REST API. |
| `.dockerignore` | Keeps the build context to this directory's own files. |

## GPU

An **L4 (24 GB)** is sufficient for DeBERTa-v3-large (tens of pairs/sec at
a reasonable batch size). L40S / A100 work too without rebuilding — the
cu121 wheels in the base image cover Ada/Ampere/Hopper.

## Build (from repo root)

```bash
docker buildx build --platform linux/amd64 \
    -t ghcr.io/<you>/nli-runpod:v0.1.0 \
    --build-arg IMAGE_SOURCE_URL=https://github.com/<you>/<your-fork> \
    -f docker/nli-runpod/Dockerfile .

docker push ghcr.io/<you>/nli-runpod:v0.1.0
```

`--platform linux/amd64` matters on Apple Silicon — RunPod nodes are amd64.

Swap the model at build time with `--build-arg NLI_MODEL=<hf-id>` (e.g. to
benchmark a different zero-shot NLI model).

### Tagging

**Don't use moving tags** (`:latest`) for the pod template's Container Image —
RunPod's docs warn against them (caching surprises, no rollback). Use a semantic
version (`:v0.1.0`) or, strongest, the immutable digest:

```bash
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/<you>/nli-runpod:v0.1.0
```

## Use in RunPod

1. Push to a token-accessible registry (GHCR public, or with credentials).
2. Create pods with `scripts/runpod/create_pods.sh` (see the top-level
   [`docs/RunPodSetup.md`](../../docs/RunPodSetup.md) and
   `scripts/runpod/config/pods.conf.nli.example`), or configure manually via
   RunPod → **GPU Pod** → "Edit Template":
   - Container Image: `ghcr.io/<you>/nli-runpod:v0.1.0` (or the `@sha256:…` digest)
   - Container Start Command: *(leave blank — entrypoint launches uvicorn)*
   - Expose HTTP port: `8080`
   - **Environment Variables**:
     - `RUNPOD_API_KEY` = your RunPod API key — **required** for the idle watchdog
     - `IDLE_MIN` = `5` (optional), `STARTUP_GRACE_MIN` = `60` (optional), `POLL_SEC` = `30` (optional)
3. Launch the pod. Health-check (the proxy host maps the exposed port into the
   hostname, so no `:8080`):
   ```bash
   HOST=<pod-id>-8080.proxy.runpod.net
   curl -s https://$HOST/health && echo
   curl -s https://$HOST/classify -H 'Content-Type: application/json' -d '{
     "sequences": ["Soil carbon stocks declined sharply after land conversion."],
     "candidate_labels": ["supports", "refutes", "is not relevant to"],
     "hypothesis_template": "This example {} the following claim: Land-use change reduces terrestrial carbon storage.",
     "multi_label": false
   }' | jq
   ```
4. Point your project's NLI client at `$HOST`.

## Runtime tuning (no rebuild)

Set in the pod template **Environment Variables**:

| Var | Default | Notes |
|---|---|---|
| `NLI_PORT` | `8080` | Must match RunPod's exposed port. |
| `NLI_DEVICE` | `0` (CPU `-1` if no CUDA) | GPU index. |
| `NLI_MAX_LENGTH` | `512` | Tokenizer truncation length. |
| `IDLE_MIN` | `5` | Idle minutes before the watchdog stops the pod — counted only **after** the pod has served its first request. `0` (or unset `RUNPOD_API_KEY`) disables it. |
| `STARTUP_GRACE_MIN` | `60` | Minutes the pod may live **without ever serving a request** before stopping itself. Covers both a pod nobody sends work to and one whose model never loads. `0` disables it (the pod then runs until stopped by hand). |
| `POLL_SEC` | `30` | Watchdog poll cadence. |
| `LOG_DIR` | `/workspace` | Volume-mounted path for persistent logs. |

## Local smoke test (CPU)

```bash
docker build -f docker/nli-runpod/Dockerfile -t nli-runpod:dev .
docker run --rm -p 8080:8080 -e NLI_DEVICE=-1 nli-runpod:dev
# then in another shell:
curl -s localhost:8080/health
```

CPU is slow (a few pairs/sec) — fine for a smoke test, not for a full run.
