# Unified `runpod` repository

## Context

RunPod (GPU cloud) Docker images and pod-lifecycle scripts currently exist, duplicated with drift, across four separate repos:

- **NXS_TCA_Article** — newest `docker/tei-runpod/` (v0.1.3) and `docker/bertopic-runpod/` (v0.1.20), plus the most advanced `scripts/runpod/` pod-pool management layer (`create_pods.sh`, `stop_pods.sh`, `pod_watch.sh`, `pod_log_tail.sh`, `pods.conf.*` templates).
- **Reimagening_TFC** — a close fork, one step behind (bertopic v0.1.16, tei v0.1.2). Confirmed via direct `diff`: Dockerfiles/entrypoints are byte-identical to NXS's; only version-history and a couple of since-ported bugfixes differ.
- **TCAC 2.0** — has the two Docker images (byte-identical tei-runpod Dockerfile; bertopic-runpod Dockerfile differs by one `COPY` path only) but is **missing** `scripts/runpod/` entirely (no `create_pods.sh`/`stop_pods.sh`) — oldest/behind.
- **IPBES_BM_Fact_Checker** — the sole source of a third workload, `docker/nli-runpod/` (FastAPI NLI classifier), plus its own older `scripts/runpod/` (confirmed: its `create_pods.sh` lacks `POD_KIND`, the `NOT_READY` guard, and `EXTRA_ENV` that NXS's has). Its `nli_idle_watchdog.sh` has a **live bug**: it calls `runpodctl stop pod` directly (line 54), the exact broken pattern NXS's changelogs document as failing under `set -euo pipefail` with `"Runpod config file not found"` — meaning idle NLI pods on this pattern never actually self-stop.

This duplication is a maintenance burden — the same Dockerfiles/scripts drift independently across repos, bugs get fixed in one place and not others (as evidenced by the CHANGES.md files explicitly reconciling "sibling repo" drift). The goal is a single, self-contained `runpod` repo at `/Users/rkrug/GitHub/runpod` holding all three (extensible to more) Docker images and the generic pod-lifecycle tooling, config-driven so it has zero hardcoded references to any of the four source repos, and structured so it can later be pulled into each project repo (e.g. as a git submodule) without path assumptions breaking.

All work happens only in the new `runpod` directory — the four source repos are read-only reference material and must not be touched.

## Directory structure to create

```
runpod/
├── README.md                 # what this repo is, image table, submodule usage
├── CHANGES.md                # repo-level changelog
├── LICENSE
├── .gitignore                # pods.conf, hosts.generated.*, __pycache__/, output/
├── Makefile                  # docker-<image>-build/push/all; REGISTRY required (no default)
├── docker/
│   ├── tei-runpod/            {Dockerfile, entrypoint.sh, tei_idle_watchdog.sh,
│   │                           prepare_specter2_merged.py, .dockerignore, README.md, CHANGES.md}
│   ├── bertopic-runpod/       {Dockerfile, entrypoint.sh, bertopic_idle_watchdog.sh,
│   │                           run_bertopic_gpu.py, .dockerignore, README.md, CHANGES.md}
│   └── nli-runpod/            {Dockerfile, entrypoint.sh, nli_idle_watchdog.sh,
│                                server.py, download_model.py, .dockerignore, README.md, CHANGES.md}
├── scripts/
│   └── runpod/                 # ONLY pod-management scripts live under scripts/ —
│       ├── README.md           #   anything used to build a Docker image lives inside
│       ├── create_pods.sh      #   that image's own docker/<image>/ folder instead.
│       ├── stop_pods.sh
│       ├── pod_watch.sh
│       ├── pod_log_tail.sh
│       ├── plot_pod_watch.R
│       ├── config/             # pods.conf templates, kept separate from the scripts
│       │   ├── pods.conf.tei.example
│       │   ├── pods.conf.bertopic.example
│       │   ├── pods.conf.nli.example
│       │   └── pods.conf.example
│       └── nli/                {keep_alive.sh, watch_gpu.sh}   # re-scoped, decoupled
├── docs/
│   └── RunPodSetup.md          # fresh, generic setup walkthrough
└── PLAN.md                     # this planning document, kept for reference
```

`R/` orchestration code is deliberately **not** included (see rationale below). Local, non-RunPod dev helpers (`prepare_specter2.sh`, `start_tei_specter2.sh` — used to run TEI locally without a pod at all) are **not** brought in either: they're neither Docker-build inputs nor pod-management tooling, so they don't belong under `scripts/` per the rule above, and they're out of scope for this repo. See "What NOT to bring over."

## Per-image sourcing and generalization

### `docker/tei-runpod/` — base: `NXS_TCA_Article/docker/tei-runpod/`
Confirmed byte-identical across NXS/Reimagening/TCAC 2.0, so this is a safe, lossless base.
- `Dockerfile`: `LABEL org.opencontainers.image.source=https://github.com/rkrug/TCAC-2.0` → replace with an `ARG IMAGE_SOURCE_URL` / `ARG IMAGE_DESCRIPTION`, defaulted to this new repo's own URL, overridable per build.
- `Dockerfile`'s `COPY scripts/prepare_specter2_merged.py ...` → since `prepare_specter2_merged.py` moves into `docker/tei-runpod/`, update the `COPY` path and `.dockerignore` allow-list to match.
- `scripts/prepare_specter2_merged.py`'s `default_out_dir()` hardcodes an `openalexVectorComp`-branded cache path fallback (dead at Docker-build time since `OVC_SPECTER2_PATH=/merged` always overrides it, but leaks a foreign package name) — change the fallback default to something neutral like `~/.cache/runpod-specter2/<subdir>`.
- `entrypoint.sh` / `tei_idle_watchdog.sh`: no changes — already fully env-var driven, no hardcoded strings.
- `Dockerfile` also `ADD`s the `runpodctl` binary, but `tei_idle_watchdog.sh` self-stops via the RunPod REST API directly, never calling `runpodctl` — **drop the `ARG RUNPODCTL_VERSION` / `ADD .../runpodctl` / `chmod` lines entirely**, it's unused dead weight (same fix applied to all three images — see below).

### `docker/bertopic-runpod/` — base: `NXS_TCA_Article/docker/bertopic-runpod/`
Confirmed byte-identical to Reimagening's; TCAC 2.0 differs only by one `COPY` path (older layout).
- `Dockerfile:124-126` — `LABEL org.opencontainers.image.source=https://github.com/rkrug/TCAC-2.0` / description `"... Built for TCAC 2.0."` → same `ARG`-based fix as tei-runpod.
- `Dockerfile:102` — `COPY scripts/runpod/run_bertopic_gpu.py /opt/run_bertopic_gpu.py` → since the script moves to `docker/bertopic-runpod/run_bertopic_gpu.py`, update this path and `.dockerignore` accordingly.
- `run_bertopic_gpu.py` itself is already well-generalized (R2 bucket/endpoint read entirely from the run's YAML `cfg`, credentials from env vars, no literals found) — only its stray docstring ("droppable into openalexVectorComp/...") needs rewording.
- The Dockerfile `ADD`s the `runpodctl` binary, but `bertopic_idle_watchdog.sh` actually self-stops via the RunPod REST API (`curl POST .../stop`), not `runpodctl` — it's unused. **Drop the `ARG RUNPODCTL_VERSION` / `ADD .../runpodctl` / `chmod` lines from the Dockerfile.**

### `docker/nli-runpod/` — base: `IPBES_BM_Fact_Checker/docker/nli-runpod/`
Only source for this image; needs the most work, including one real bug fix:
- `Dockerfile` — `LABEL org.opencontainers.image.source=https://github.com/IPBES-Data/IPBES_BM_Fact_Checker` → same `ARG`-based fix.
- `Dockerfile` header comment claims to mirror a `new/docker/tei-runpod/` path that doesn't exist anywhere — drop/rewrite to reference this repo's own `docker/tei-runpod/`.
- **`nli_idle_watchdog.sh:54`** — `runpodctl stop pod "${RUNPOD_POD_ID}"` under `set -euo pipefail` is a live bug (idle pods never actually stop, silently). **Fix: port the REST-API `stop_pod()` function verbatim from `docker/tei-runpod/tei_idle_watchdog.sh` (lines ~38-51)** — `POST https://rest.runpod.io/v1/pods/<id>/stop` with `Authorization: Bearer $RUNPOD_API_KEY`, logging on failure rather than exiting. Once this fix lands, the image no longer needs `runpodctl` at all — **drop the `ARG RUNPODCTL_VERSION` / `ADD .../runpodctl` / `chmod` lines from this Dockerfile too, if present**, consistent with the same cleanup in tei-runpod and bertopic-runpod.
- `server.py`, `download_model.py`, `entrypoint.sh` — already clean (model id, port, device, dtype, max-length all env/build-arg driven).

### Cross-image: `Makefile`
Source's `REGISTRY ?= ghcr.io/rkrug` default is a personal-namespace leak. In the unified repo, make `REGISTRY` required with no default (`$(error REGISTRY must be set)` if unset) so nobody accidentally builds/pushes into `rkrug`'s namespace from a fork.

## `scripts/runpod/` pod-lifecycle layer

**Base: `NXS_TCA_Article/scripts/runpod/{create_pods.sh,stop_pods.sh,pod_watch.sh,pod_log_tail.sh,plot_pod_watch.R}`** — confirmed (by direct read and diff) to be the newest, most feature-complete versions; no merging needed from the other repos.

- `create_pods.sh` / `stop_pods.sh` are already fully generic: no project-specific strings, all identifiers come from the sourced config file or CLI flags, and `hosts.generated.csv/.yaml` are written relative to `SCRIPT_DIR` (the script's own directory) — already submodule-safe.
- `pod_watch.sh` / `pod_log_tail.sh` currently resolve `hosts.generated.yaml` and read logs relative to the **caller's CWD**, not `SCRIPT_DIR`. Fix: apply the same `SCRIPT_DIR`-relative resolution `create_pods.sh` already uses, so these still work correctly when this repo is consumed from a different location (e.g. a submodule).
- **`pods.conf` templates** — move into `scripts/runpod/config/` (kept separate from the scripts themselves) and rename/genericize all placeholder values (image tags, GPU type defaults are fine to keep as illustrative, but strip identity leaks):
  - `pods.conf.embedding` → `scripts/runpod/config/pods.conf.tei.example`
  - `pods.conf.bertopic` → `scripts/runpod/config/pods.conf.bertopic.example` — **critically**, its `EXTRA_ENV` array currently *executes* `cat ~/.ssh/id_ed25519.pub` and `Rscript -e 'cat(keyring::key_get("R2_ACCESS_KEY"))'` at config-source time (confirmed by reading the file directly) — a hardcoded SSH key path and a project-specific keyring entry name. This must become a **commented-out illustrative example** with `EXTRA_ENV=()` as the live default, not something that runs R/keyring commands out of the box.
  - `pods.conf.NLI` → `scripts/runpod/config/pods.conf.nli.example`
  - `pods.conf.example` → `scripts/runpod/config/pods.conf.example`, genericized (drop the `rkrug` image reference).
  - `create_pods.sh`'s default `CONFIG_FILE` path and its usage/help text need updating to point at `config/pods.conf` (the user's gitignored working copy, also under `config/`) instead of `${SCRIPT_DIR}/pods.conf`.
- **`keep_alive.sh` / `watch_gpu.sh`** (from IPBES) — these are legitimate companion tools for the `nli-runpod` image (not pure discardable leftovers), but currently parse a *calling project's* `input/config.yaml` schema directly (`nli[["configs"]][[active]][...]` via an embedded `Rscript` call) — backwards coupling for a repo that's supposed to be config-driven from *its own* generic inputs. Fix: re-scope to `scripts/runpod/nli/`, and change them to take a plain URL (or list of URLs) via a `-u`/flag or a simple text file, removing the R/YAML-schema dependency entirely.

## Where R-orchestration code lives: **stays in each project repo**

`R/run_bertopic_runpod.R` and `R/embed_works.R::build_tei_backend()` should **not** move into this repo. Reasons, from reading the actual code:
1. `run_bertopic_runpod.R`'s own header states its intended future home is a separate R package (`openalexVectorComp`), not this shell/Docker repo.
2. It depends on sibling helpers (`read_topics_marker()`, `.topics_cfg_hash()`, etc.) defined in each project's own `R/run_bertopic_local.R` — it isn't actually standalone today.
3. `build_tei_backend()` is a thin adapter into the `openalexVectorComp` R package's `backend_config()` — pulling it here would make a shell/Docker repo depend on an unrelated R package.
4. The interface boundary is already clean: `create_pods.sh` (this repo) prints/writes `hosts.generated.yaml` (host/port/ssh info); each project's R code consumes that purely as plain config values (`cfg$host`, `cfg$ssh_host`, etc.). Nothing on either side needs to know about the other's internal structure — exactly the config-driven boundary requested.

Each project repo's R wrapper stays as a thin, pipeline-specific caller that (a) invokes this repo's `create_pods.sh`/`stop_pods.sh` for lifecycle, and (b) SSHes in to run the workload script that's baked into the relevant image (contract documented in each image's README).

## What NOT to bring over

- `scripts/prepare_specter2.sh` and `scripts/start_tei_specter2.sh` — local dev-only helpers for running TEI without a pod at all; not Docker-build inputs and not pod-management tooling, so they don't fit `scripts/runpod/`'s narrowed scope. Left in the source repos.
- `scripts/runpod/sync_embeddings_to_r2.sh` — hardcodes a specific bucket/prefix. Bring over only as a non-executable `.example` template with `LOCAL_ROOT`/`REMOTE_ROOT` as required env vars, no defaults.
- Any committed `hosts.generated.csv`/`hosts.generated.yaml` — ephemeral, contain real past pod IDs/hosts. Do not copy; add both filenames to `.gitignore`.
- The filled-in `pods.conf` file itself — only the `.example` templates are committed anywhere upstream; replicate that.
- Any project's `input/config.yaml` content, or the NLI-tooling's coupling to it (see above).
- `TD_RunPodSetup.md` verbatim — it documents the superseded volume-mount TEI workflow and is full of `openalexVectorComp`/`config.yaml` specifics. Write a fresh `docs/RunPodSetup.md` instead, using it only as background reading.
- Stray build artifacts (`__pycache__/`, `.pyc` files).

## Implementation steps

1. `mkdir -p` the directory tree above under `/Users/rkrug/GitHub/runpod`.
2. Copy the base files listed per image/script from their source repos (read-only reads only), applying the generalization edits above during/after copy — do not edit anything in the source repos.
3. Write `README.md`, `docs/RunPodSetup.md`, `.gitignore`, `Makefile`, and per-image `README.md`/`CHANGES.md` (seed each image's `CHANGES.md` with its current version history from the source repo, then add an entry for "extracted into unified `runpod` repo").
4. Copy this plan document itself into the new repo as `PLAN.md` (at repo root), so the rationale behind the unification is preserved for future reference.
5. `git init`, add everything, and create an initial commit.

## Verification

1. **Docker build smoke tests** for all three images (`docker buildx build ... -f docker/<image>/Dockerfile .` from repo root) — immediately surfaces any broken `COPY` path from the file relocations.
2. **Local entrypoint smoke tests** for `tei-runpod` and `nli-runpod` (`docker run -p 8080:8080 ...` + `curl localhost:8080/health`) — no GPU or RunPod account needed; both entrypoints already skip the idle watchdog when `RUNPOD_POD_ID` is unset.
3. **bertopic-runpod entrypoint check** via `docker exec` (confirm sshd listening, `/work/.heartbeat` exists) — GPU-dependent `cuml` calls aren't exercised, but the entrypoint/watchdog plumbing is.
4. **`shellcheck`** across all `.sh` files touched by the generalization edits.
5. **Argument/env validation dry-runs** of `create_pods.sh`/`stop_pods.sh` (missing `-n`, unset `RUNPOD_API_KEY`, bad config path) to confirm the genericized `pods.conf.*.example` templates still `source` cleanly.
6. **One real pod create/stop cycle**, gated on explicit user go-ahead (costs real GPU-hours) — specifically re-validates the ported REST-API stop call in the fixed `nli_idle_watchdog.sh`.
