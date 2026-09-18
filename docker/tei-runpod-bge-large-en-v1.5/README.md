# `docker/tei-runpod-bge-large-en-v1.5/` — TEI embedding server (BGE-large-en-v1.5)

A self-contained Docker image that serves [`BAAI/bge-large-en-v1.5`](https://hf.co/BAAI/bge-large-en-v1.5)
over [TEI](https://github.com/huggingface/text-embeddings-inference). Drop it
into a RunPod pod; the model is baked into the image at build time, so there
is no first-request download and no volume mount needed for weights.

Sibling of [`docker/tei-runpod/`](../tei-runpod/README.md), which serves a
*merged SPECTER2 adapter* and therefore needs a build-time adapter-merge
stage. This image serves an off-the-shelf model, so its first stage is just a
download — no merge, no `adapters` dependency.

| | |
|---|---|
| Model | `BAAI/bge-large-en-v1.5` |
| Architecture | `BertModel` (core-supported by TEI) |
| Parameters | ~335M |
| Embedding dimensions | 1024 |
| Max input tokens | **512** (hard architectural cap) |
| Pooling | CLS (per the model's own `1_Pooling/config.json`) |

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Two stages: download the model, then copy it into the TEI runtime. |
| `download_model.py` | Build-time model download. Picks weight format via `--weights`; fails the build if the requested format doesn't exist upstream. |
| `entrypoint.sh` | Log rotation, idle watchdog, `exec text-embeddings-router`. |
| `tei_idle_watchdog.sh` | Polls `/metrics`; stops the pod after `IDLE_MIN` idle minutes via the RunPod REST API. |
| `.dockerignore` | Keeps the build context to this directory's own files. |

## `TEI_TAG` and `MODEL_WEIGHTS` must agree

This is the one genuinely easy thing to get wrong. TEI's two backend families
read **different weight files**:

| Target | `TEI_TAG` | `MODEL_WEIGHTS` | Reads |
|---|---|---|---|
| GPU (default) | `89-1.5` — see the tag/GPU table below | `safetensors` | `/model/model.safetensors` |
| CPU (local testing) | `cpu-1.6` | `onnx` | `/model/onnx/model.onnx` |

### Picking `TEI_TAG` for your GPU

TEI ships one image per CUDA compute capability, and picking the wrong one
means the container won't start:

| GPU | `TEI_TAG` |
|---|---|
| **L4, L40S, RTX 4090**, RTX 4000/6000 Ada (Ada Lovelace, 8.9) | `89-1.5` ← image default |
| A10, A40, A6000, A5000, RTX 3090 (Ampere 8.6) | `86-1.5` |
| A100, A30 (Ampere 8.0) | `1.5` — the **untagged** variant |
| H100 (Hopper 9.0) | `hopper-1.5` |
| T4, RTX 2000 (Turing 7.5) | `turing-1.5` (experimental) |
| CPU only | `cpu-1.6` |

Two traps worth knowing: there is **no `80-1.5` tag** (compute-8.0 A100 uses
the plain `1.5` image), and **H100 is not covered by `89-*`** despite both
being "modern" — it needs `hopper-*`. Verified against
[TEI's supported-hardware table](https://github.com/huggingface/text-embeddings-inference/blob/main/docs/source/en/supported_models.md).

Mismatch them and nothing errors at build time — the pod just silently
re-downloads the format it actually wants on first boot, throwing away the
point of baking the model in (and failing outright on a pod without outbound
Hub access). `entrypoint.sh` warns at boot if neither format is present.

`MODEL_WEIGHTS=both` bakes both formats into one image usable on either
backend, at roughly double the size (~1.3 GB per format).

## Build (from repo root)

```bash
# GPU image, for actual RunPod deployment
docker buildx build --platform linux/amd64 \
    -t ghcr.io/<you>/tei-runpod-bge-large-en-v1.5:v0.1.0 \
    -f docker/tei-runpod-bge-large-en-v1.5/Dockerfile .

docker push ghcr.io/<you>/tei-runpod-bge-large-en-v1.5:v0.1.0
```

`--platform linux/amd64` matters on Apple Silicon — RunPod nodes are amd64.

Swap the model at build time with `--build-arg MODEL_ID=<hf-id>` (the
downloader is model-agnostic), though anything with a different embedding
dimensionality, pooling mode, or token cap wants its own image directory and
config example rather than a silent override here.

### Tagging

**Don't use moving tags** (`:latest`) for the pod template's Container Image —
RunPod's docs warn against them (caching surprises, no rollback). Use a
semantic version (`:v0.1.0`) or, strongest, the immutable digest:

```bash
docker inspect --format='{{index .RepoDigests 0}}' \
    ghcr.io/<you>/tei-runpod-bge-large-en-v1.5:v0.1.0
```

## Use in RunPod

Create pods with `scripts/runpod/create_pods.sh` and
[`scripts/runpod/config/pods.conf.tei-bge-large-en-v1.5.example`](../../scripts/runpod/config/pods.conf.tei-bge-large-en-v1.5.example),
or configure manually: RunPod → **GPU Pod** → "Edit Template":

- Container Image: `ghcr.io/<you>/tei-runpod-bge-large-en-v1.5:v0.1.0`
- Container Start Command: *(leave blank — the entrypoint launches TEI)*
- Expose HTTP port: `8080`
- **Environment Variables**: `RUNPOD_API_KEY` (**required** for the idle
  watchdog's self-stop), optionally `IDLE_MIN`, `POLL_SEC`

Health-check and embed:

```bash
HOST=<pod-id>-8080.proxy.runpod.net
curl -s https://$HOST/health && echo
curl -s https://$HOST/embed -H 'Content-Type: application/json' \
     -d '{"inputs":"hello world"}' | jq 'length'      # -> 1
```

## GPU sizing

**Memory is not the constraint.** ~335M params in fp16 is under 1 GB of
weights, and the hard 512-token cap bounds activations tightly — any 24 GB
card has ample room. So choose on throughput per dollar, not capacity.

| GPU | VRAM | Mem bandwidth | `TEI_TAG` | Notes |
|---|---|---|---|---|
| **RTX 4090** ← suggested | 24 GB | ~1008 GB/s | `89-1.5` (default) | ~3x an L4's bandwidth in the same generation and VRAM. Best throughput/$ for this model. Community cloud; check availability. |
| L40S | 48 GB | ~864 GB/s | `89-1.5` (default) | Secure-cloud availability, ECC, 2x headroom. The safer pick if 4090 capacity is scarce. |
| L4 | 24 GB | ~300 GB/s | `89-1.5` (default) | Cheapest per hour, lowest power — but the slowest of these by a wide margin. Fine for small or bursty batches. |
| A100 80GB | 80 GB | ~2039 GB/s | **`1.5`** (rebuild) | Genuinely faster, wildly overprovisioned on memory. Needs the untagged compute-8.0 image. |

For bulk corpus embedding, the bandwidth gap matters more than the hourly
rate: a 3x faster card turns a 9-hour backlog into 3 hours, which usually
more than pays for itself.

**Not benchmarked for this model** — the table reasons from published
bandwidth/compute specs. Measure yours with this repo's own tooling:

```bash
scripts/runpod/http-pool/watch_gpu.sh -u https://<host> \
    --metric te_request_count --unit embeds/s
```

## Runtime tuning (no rebuild)

| Var | Default | Notes |
|---|---|---|
| `TEI_PORT` | `8080` | Must match RunPod's exposed port. |
| `TEI_MAX_BATCH_TOKENS` | `32768` | Server token budget per batch. Lower than `docker/tei-runpod/`'s 131072, which was tuned for A100/H100. |
| `TEI_MAX_CONCURRENT` | `512` | Concurrent in-flight requests. |
| `TEI_MAX_CLIENT_BATCH` | `128` | Per-HTTP-request texts. |
| `TEI_POOLING` | `cls` | **Don't change.** This model specifies CLS pooling; mean pooling yields quietly wrong embeddings, not an error. |
| `MODEL_PATH` | `/model` | Where the baked-in model lives. |
| `LOG_DIR` | `/workspace` | Volume-mounted path for persistent logs. |
| `IDLE_MIN` | `5` | Idle minutes before the watchdog stops the pod — counted only **after** the pod has served its first request. `0` disables it. |
| `STARTUP_GRACE_MIN` | `60` | Minutes the pod may live **without ever serving a request** before stopping itself. Covers both a pod nobody sends work to and one whose model never loads. `0` disables it. |
| `POLL_SEC` | `30` | Watchdog poll cadence. |
| `RUNPOD_API_KEY` | *(unset)* | **Required** for the watchdog's self-stop REST call. |

## Normalization

TEI's `/embed` normalizes by default (`"normalize": true`). BGE models are
trained for cosine similarity on normalized vectors, so leave it on unless
you have a specific reason not to.

## Local smoke test (CPU, no GPU needed)

Covered by `test/smoke-test.sh`, which builds this image against `cpu-1.6`
and checks `/health`, that `/embed` returns exactly 1024 dims, that
`/metrics` exposes `te_request_count`, and that the weights were **not**
re-downloaded at boot. To do it by hand:

```bash
docker buildx build --platform linux/amd64 \
    --build-arg TEI_TAG=cpu-1.6 --build-arg MODEL_WEIGHTS=onnx \
    -t tei-bge:cputest -f docker/tei-runpod-bge-large-en-v1.5/Dockerfile .

docker run --rm -p 8080:8080 tei-bge:cputest
curl -s localhost:8080/embed -H 'Content-Type: application/json' \
     -d '{"inputs":"hello"}' | jq '.[0] | length'     # -> 1024
```

## Verification status

- ✅ **CPU image**: built and run locally. Serves `/health`, `/info`,
  `/embed` (1024 dims), `/metrics`; boots from baked-in weights in ~2 s with
  no Hub download; semantic sanity-checked (related sentences score ~0.81
  cosine vs. ~0.28 for unrelated).
- ⚠️ **GPU image**: not yet built or run against a real RunPod pod. The
  architecture is core-supported by TEI (plain BERT), and only the base image
  tag and weight format differ from the verified CPU build — but the CUDA
  path itself and all GPU sizing guidance above remain unmeasured.
