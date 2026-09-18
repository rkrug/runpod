# `docker/bertopic-runpod/` — BERTopic GPU image

A RunPod-deployable image that runs BERTopic-style clustering with
`cuml.UMAP` + `cuml.HDBSCAN` on the GPU, so a multi-million-row corpus
fits in VRAM and clusters in minutes-to-hours instead of days.

The image is **not** self-running like the TEI image — it boots into an
SSH-ready idle state. An orchestrating script (in your own project repo)
scp's the embedding parquets in, ssh-triggers `/opt/run_bertopic_gpu.py`,
and scp's the result parquets back.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | RAPIDS base + BERTopic + sshd + idle watchdog. |
| `run_bertopic_gpu.py` | The GPU workload script, baked into the image at `/opt/run_bertopic_gpu.py`. |
| `entrypoint.sh` | Brings up sshd, starts the watchdog, `tail -f /dev/null`. |
| `bertopic_idle_watchdog.sh` | Heartbeat-based auto-stop after `IDLE_MIN` min. |
| `.dockerignore` | Keeps the build context to this directory's own files. |

## Requirements

### GPU — suggested: **L40S**

For a multi-million-row corpus + a few hundred reference/"keypaper" items:

| GPU | VRAM | Verdict |
|---|---|---|
| **L40S** ✅ | 48 GB | **Suggested.** cuml UMAP needs headroom for embeddings + workspace; HDBSCAN is light. Fits comfortably with margin. |
| A100 80GB | 80 GB | Safe headroom; pick if you'll run multiple ablations or scale the corpus. |
| H100 80GB | 80 GB | Overkill — cuml on this workload doesn't benefit from H100 tensor cores. |
| L40 (non-S) | 48 GB | Same VRAM as L40S, ~30–50% slower compute. Cheaper if patience > speed. |
| A40 | 48 GB | Cheap, slow, works. |

Cuml auto-selects the right CUDA kernels at runtime, so the same image
runs on any of the above without rebuilding.

### CPU & RAM

| Resource | Minimum | Recommended |
|---|---|---|
| vCPUs | 8 | 16+ (faster parquet read) |
| System RAM | 80 GB | **120 GB+** |

BERTopic-style clustering holds the full embedding dataframe in CPU
memory before pushing to GPU. Size to your corpus: N rows × D dims ×
4 bytes (float32), plus pandas/pyarrow overhead and vectorizer peaks.

### Disk

| Mount | Size | Rationale |
|---|---|---|
| **Container disk** | 25 GB | Image + Python heap + scratch + logs. |
| **Volume disk** at `/work` | **60 GB** (adjust to your corpus size) | Uploaded embedding parquets + outputs + heartbeat + scratch room. |

Volume disk survives pod stop/restart; container disk is ephemeral.

### Network

- **TCP/22** exposed via RunPod's TCP port mapping — required for SSH-based
  orchestration and any bulk rsync transfer.
- No HTTP ports needed.

### Pre-flight checklist

1. Image pushed to a registry (e.g. GHCR), **public** visibility (so RunPod can pull without credentials).
2. Your SSH public key content ready — goes into the template's `PUBLIC_KEY` env var.
3. `RUNPOD_API_KEY` saved as a **Secret** in RunPod settings.
4. Volume size sized to your embedding data.

## Build (from repo root)

```bash
docker buildx build --platform linux/amd64 \
    -t ghcr.io/<you>/bertopic-runpod:v0.1.0 \
    --build-arg IMAGE_SOURCE_URL=https://github.com/<you>/<your-fork> \
    -f docker/bertopic-runpod/Dockerfile .

docker push ghcr.io/<you>/bertopic-runpod:v0.1.0
```

`--platform linux/amd64` matters on Apple Silicon — RunPod is amd64.

No per-GPU tag needed (unlike the TEI image): cuml auto-selects the right
CUDA kernels at runtime for L40, L40S, A100, H100, etc.

### Tagging strategy

**Don't use `:latest`** for the pod template's `Container Image` field —
RunPod's own docs warn against it (caching surprises + no rollback).

Use either of:

- **Semantic version** (`:v0.1.0`) — manual but human-readable. Bump on
  meaningful changes; pin the pod template to a specific version.
- **Immutable digest** (`@sha256:abc123…`) — strongest reproducibility
  guarantee. Get it after a push with:
  ```bash
  docker inspect --format='{{index .RepoDigests 0}}' \
      ghcr.io/<you>/bertopic-runpod:v0.1.0
  ```

Re-tagging an existing image is essentially free — only the manifest
gets pushed, not the GBs of layers:

```bash
docker tag  ghcr.io/<you>/bertopic-runpod:v0.1.0 \
            ghcr.io/<you>/bertopic-runpod:v0.2.0
docker push ghcr.io/<you>/bertopic-runpod:v0.2.0
```

## Pod template

Create pods with `scripts/runpod/create_pods.sh` (see the top-level
[`docs/RunPodSetup.md`](../../docs/RunPodSetup.md) and
`scripts/runpod/config/pods.conf.bertopic.example`), or configure manually
via RunPod → **GPU Pod** → "Edit Template":

- **Container Image**: `ghcr.io/<you>/bertopic-runpod:v0.2.0` (or the immutable `@sha256:…` digest — see "Tagging strategy"). **Use v0.2.0 (or at minimum v0.1.17)** — v0.1.0 predates the v0.1.17 watchdog fix and still calls `runpodctl stop pod`, which fails silently, so those pods never idle-stop and keep billing.
- **Container Start Command**: *(leave blank — entrypoint handles it)*
- **Expose TCP Ports**: `22` (SSH transport)
- **Container Disk**: `20 GB` (logs + temp work)
- **Volume Disk**: sized to your embedding data, mounted at `/work`
- **Environment Variables**:
  - `PUBLIC_KEY` = the contents of your SSH public key (one line). The
    entrypoint injects this into `/root/.ssh/authorized_keys` at boot so
    sshd accepts your key. **Plain env var, not a Secret** — the public
    half is public by definition. Required for SSH access.
  - `RUNPOD_API_KEY` = your RunPod API key (use a **Secret** for this
    one) — required for the idle watchdog to self-stop via the REST API.
  - `IDLE_MIN` = `5` (override of the image default; see "Tuning" below)
  - `POLL_SEC` = `30`

## Use from an orchestrating script

After the pod boots, note its SSH connection info (host/port), then invoke
the baked-in workload script over SSH:

```bash
python /opt/run_bertopic_gpu.py \
    --corpus-emb-dir s3://<bucket>/embeddings/config=<name>/ \
    --reference-emb-dir s3://<bucket>/embeddings/config=<name>/ \
    --output-dir /work/out \
    --bertopic-cfg-yaml /work/run_cfg.yaml \
    --run-name <run-name>
```

Your own project's wrapper is responsible for: writing `run_cfg.yaml`
(with a `r2:`/`s3:` block for the object-storage endpoint/bucket/region),
rsyncing it to the pod, invoking the command above over SSH, and rsyncing
the three result parquets (`topic_info.parquet`, `topics.parquet`,
`topic_words.parquet`) back.

## Idle auto-stop

`bertopic_idle_watchdog.sh` polls `/work/.heartbeat` every `POLL_SEC`
seconds. The heartbeat is touched:

- At boot, by the entrypoint
- At start + after each step, by `run_bertopic_gpu.py`
- (Optional) manually during interactive SSH: `touch /work/.heartbeat`

If `now - heartbeat_mtime ≥ IDLE_MIN`, the watchdog calls the RunPod REST
API to stop the pod. Billing pauses, volume + image cache survive —
restart from the RunPod UI when next needed.

### Tuning

Override at pod-template level:

| Var | Default | Effect |
|---|---|---|
| `IDLE_MIN` | `5` | Minutes of no heartbeat → stop — counted only **after** the heartbeat has been touched by a job or session (this watchdog's own initialising touch does not count). `0` disables it. |
| `STARTUP_GRACE_MIN` | `60` | Minutes the pod may live **without ever touching the heartbeat** before stopping itself. Covers both a pod nobody sends work to and one whose job never starts. `0` disables it. |
| `POLL_SEC` | `30` | Watchdog check cadence. |
| `HEARTBEAT_PATH` | `/work/.heartbeat` | File whose mtime is "last activity". |
| `LOG_DIR` | `/work` | Where the entrypoint persists its log file. |

## Persistent logs

The entrypoint tees its own output (and the watchdog's, via inherited
fds) to `${LOG_DIR}/bertopic-current.log`. Goes to a volume-mounted path
so it survives pod stop/restart.

**On every boot**, the previous run's log is renamed:
`bertopic-current.log` → `bertopic-previous.log` (old previous is
overwritten). You always have one historical log, never more — bounded
space, no log-rotation daemon needed.

Reading after a crash:

```bash
ssh <pod> "tail -200 /work/bertopic-previous.log"
```

The GPU script's own progress logs (`print()` output) stream through
this same log (thanks to `PYTHONUNBUFFERED=1`); an orchestrating script
may additionally capture its own copy under `/work/` if desired.

Set `IDLE_MIN=0` or omit `RUNPOD_API_KEY` to effectively disable the
watchdog's self-stop.

## Why bake everything into one image

- Cold-start latency: image already has BERTopic, cuml, the GPU script —
  ready seconds after the pod boots.
- Reproducibility: `docker pull <digest>` = exact code that produced a
  given result.
- No "first-boot pip install" wasting GPU time.

Trade-off: image is ~5–7 GB heavier than the stock RAPIDS image.
Negligible vs the cost of running the pod.
