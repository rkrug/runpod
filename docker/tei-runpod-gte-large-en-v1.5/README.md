# `docker/tei-runpod-gte-large-en-v1.5/` — TEI embedding server (GTE-large-en-v1.5)

A self-contained Docker image that serves [`Alibaba-NLP/gte-large-en-v1.5`](https://hf.co/Alibaba-NLP/gte-large-en-v1.5)
over [TEI](https://github.com/huggingface/text-embeddings-inference). Drop it
into a RunPod pod; the model is baked into the image at build time, so there
is no first-request download and no volume mount needed for weights.

Sibling of [`docker/tei-runpod/`](../tei-runpod/README.md), which serves a
*merged SPECTER2 adapter* and therefore needs a build-time adapter-merge
stage. This image serves an off-the-shelf model, so its first stage is just a
download — no merge, no `adapters` dependency.

| | |
|---|---|
| Model | `Alibaba-NLP/gte-large-en-v1.5` |
| Architecture | `NewModel` / `model_type: new` — TEI's "Alibaba GTE" support |
| Parameters | ~434M |
| Embedding dimensions | 1024 |
| Max input tokens | **8192** |
| Pooling | CLS (per the model's own `1_Pooling/config.json`) |

**On `trust_remote_code`:** this model's `config.json` carries an `auto_map`
pointing at remote modelling code, which `transformers` would need
`trust_remote_code=True` to run. TEI does **not** use that path — it has a
native Rust implementation and lists `Alibaba-NLP/gte-large-en-v1.5`
explicitly among its supported models, so no remote code is executed here.

## The 8192-token context is the reason to pick this image

Every other embedding model in this repo is capped at 512 tokens. This one
accepts 16× that, which is the whole point of it — but it has a cost that
isn't obvious from the parameter count: attention activation memory scales
with sequence length, so a batch of long documents is far heavier than the
same token budget spread across short ones.

Concretely, the default `TEI_MAX_BATCH_TOKENS=32768` is only **~4
maximum-length documents per batch**. If your inputs are short passages, this
behaves like any other large embedding model. If they're genuinely long
documents, measure with your real input-length distribution before sizing a
pod — see "GPU sizing" below.

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
backend, at roughly double the size (~1.7 GB per format).

Note this repo's downloader deliberately pulls only `onnx/model.onnx`, not
`onnx/*` — upstream also publishes fp16/int8/q4/bnb4/uint8 variants that TEI
doesn't use and that would bloat the image for nothing.

## Build (from repo root)

```bash
# GPU image, for actual RunPod deployment
docker buildx build --platform linux/amd64 \
    -t ghcr.io/<you>/tei-runpod-gte-large-en-v1.5:v0.1.0 \
    -f docker/tei-runpod-gte-large-en-v1.5/Dockerfile .

docker push ghcr.io/<you>/tei-runpod-gte-large-en-v1.5:v0.1.0
```

`--platform linux/amd64` matters on Apple Silicon — RunPod nodes are amd64.

### Tagging

**Don't use moving tags** (`:latest`) for the pod template's Container Image —
RunPod's docs warn against them (caching surprises, no rollback). Use a
semantic version (`:v0.1.0`) or, strongest, the immutable digest:

```bash
docker inspect --format='{{index .RepoDigests 0}}' \
    ghcr.io/<you>/tei-runpod-gte-large-en-v1.5:v0.1.0
```

## Use in RunPod

Create pods with `scripts/runpod/create_pods.sh` and
[`scripts/runpod/config/pods.conf.tei-gte-large-en-v1.5.example`](../../scripts/runpod/config/pods.conf.tei-gte-large-en-v1.5.example),
or configure manually: RunPod → **GPU Pod** → "Edit Template":

- Container Image: `ghcr.io/<you>/tei-runpod-gte-large-en-v1.5:v0.1.0`
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

On parameter count alone (~434M, under 1 GB in fp16) any 24 GB card would
do, and the throughput/$ winner would be an RTX 4090. **But this is the one
model here that takes 8192-token inputs**, and activation memory scales with
sequence length — so with long documents, VRAM becomes the binding
constraint well before the weights suggest. That's why the suggestion is
different from this repo's `bge-large-en-v1.5` image.

| GPU | VRAM | Mem bandwidth | `TEI_TAG` | Notes |
|---|---|---|---|---|
| **L40S** ← suggested | 48 GB | ~864 GB/s | `89-1.5` (default) | Ada-generation speed *and* 48 GB of headroom for long inputs. The balanced pick. |
| RTX 4090 | 24 GB | ~1008 GB/s | `89-1.5` (default) | Fastest and often cheapest — the right call **if your inputs are short passages**. 24 GB is the risk you accept. |
| A100 80GB | 80 GB | ~2039 GB/s | **`1.5`** (rebuild) | The safe answer if you routinely embed maximum-length documents. Needs the untagged compute-8.0 image. |
| L4 | 24 GB | ~300 GB/s | `89-1.5` (default) | Cheapest, but both the slowest here and the tightest on memory — the worst combination for this particular model. |

**Not benchmarked for this model** — the table reasons from published
bandwidth/compute specs plus the context-length argument. Because the right
answer here depends on your input-length distribution more than on the model,
measure with real data before sizing a pool:

```bash
scripts/runpod/http-pool/watch_gpu.sh -u https://<host> \
    --metric te_request_count --unit embeds/s
```

## Runtime tuning (no rebuild)

| Var | Default | Notes |
|---|---|---|
| `TEI_PORT` | `8080` | Must match RunPod's exposed port. |
| `TEI_MAX_BATCH_TOKENS` | `32768` | Server token budget per batch — only ~4 maximum-length inputs. Raise only alongside a GPU with the memory for it. |
| `TEI_MAX_CONCURRENT` | `512` | Concurrent in-flight requests. |
| `TEI_MAX_CLIENT_BATCH` | `128` | Per-HTTP-request texts. |
| `TEI_POOLING` | `cls` | **Don't change.** This model specifies CLS pooling; mean pooling yields quietly wrong embeddings, not an error. |
| `MODEL_PATH` | `/model` | Where the baked-in model lives. |
| `LOG_DIR` | `/workspace` | Volume-mounted path for persistent logs. |
| `IDLE_MIN` | `5` | Idle minutes before the watchdog stops the pod. |
| `POLL_SEC` | `30` | Watchdog poll cadence. |
| `RUNPOD_API_KEY` | *(unset)* | **Required** for the watchdog's self-stop REST call. |

## Local smoke test (CPU, no GPU needed)

Covered by `test/smoke-test.sh`, which builds this image against `cpu-1.6`
and checks `/health`, that `/embed` returns exactly 1024 dims, that
`/metrics` exposes `te_request_count`, and that the weights were **not**
re-downloaded at boot. To do it by hand:

```bash
docker buildx build --platform linux/amd64 \
    --build-arg TEI_TAG=cpu-1.6 --build-arg MODEL_WEIGHTS=onnx \
    -t tei-gte:cputest -f docker/tei-runpod-gte-large-en-v1.5/Dockerfile .

docker run --rm -p 8080:8080 tei-gte:cputest
curl -s localhost:8080/embed -H 'Content-Type: application/json' \
     -d '{"inputs":"hello"}' | jq '.[0] | length'     # -> 1024
```

## Verification status

- ✅ **CPU image**: built and run locally. Serves `/health`, `/info`
  (reports `max_input_length: 8192`, `pooling: cls`), `/embed` (1024 dims),
  `/metrics`; boots from baked-in weights with no Hub download; semantic
  sanity-checked (related sentences score ~0.78 cosine vs. ~0.39 for
  unrelated).
- ⚠️ **GPU image**: not yet built or run against a real RunPod pod. TEI
  lists this model as natively supported and only the base image tag and
  weight format differ from the verified CPU build — but the CUDA path
  itself and all GPU sizing guidance above remain unmeasured, and this is
  the model in this repo where long-input memory behaviour is most likely
  to surprise you.
