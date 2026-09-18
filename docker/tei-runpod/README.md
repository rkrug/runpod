# `docker/tei-runpod/` — TEI image with merged SPECTER2

A self-contained Docker image that runs [TEI](https://github.com/huggingface/text-embeddings-inference)
against a SPECTER2 adapter merged into the image at build time. Drop into a
RunPod pod template; no volume mount, no first-boot download.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage: stage 1 merges the SPECTER2 adapter; stage 2 is the TEI runtime with the merged model copied in. |
| `prepare_specter2_merged.py` | Merge script run inside the build (also usable standalone for local testing). |
| `entrypoint.sh` | Pod-side launch command; reads env vars for tuning. |
| `tei_idle_watchdog.sh` | Background process that self-stops the pod after idle minutes (see "Idle auto-stop" below). |
| `.dockerignore` | Keeps the build context tiny (only this directory's own files). |

## Build (from repo root)

Tag with **`<adapter>-v<version>`** — see "Tagging strategy" below for
why moving tags like `:proximity` alone should be avoided.

```bash
# Proximity adapter (corpus embedding side)
docker buildx build --platform linux/amd64 \
    -t ghcr.io/<you>/tei-specter2:proximity-v0.1.0 \
    --build-arg ADAPTER=proximity \
    --build-arg TEI_TAG=89-1.5 \
    --build-arg IMAGE_SOURCE_URL=https://github.com/<you>/<your-fork> \
    -f docker/tei-runpod/Dockerfile .

# Adhoc-query adapter (query-time)
docker buildx build --platform linux/amd64 \
    -t ghcr.io/<you>/tei-specter2:adhoc_query-v0.1.0 \
    --build-arg ADAPTER=adhoc_query \
    --build-arg TEI_TAG=89-1.5 \
    --build-arg IMAGE_SOURCE_URL=https://github.com/<you>/<your-fork> \
    -f docker/tei-runpod/Dockerfile .

docker push ghcr.io/<you>/tei-specter2:proximity-v0.1.0
docker push ghcr.io/<you>/tei-specter2:adhoc_query-v0.1.0
```

`--platform linux/amd64` matters on Apple Silicon — RunPod nodes are amd64.

### Tagging strategy

**Don't use moving tags** (`:proximity`, `:adhoc_query`, `:latest`) for
the pod template's `Container Image` field. RunPod's docs warn against
them — caching surprises + no rollback if a new build is broken.

Use either of:

- **Semantic version** (`:proximity-v0.1.0`) — manual but readable; pin
  the pod template to a specific version.
- **Immutable digest** (`@sha256:abc123…`) — strongest reproducibility
  guarantee. After a push:
  ```bash
  docker inspect --format='{{index .RepoDigests 0}}' \
      ghcr.io/<you>/tei-specter2:proximity-v0.1.0
  ```
  Use the resulting `@sha256:…` string in the pod template.

Re-tagging an existing image is essentially free — only the manifest is
pushed, not the GBs of layers:

```bash
docker tag  ghcr.io/<you>/tei-specter2:proximity-v0.1.0 \
            ghcr.io/<you>/tei-specter2:proximity-v0.2.0
docker push ghcr.io/<you>/tei-specter2:proximity-v0.2.0
```

### Picking `TEI_TAG`

Match TEI's CUDA build to the GPU family you'll rent:

| GPU | Suggested tag |
|---|---|
| L4, L40S, RTX 4090, RTX 4000/6000 Ada (Ada Lovelace, 8.9) | `89-1.5` |
| A10, A40, A6000, A5000, RTX 3090 (Ampere 8.6) | `86-1.5` |
| A100, A30 (Ampere 8.0) | `1.5` — the **untagged** variant |
| H100 (Hopper 9.0) | `hopper-1.5` |
| T4, RTX 2000 (Turing 7.5) | `turing-1.5` (experimental) |

Two traps: there is **no `80-1.5` tag** (compute-8.0 A100 uses the plain
`1.5` image), and **H100 is not covered by `89-*`** — it needs `hopper-*`.

Wrong tag → the binary refuses to start on that GPU. List of tags:
[ghcr.io/huggingface/text-embeddings-inference](https://github.com/huggingface/text-embeddings-inference/pkgs/container/text-embeddings-inference).

## Use in RunPod

1. Push to a public-or-token-accessible registry (GHCR, Docker Hub).
2. Create pods with `scripts/runpod/create_pods.sh` (see the top-level
   [`docs/RunPodSetup.md`](../../docs/RunPodSetup.md) and
   `scripts/runpod/config/pods.conf.tei.example`), or configure manually:
   RunPod → **GPU Pod** → "Edit Template".
   - Container Image: `ghcr.io/<you>/tei-specter2:proximity-v0.2.0` (or the immutable `@sha256:…` digest — see "Tagging strategy"). **Use v0.2.0 (or at minimum v0.1.3)** — v0.1.0/v0.1.1 predate the v0.1.2 watchdog fix and still call `runpodctl stop pod`, which fails silently, so those pods never idle-stop and keep billing.
   - Container Start Command: *(leave blank — entrypoint launches TEI)*
   - Expose HTTP port: `8080`
   - **Environment Variables** (for the idle-watchdog auto-stop):
     - `RUNPOD_API_KEY` = your RunPod API key (Settings → API Keys) — **required**
     - `IDLE_MIN` = `5` (optional override of the image default; see "Tuning" below)
     - `POLL_SEC` = `30` (optional override of the image default)
3. Launch pod. Health-check:
   ```bash
   HOST=<pod-id>-8080.proxy.runpod.net
   curl -s https://$HOST/health && echo
   curl -s https://$HOST/embed -H 'Content-Type: application/json' \
        -d '{"inputs":"hello"}' | jq 'length'
   ```
4. Point your project's embedding config at `$HOST` and run your pipeline.

## Runtime tuning (without rebuilding)

Set in RunPod template **Environment Variables**:

| Var | Default | Notes |
|---|---|---|
| `TEI_PORT` | `8080` | Must match RunPod's exposed port. |
| `TEI_MAX_BATCH_TOKENS` | `131072` | Server token budget per batch. |
| `TEI_MAX_CONCURRENT` | `2048` | Concurrent in-flight requests. |
| `TEI_MAX_CLIENT_BATCH` | `512` | Per-HTTP-request texts; client batch size. |
| `TEI_SERVED_NAME` | `allenai/specter2_<adapter>_merged` | Surfaces in `/info`. |
| `IDLE_MIN` | `5` | Minutes of TEI inactivity before the idle watchdog stops the pod — counted only **after** the pod has served its first request. **Tune to taste** — see below. `0` disables it. |
| `STARTUP_GRACE_MIN` | `60` | Minutes the pod may live **without ever serving a request** before stopping itself. Covers both a pod nobody sends work to and one whose model never loads. `0` disables it. |
| `POLL_SEC` | `30` | How often the watchdog samples TEI's request counter. Lower → faster shutdown after last request; higher → less log noise. |
| `LOG_DIR` | `/workspace` | Where the entrypoint persists the TEI log file (see "Persistent logs" below). Must be the volume-mounted path on the pod. |
| `RUNPOD_API_KEY` | *(unset)* | **Required** for the idle watchdog to be able to self-stop via the RunPod REST API. Set in the pod template. |

## Persistent logs

The entrypoint tees TEI's stdout+stderr (and the watchdog's output) to
`${LOG_DIR}/tei-current.log`. Goes to a volume-mounted path so it
survives pod stop/restart — crucial for post-mortem after a crash
(RunPod's web Logs panel resets on every restart, but the file on the
volume doesn't).

**On every boot**, the previous run's log is renamed:
`tei-current.log` → `tei-previous.log` (old previous is overwritten).
You always have exactly one historical log, never more — bounded space,
no log-rotation daemon needed.

Reading after a crash:

```bash
ssh <pod> "tail -200 /workspace/tei-previous.log"
```

(SSH access on the TEI pod isn't enabled by default; either turn it on
in the template or use the RunPod web terminal to scroll the file.)

### Size considerations

TEI logs one INFO line per HTTP `/embed` request, so a full 10 h embed
run accumulates **~1.0–1.5 GB** of log. With two generations on the
volume (current + previous), peak ~3 GB.

For your typical pod template (Volume Disk: 10 GB minimum on TEI), that
leaves comfortable headroom. If you really want to trim:

- TEI flag `--json-output` is denser (one JSON object per line) but
  still ~same total bytes.
- Pipe through `grep -v 'INFO embed{'` if you only want warnings/errors.

## Idle auto-stop (pod-side watchdog)

`tei_idle_watchdog.sh` runs in the background alongside TEI on the pod. It
polls TEI's `/metrics` endpoint every `POLL_SEC` seconds and tracks the
cumulative request counter. After `IDLE_MIN` minutes with no new requests
it calls the RunPod REST API (`POST /v1/pods/<id>/stop`) to pause billing.
The volume and image cache survive; restart from the RunPod UI when needed.

This protects against:
- Laptop crashes / sleeps mid-run leaving a pod running for hours.
- Forgetting to manually stop after a job finishes.
- Pipeline pauses overnight between runs.

### Tuning — both knobs are overridable per pod

The image default is `IDLE_MIN=5`, `POLL_SEC=30`. **Override either value
without rebuilding** by setting it in the pod template's Environment
Variables UI:

| Workflow | Suggested `IDLE_MIN` | Why |
|---|---|---|
| One big embed run, then days idle | `5` (default) | Stops fast after the run finishes; cold-restart cost is rare. |
| Iterating on prompts / scoring | `15`–`30` | Avoids restart latency between many small runs. |
| Live-demo / interactive use | `60` | Don't shut down while a user is mid-question. |

Unset `RUNPOD_API_KEY` to disable the watchdog's self-stop (it will still
run and log, but the stop call is skipped).

## Why bake the model in (vs. mount a volume)

- Cold-start latency: image already has weights → TEI ready in seconds.
- Reproducibility: `docker pull <digest>` = exact model bytes; no drift.
- No `runpodctl send/receive` ceremony.

Trade-off: the image is ~500 MB heavier than the stock TEI image. Negligible
for repeated runs; rebuild only when you bump SPECTER2 or the base image.
