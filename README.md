# runpod

Unified, self-contained RunPod tooling: Docker images for GPU workloads
plus generic pod-lifecycle scripts (create, monitor, stop). Consolidated
from tooling that had drifted, duplicated, across several separate project
repos — see [PLAN.md](PLAN.md) for the extraction rationale and what came
from where.

## Design

- **Config-driven, zero project coupling.** Nothing in this repo hardcodes
  a bucket name, SSH host, project name, or config schema belonging to any
  consuming project. Every script takes its inputs via env vars, CLI flags,
  or a `pods.conf`-style file you supply.
- **Multiple images, one repo.** Each GPU workload gets its own directory
  under `docker/`, fully self-contained (Dockerfile + entrypoint + idle
  watchdog + docs). Add a new workload by adding a new `docker/<name>/`
  directory.
- **Generic pod-lifecycle layer.** `scripts/runpod/` creates, monitors, and
  tears down pods via the RunPod REST API, independent of which image is
  running on them.
- **Submodule-friendly.** Scripts resolve their own paths relative to their
  own location (not the caller's working directory), so this repo can be
  dropped into another repo (e.g. as a git submodule) without breaking.

## Images

| Image | Directory | Workload | Exposure |
|---|---|---|---|
| `tei-specter2` | [`docker/tei-runpod/`](docker/tei-runpod/) | SPECTER2 embedding server (HuggingFace TEI) | HTTP |
| `bertopic-runpod` | [`docker/bertopic-runpod/`](docker/bertopic-runpod/) | BERTopic-style GPU clustering (cuml UMAP + HDBSCAN) | SSH (TCP/22) |
| `nli-runpod` | [`docker/nli-runpod/`](docker/nli-runpod/) | Zero-shot NLI classification server | HTTP |

Each has its own `README.md` (build/deploy instructions) and `CHANGES.md`
(version history).

## Pod lifecycle

`scripts/runpod/` — see [`scripts/runpod/README.md`](scripts/runpod/README.md)
for full usage:

- `create_pods.sh` — create N pods from a `pods.conf`-style config, wait for
  readiness, print connection info.
- `stop_pods.sh` — stop or permanently delete pods.
- `pod_watch.sh` / `pod_log_tail.sh` — live CPU/GPU monitoring and log tailing
  for the SSH-based bertopic pod.
- `http-pool/keep_alive.sh` / `http-pool/watch_gpu.sh` — pool-monitoring
  companions for any HTTP-based pod (`tei-runpod`, `nli-runpod`; not
  `bertopic-runpod`, which is SSH-only), URL-driven and not tied to any
  project's config format.
- `config/` — `pods.conf.*.example` templates, one per image. Copy one to
  `config/pods.conf`, edit, and run `create_pods.sh`.

All of these talk to the RunPod REST API directly (`https://rest.runpod.io/v1`)
— no `runpodctl` install required on the calling machine, and none of the
images depend on `runpodctl` either (every idle watchdog self-stops via the
same REST API).

## Quick start

```bash
export RUNPOD_API_KEY=...

# 1. Build and push an image (see each docker/<image>/README.md for details)
REGISTRY=ghcr.io/<you> make docker-tei

# 2. Create a pod
cp scripts/runpod/config/pods.conf.tei.example scripts/runpod/config/pods.conf
$EDITOR scripts/runpod/config/pods.conf   # set IMAGE to the tag you just pushed
scripts/runpod/create_pods.sh -n 1

# 3. Use it (host/ssh info printed by create_pods.sh)
curl -s https://<printed-host>/health

# 4. Tear down when done (or let the idle watchdog do it)
scripts/runpod/stop_pods.sh
```

See [`docs/RunPodSetup.md`](docs/RunPodSetup.md) for a fuller walkthrough.

## Testing

```bash
make test                  # or: test/smoke-test.sh
make test-skip-docker      # shellcheck + dry-run validation only, no docker needed
make test-skip-build       # re-run smoke tests against already-built runpod-smoketest/* images
```

Runs `shellcheck`, builds every image under `docker/`, runs an entrypoint
smoke test for each where one exists, exercises `scripts/runpod/http-pool/`
against a throwaway local server, and validates `create_pods.sh`/
`stop_pods.sh` argument handling and every `pods.conf.*.example` template.
No RunPod account or GPU needed. See [`test/README.md`](test/README.md).

## Using this repo from another project

Nothing here assumes a specific caller. A consuming project should:

1. Pull this repo in (e.g. as a git submodule) at a path of its choosing.
2. Point its own build/deploy scripts at `<submodule>/docker/<image>/Dockerfile`.
3. Invoke `<submodule>/scripts/runpod/create_pods.sh` / `stop_pods.sh` for
   lifecycle management, with its own `pods.conf` (copied from one of the
   `.example` templates here).
4. Keep any project-specific orchestration (e.g. an R/Python wrapper that
   SSHes into the bertopic pod to run a specific analysis, or translates a
   project's own config file into this repo's plain URL/host inputs) in the
   *project's own* repo — this repo intentionally stops at "build the image"
   and "manage the pod."
