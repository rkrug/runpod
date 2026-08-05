# RunPod setup walkthrough

A step-by-step guide to standing up one of this repo's images on RunPod,
from a blank RunPod account to a working, reachable pod.

## 1. Prerequisites

- A RunPod account with billing set up: https://runpod.io
- A RunPod API key: Settings → API Keys. Export it in your shell:
  ```bash
  export RUNPOD_API_KEY=...
  ```
- `curl` and `jq` installed locally (used by `create_pods.sh`/`stop_pods.sh`).
- A container registry you can push to (GHCR, Docker Hub, etc.), with public
  or token-accessible pull permissions so RunPod can pull the image.
- `docker buildx` for multi-platform builds (`--platform linux/amd64` —
  RunPod nodes are amd64, which matters if you're building on Apple Silicon).

## 2. Build and push an image

Pick the image for your workload (see the top-level README's image table),
then follow that image's own `README.md` for build specifics — model/adapter
choice, GPU-family tags, etc. In general:

```bash
REGISTRY=ghcr.io/<you> make docker-tei        # or docker-bertopic / docker-nli
```

Tag with a semantic version (`:v0.1.0`) rather than a moving tag like
`:latest` — RunPod's own docs warn against moving tags for pod templates
(caching surprises, no rollback if a bad build gets pushed under the same
tag).

## 3. Create a pod

Copy the config template matching your image, edit the values you need
(image tag, GPU type, disk sizing), then create the pod:

```bash
cp scripts/runpod/config/pods.conf.tei.example scripts/runpod/config/pods.conf
$EDITOR scripts/runpod/config/pods.conf
scripts/runpod/create_pods.sh -n 1
```

`create_pods.sh` polls until the pod is actually ready (not just "the RunPod
proxy answered") and prints a ready-to-use `host:` (HTTP images) or
`ssh_host:`/`ssh_port:` (SSH images, like bertopic) block. It also writes
`scripts/runpod/hosts.generated.{csv,yaml}` — an inventory used by
`stop_pods.sh` and the monitoring scripts.

If you'd rather not have your raw `RUNPOD_API_KEY` end up in the pod-creation
request body, store it as a [RunPod
Secret](https://docs.runpod.io/pods/templates/secrets) and set
`POD_ENV_RUNPOD_API_KEY='{{ RUNPOD_SECRET_<name> }}'` in your `pods.conf` —
see `scripts/runpod/README.md` for details.

## 4. Smoke test

For an HTTP image (TEI, NLI):

```bash
HOST=<printed-host>
curl -s https://$HOST/health && echo
```

For the SSH-based bertopic image:

```bash
ssh -i ~/.ssh/id_ed25519 -p <printed-ssh_port> root@<printed-ssh_host> \
    "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader"
```

## 5. Point your project at it

This repo doesn't touch any project's own config — copy the printed
host/port info into wherever your project keeps its backend configuration
(an env var, a YAML file, whatever your pipeline uses).

## 6. Monitor (bertopic pod only — SSH-based)

```bash
scripts/runpod/pod_watch.sh            # live CPU/GPU polling + PNG plot
scripts/runpod/pod_log_tail.sh python  # tail the GPU script's own log
```

For HTTP-based images (e.g. running several `nli-runpod` or `tei-runpod`
pods), use the URL-driven companions instead:

```bash
scripts/runpod/http-pool/watch_gpu.sh -u https://<host1> -u https://<host2>
scripts/runpod/http-pool/keep_alive.sh -u https://<host1> --loop 240
```

## 7. Tear down

Every image self-stops via its idle watchdog after `IDLE_MIN` minutes of
inactivity (default 5). To act immediately:

```bash
scripts/runpod/stop_pods.sh          # stop (resumable later)
scripts/runpod/stop_pods.sh -d       # permanently delete (frees all billing)
```

## Gotchas

- **RunPod's API shape has changed before.** If `create_pods.sh` fails with
  a validation error on a field like `cloudType`, check the current request
  body schema at https://docs.runpod.io/api-reference/pods/POST/pods and
  adjust `pods.conf`/the script.
- **GPU availability varies by region and tier.** If pod creation hangs
  waiting for `publicIp`/`portMappings` (TCP pods) or never gets healthy
  (HTTP pods), check the RunPod console — it's often a scheduling issue, not
  a bug in the image.
- **Cold starts.** Images with a model baked in are ready within seconds of
  boot, but the image pull itself can take a few minutes on a cold node —
  `create_pods.sh`'s `HEALTH_TIMEOUT_SEC` defaults are generous for this.
