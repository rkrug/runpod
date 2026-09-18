# nli-runpod — CHANGES

Image versions published as `ghcr.io/<you>/nli-runpod:vX.Y.Z`.

Semantic versioning, loosely:
- **MAJOR** — incompatible base image or breaking API change in `/classify`.
- **MINOR** — new feature (new tunable, new endpoint field).
- **PATCH** — bug fixes, dependency bumps.

## v0.4.0 — idle watchdog no longer races pool bring-up

Numbered v0.4.0, not v0.2.0: tags up to `v0.3.0` were already published
for this image without CHANGES entries (see the v0.3.0 note below), and a
fix published under a LOWER number than an existing tag is worse than no
fix — anyone resolving "the newest version" would get the old watchdog.

- **`STARTUP_GRACE_MIN` (new, default 60).** The idle watchdog now has two
  phases. Until the pod has served its first request the `IDLE_MIN` countdown
  does not run at all; the pod is instead bounded by `STARTUP_GRACE_MIN`. Once
  a request arrives the idle timer is armed permanently and the original
  `IDLE_MIN` behaviour applies.

  This fixes a real failure when bringing up a **pool**: the old single timer
  started the moment `/metrics` first answered, so the earliest pods were
  already counting down while the rest were still booting, while their
  hostnames were being collected, and while the client was being pointed at
  them. Only `POST /classify` moves the counter the watchdog watches — the
  `GET /health` polling in `scripts/runpod/create_pods.sh` does not — so with
  enough pods the first ones stopped themselves before the last were usable.
  Raising `IDLE_MIN` only widened the race; this removes it.

- **Fixed: a pod whose model never loaded ran forever.** While `/metrics` was
  unreachable the old loop advanced no counter at all, so nothing ever stopped
  a pod that failed to come up. That case is now covered by the startup grace.

- **Fixed: `IDLE_MIN=0` stopped the pod immediately** instead of disabling the
  idle timer as the README has always documented. `idle_seconds` starts at 0,
  so the unguarded `-ge $((IDLE_MIN * 60))` was true on the very first poll.

- Metrics becoming unreachable *after* the pod has served now holds the idle
  timer rather than advancing it — a restarting server is not evidence of
  idleness.

## v0.1.1 – v0.2.3 — pre-extraction tags, not from this repo

`ghcr.io/<you>/nli-runpod:v0.1.1` through `v0.2.3` (and `v0.2.3-base`) were
published from this image's ORIGIN project before it was extracted into this
repo (first commit 2026-08-05; those tags are dated 2026-06-30/07-01). They
predate everything documented below and are listed only so the version line
has no unexplained gap. Do not deploy them.

## v0.3.0 — published, not documented at the time

Reconstructed retroactively. `ghcr.io/<you>/nli-runpod:v0.3.0` exists and
predates v0.4.0, but no entry was written for it. For this image v0.3.0 is the `passes:1`
direct-classifier mode added in commit 52b263d.
Recorded here so the version line has no silent gap.

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
