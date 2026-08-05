# runpod — CHANGES

Repo-level changelog. See each `docker/<image>/CHANGES.md` for per-image
version history.

## v0.1.0 — initial unification

- Extracted the newest versions of `docker/tei-runpod/`,
  `docker/bertopic-runpod/`, and their shared `scripts/runpod/`
  pod-lifecycle layer from the most advanced of several source repos where
  this tooling had been developed and independently drifted.
- Added `docker/nli-runpod/`, ported from a separate source repo — the only
  place this workload previously existed — and fixed a live bug in its idle
  watchdog in the process (it called `runpodctl stop pod` directly, which
  fails under the pod's runtime environment; replaced with the same
  RunPod-REST-API self-stop pattern already used by the other two images).
- Generalized every image and script to remove hardcoded coupling to any
  one source repo: OCI image-source labels are now build-arg driven, the
  `Makefile`'s registry namespace has no default (must be set explicitly),
  and `pods.conf` templates had project-specific values (registry
  namespace, keyring entry names, SSH key paths) replaced with placeholders
  or commented-out examples.
- Reorganized `scripts/runpod/` so build-time image assets live inside each
  image's own `docker/<image>/` directory, and `scripts/runpod/` holds only
  pod-lifecycle management scripts. Moved `pods.conf.*` templates into
  `scripts/runpod/config/`.
- Decoupled `keep_alive.sh` and `watch_gpu.sh` from a specific project's
  `config.yaml` schema — they now take plain URLs via `-u`/`--url-file`
  instead of parsing a project's YAML config. Further generalized both from
  nli-runpod-only to any HTTP-based image (tei-runpod or nli-runpod): the
  work-request path/body (`keep_alive.sh`) and the `/metrics` counter name
  (`watch_gpu.sh`) are now flags rather than hardcoded to nli-runpod's
  `/classify` contract, and the pair moved from `scripts/runpod/nli/` to
  `scripts/runpod/http-pool/` to reflect that. `bertopic-runpod` doesn't fit
  this pair at all (SSH-only, no HTTP endpoint) — it already has its own
  analogous tools (`pod_watch.sh`/`pod_log_tail.sh`).
- Added `test/smoke-test.sh`, formalizing the manual verification run while
  building this repo (shellcheck, per-image builds + entrypoint smoke tests,
  http-pool functional checks, pod-lifecycle argument/config validation)
  into a single repeatable script with no RunPod account or GPU required.
- Added `CLAUDE.md`.
