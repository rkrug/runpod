# tei-runpod — CHANGES

Image versions published as
`ghcr.io/<you>/tei-specter2:<adapter>-vX.Y.Z`, one per SPECTER2 adapter
(`proximity` for document embedding, `adhoc_query` for query-time).

Semantic versioning, loosely:
- **MAJOR** — incompatible TEI base, model format change, or breaking
  pod-template contract.
- **MINOR** — new feature in the image (new tunable, new bundled tool,
  new watchdog signal).
- **PATCH** — bug fixes, dependency bumps, small entrypoint tweaks.

## v0.4.0 — idle watchdog no longer races pod bring-up

Numbered v0.4.0 rather than the next unused minor: `tei-specter2:<adapter>-v0.3.0` is already
published on GHCR, and a fix published under a LOWER number than an existing
tag is worse than no fix -- anyone resolving "the newest version" would get
the old watchdog.

- **`STARTUP_GRACE_MIN` (new, default 60).** The idle watchdog now has two
  phases. Until the pod has been used at all -- serving a request -- the
  `IDLE_MIN` countdown does not run; the pod is bounded by `STARTUP_GRACE_MIN`
  instead. First use arms the idle timer permanently, after which the original
  `IDLE_MIN` behaviour applies.

  This fixes a real failure when bringing up a **pool**: the old single timer
  started as soon as the pod was reachable, so the earliest pods were counting
  down while the rest were still booting, while their hostnames were being
  collected, and while a client was being pointed at them. With enough pods the
  first ones stopped themselves before the last were usable, and raising
  `IDLE_MIN` only widened the race rather than removing it.

- **Fixed: a pod that never became usable ran forever.** When /metrics never answers,
  the old loop advanced no counter at all, so nothing ever stopped a pod that
  failed to come up. Now covered by the startup grace.

- **Fixed: `IDLE_MIN=0` stopped the pod immediately** instead of disabling the
  idle timer. `idle_seconds` starts at 0, so the unguarded
  `-ge $((IDLE_MIN * 60))` was true on the very first poll.

- Metrics becoming unreachable *after* the pod has served now holds the idle
  timer rather than advancing it — a restarting server is not evidence of
  idleness.

## v0.2.0 — 2026-08-20 — unified `runpod` repo

First build published from this repo (`proximity-v0.2.0` and
`adhoc_query-v0.2.0`). Verified after push: the `runpodctl` binary is gone
from the image and the watchdog stops the pod via the REST API.

The `v0.1.x` history below is this image's **pre-extraction** lineage,
carried over from the project repo it came from — those numbers describe
builds published before this repo existed. Of those, `v0.1.3` is the last
good one; `v0.1.0`/`v0.1.1` predate the v0.1.2 watchdog fix and still carry
the broken `runpodctl` self-stop, so don't deploy them.

- Extracted from the newest version of this image (previously duplicated,
  with drift, across several downstream project repos) into this
  self-contained repo.
- Generalized: OCI image-source label is now build-arg driven
  (`IMAGE_SOURCE_URL`/`IMAGE_DESCRIPTION`) instead of pointing at one
  specific project's GitHub repo.
- `prepare_specter2_merged.py` moved into this image's own directory
  (was previously shared from a project-level `scripts/` folder); its
  local-cache fallback path env var is now `SPECTER2_MERGED_PATH` (was
  `OVC_SPECTER2_PATH`, an artifact of a specific R package's naming) and
  its default cache location no longer references any specific package.
- Dropped the unused `runpodctl` binary from the image — the idle
  watchdog has used the RunPod REST API exclusively since v0.1.2 and
  never called `runpodctl`.

## v0.1.3 — 2026-07-07

Tag bump only — resolve a tag collision between two independently-versioned
downstream copies of this image that had drifted. No functional change vs
v0.1.2: still the REST-API idle watchdog, which needs only `RUNPOD_API_KEY`.

## v0.1.2 — 2026-07-06

- **tei_idle_watchdog.sh**: self-stop now calls the RunPod REST API
  (`POST https://rest.runpod.io/v1/pods/<id>/stop` with
  `Authorization: Bearer $RUNPOD_API_KEY`) instead of `runpodctl stop pod`.
  The `runpodctl` path required a `runpodctl config` file the pod doesn't
  have and failed with "Runpod config file not found" / HTTP 400, so idle
  pods never actually stopped. The REST call needs only `RUNPOD_API_KEY`
  (already in the pod-template env) and matches `scripts/runpod/stop_pods.sh`.
  Watchdog-only patch.

## v0.1.1 — 2026-06-08

- **entrypoint.sh**: persistent logs to `${LOG_DIR:=/workspace}` —
  `tei-current.log` rotated to `tei-previous.log` on every boot. Lets
  you read TEI's last words after a crash via the volume (RunPod's web
  Logs panel resets on restart, but the file doesn't). New env var
  `LOG_DIR` overridable from the pod template.

## v0.1.0 — 2026-06-08

Initial release.

- Multi-stage Dockerfile:
  - Stage 1 (`python:3.11-slim`): merges the SPECTER2 adapter into the
    base encoder via `prepare_specter2_merged.py`. Pins
    `huggingface_hub<0.20` so adapters 0.2.x can import
    `url_to_filename`.
  - Stage 2 (`ghcr.io/huggingface/text-embeddings-inference:<TEI_TAG>`):
    copies the merged model in at `/model`. CUDA tag selected via
    `--build-arg TEI_TAG=…` (e.g. `89-1.5` for Ada/Hopper L40S).
- Idle watchdog (`tei_idle_watchdog.sh`) auto-stops the pod after
  `IDLE_MIN` minutes of no new TEI requests; defaults to 5 min, override
  per pod via env var.
- Entrypoint binds TEI on `0.0.0.0:8080` (HTTP) with sensible defaults
  (`max-batch-tokens 131072`, `max-concurrent-requests 2048`,
  `max-client-batch-size 512`, `pooling cls`, `--auto-truncate`); all
  overridable via env vars.
- TEI 1.5 dropped `--served-model-name`; we don't pass it anymore.
