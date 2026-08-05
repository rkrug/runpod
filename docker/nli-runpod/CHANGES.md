# nli-runpod — CHANGES

Image versions published as `ghcr.io/<you>/nli-runpod:vX.Y.Z`.

Semantic versioning, loosely:
- **MAJOR** — incompatible base image or breaking API change in `/classify`.
- **MINOR** — new feature (new tunable, new endpoint field).
- **PATCH** — bug fixes, dependency bumps.

## v0.1.0 — unified `runpod` repo

Extracted from its origin project repo into this self-contained repo, with
the following fixes applied during the port:

- **Fixed a live bug**: `nli_idle_watchdog.sh` previously called
  `runpodctl stop pod "${RUNPOD_POD_ID}"` directly. Under `set -euo
  pipefail`, that call fails with "Runpod config file not found" (`runpodctl`
  needs a config file the pod doesn't have), silently killing the watchdog
  before it could stop an idle pod. Replaced with the same RunPod REST-API
  `stop_pod()` pattern (`POST https://rest.runpod.io/v1/pods/<id>/stop`)
  already used by `docker/tei-runpod/tei_idle_watchdog.sh` and
  `docker/bertopic-runpod/bertopic_idle_watchdog.sh`.
- Dropped the now-unused `runpodctl` binary from the Dockerfile — no
  watchdog in this image calls it anymore.
- Generalized: OCI image-source label is now build-arg driven
  (`IMAGE_SOURCE_URL`/`IMAGE_DESCRIPTION`) instead of pointing at one
  specific project's GitHub repo.
- Dropped a stale Dockerfile comment claiming to mirror a `new/docker/tei-runpod/`
  path that didn't exist anywhere on disk; conventions now reference this
  repo's own `docker/tei-runpod/`.
- `server.py`/README's project-specific framing (a particular fact-checking
  project's claim-verification workflow) generalized to describe the
  `/classify` contract on its own terms — the server itself was already
  fully generic (model, port, device, dtype, max-length all env/build-arg
  driven).
