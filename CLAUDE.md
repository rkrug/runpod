# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Self-contained RunPod tooling: Docker images for GPU workloads (`docker/`) plus a
generic, image-agnostic pod-lifecycle layer (`scripts/runpod/`). It's meant to be
consumed by other project repos (e.g. as a git submodule) — see the "Design"
section of [README.md](README.md) and [PLAN.md](PLAN.md) for the extraction
rationale and what came from which source repo.

The core constraint driving most design decisions here: **nothing in this repo
may hardcode a value belonging to a consuming project** (bucket name, SSH host,
project name, config schema). Everything is env vars, CLI flags, or a
`pods.conf`-style file supplied by the caller. When adding to this repo, keep
that boundary — project-specific orchestration belongs in the *consuming*
project's repo, not here.

## Commands

### Build and push an image

```bash
REGISTRY=ghcr.io/<you> make docker-tei        # builds proximity + adhoc_query adapter variants
REGISTRY=ghcr.io/<you> make docker-bertopic
REGISTRY=ghcr.io/<you> make docker-nli
REGISTRY=ghcr.io/<you> make docker-all        # all three
```

`REGISTRY` is required (no default — the Makefile errors if unset, on purpose,
so a fork never pushes into someone else's namespace). `VERSION` (default
`v0.1.0`), `TEI_TAG` (default `89-1.5`, the CUDA-family tag for TEI), and
`IMAGE_SOURCE_URL` are overridable the same way. Each `docker-<image>` target
is `docker-<image>-build` + `docker-<image>-push`; use the `-build` target
alone to test locally without pushing.

Building a single image directly (bypassing the Makefile) always runs from the
**repo root**, not the image's own directory — every Dockerfile's `COPY`
paths are relative to repo root:

```bash
docker buildx build --platform linux/amd64 \
  --build-arg ADAPTER=proximity \
  -f docker/tei-runpod/Dockerfile .
```

### Pod lifecycle (local testing needs `RUNPOD_API_KEY` + a real RunPod account)

```bash
export RUNPOD_API_KEY=...
cp scripts/runpod/config/pods.conf.tei.example scripts/runpod/config/pods.conf
scripts/runpod/create_pods.sh -n 1                 # reads scripts/runpod/config/pods.conf by default
scripts/runpod/stop_pods.sh                        # or -d to permanently delete
```

`create_pods.sh -n <count>` is the only required flag; `-c <config-file>` and
`-o <output-csv>` override the defaults. Both scripts resolve their own paths
via `SCRIPT_DIR` (their own location on disk), not the caller's CWD — this is
what makes them submodule-safe, so preserve that pattern in any new script
here rather than assuming "run from repo root."

### Testing

```bash
test/smoke-test.sh                # shellcheck + every docker build + entrypoint smoke tests
test/smoke-test.sh --skip-docker  # shellcheck + pod-lifecycle dry-run validation only (no docker needed)
test/smoke-test.sh --skip-build   # re-run smoke tests against already-built runpod-smoketest/* images
```

No RunPod account or GPU is needed. This is the same coverage that was
originally run by hand while building this repo: `shellcheck` over every
`.sh` file, a build of each `docker/<image>/`, `create_pods.sh`/`stop_pods.sh`
argument/env validation plus every `scripts/runpod/config/*.example`
sourcing cleanly, `scripts/runpod/http-pool/*.sh` against a throwaway local
HTTP server (both the default and an overridden path/body/metric), and an
image-specific entrypoint check where one exists (`nli-runpod`'s full
`/health`+`/classify`+`/metrics` cycle on CPU; `bertopic-runpod`'s sshd +
heartbeat file + baked-in script via `docker exec`; `tei-runpod` is
build-only — see below). Run this after any change to a Dockerfile,
entrypoint, watchdog, or pod-lifecycle script.

**When adding a new `docker/<name>/` image**: the build loop in
`test/smoke-test.sh` auto-discovers `docker/*/` so a new image gets
build-only coverage for free. Add a `smoke_<name>` function + a case arm in
the per-image dispatch to also exercise its entrypoint (follow the
`smoke_nli`/`smoke_bertopic` pattern) — the script will remind you to if you
don't.

### Local smoke-testing an image without RunPod

- `nli-runpod` has a genuine CPU fallback (`-e NLI_DEVICE=-1`) — the only
  image of the three that can fully run+serve locally without a GPU:
  ```bash
  docker run --rm -p 8080:8080 -e NLI_DEVICE=-1 <nli-image>
  curl -s localhost:8080/health
  ```
- `tei-runpod` cannot run locally at all without an actual NVIDIA GPU — its
  TEI base tag (`89-1.5` etc.) is CUDA-only. A successful `docker build` is
  as much local verification as is possible; the multi-stage build's own
  `RUN test -f /merged/config.json` check already validates the SPECTER2
  merge step.
- `bertopic-runpod`'s entrypoint (sshd, heartbeat file, baked-in
  `run_bertopic_gpu.py`) can be checked via `docker exec` without a GPU, but
  the actual cuml/UMAP/HDBSCAN workload needs one.

`test/smoke-test.sh` automates all three of the above.

## Architecture

### Three independent, self-contained images under `docker/`

Each `docker/<image>/` directory holds everything needed to build that one
image: `Dockerfile`, `entrypoint.sh`, an idle-watchdog script, any
build-time-only assets (e.g. `tei-runpod/prepare_specter2_merged.py`,
`bertopic-runpod/run_bertopic_gpu.py` — baked in at `/opt/run_bertopic_gpu.py`
and invoked over SSH by the caller), `README.md`, and `CHANGES.md`. Adding a
new workload means adding a new `docker/<name>/` directory following this
same shape — it gets build verification for free from `test/smoke-test.sh`
(see "Testing" below), and everything else keeps working with no changes
required elsewhere.

Every idle watchdog self-stops via the **RunPod REST API**
(`POST https://rest.runpod.io/v1/pods/<id>/stop`), never `runpodctl` — an
earlier version of one of these images called `runpodctl stop pod` directly,
which fails silently under `set -euo pipefail` (`runpodctl` needs a config
file the pod doesn't have). If you're porting or writing a new watchdog, copy
the `stop_pod()` pattern from `docker/tei-runpod/tei_idle_watchdog.sh`, not
`runpodctl`.

Two exposure shapes exist and drive how each image's pod is reached:
- **HTTP** (`tei-runpod`, `nli-runpod`) — reached via RunPod's HTTP proxy,
  monitored/kept-alive via `scripts/runpod/http-pool/`.
- **SSH/TCP** (`bertopic-runpod`) — no HTTP endpoint at all; reached via SSH,
  monitored via `scripts/runpod/pod_watch.sh`/`pod_log_tail.sh`. Its idle
  signal is a heartbeat *file* (`/work/.heartbeat`), not a request counter.

### `scripts/runpod/` — the generic lifecycle layer

Only pod-management scripts live here (nothing used to *build* an image —
that lives inside the image's own `docker/<image>/` directory instead).
`create_pods.sh`/`stop_pods.sh` talk to the RunPod REST API directly (no
`runpodctl` needed on the calling machine) and branch on `POD_KIND`
(`http` vs `tcp`) read from the sourced `pods.conf` file, not on which image
is running — the scripts have no per-image special-casing.

`scripts/runpod/config/` holds one `pods.conf.<image>.example` template per
image plus a generic `pods.conf.example`. The working copy
(`scripts/runpod/config/pods.conf`, gitignored) and the generated pod
inventory (`scripts/runpod/hosts.generated.{csv,yaml}`, also gitignored) are
the only mutable state `create_pods.sh`/`stop_pods.sh` produce; everything
else here is static.

`scripts/runpod/http-pool/keep_alive.sh` and `watch_gpu.sh` work with *any*
HTTP-based image, not just one — the work-request path/body
(`keep_alive.sh --path`/`--body`) and the `/metrics` counter name
(`watch_gpu.sh --metric`) are parameters specifically because `tei-runpod`
and `nli-runpod` have different endpoint contracts and counter names
(`te_request_count` vs `nli_request_count`). Don't reintroduce an
image-specific default into these two scripts without a good reason —
that coupling was deliberately removed once already.

### What deliberately does NOT live in this repo

Project-specific orchestration code (e.g. an R/Python wrapper that SSHes into
the bertopic pod to drive a specific analysis pipeline, or that translates a
project's own config file into this repo's plain URL/host inputs) belongs in
the *consuming* project's repo. This repo's contract stops at "build the
image" and "create/monitor/stop the pod" — see README.md's "Using this repo
from another project" section for the intended boundary.
