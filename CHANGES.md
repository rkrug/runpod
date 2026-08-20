# runpod — CHANGES

Repo-level changelog. See each `docker/<image>/CHANGES.md` for per-image
version history.

## Unreleased

- Added two TEI embedding images serving plain off-the-shelf HuggingFace
  models: `docker/tei-runpod-bge-large-en-v1.5/` (`BAAI/bge-large-en-v1.5`,
  1024-dim, 512-token) and `docker/tei-runpod-gte-large-en-v1.5/`
  (`Alibaba-NLP/gte-large-en-v1.5`, 1024-dim, 8192-token). Both bake the
  model in at build time; neither needs `docker/tei-runpod/`'s SPECTER2
  adapter-merge stage, so their build is just a download.
- New `MODEL_WEIGHTS` build arg on those two images, because TEI's CUDA
  backends read `model.safetensors` while its CPU backend reads
  `onnx/model.onnx`. Getting this wrong is otherwise silent — the pod just
  re-downloads the format it wants at boot — so the downloader fails the
  build if the requested format doesn't exist upstream, and the entrypoint
  warns at boot if neither is present.
- These two are the first images in this repo that `make test` can genuinely
  **run** rather than only build: the smoke test builds them against TEI's
  `cpu-1.6` base and checks `/health`, `/embed` dimensionality, `/metrics`,
  and that baked-in weights were actually used. (The GPU artifact itself
  remains unverified without a GPU — noted in each image's README.)
- Added `scripts/runpod/config/pods.conf.tei-bge-large-en-v1.5.example`,
  `pods.conf.tei-gte-large-en-v1.5.example`, and
  `pods.conf.nli-bge-m3.example`, each flagging exactly which values diverge
  from the base template it's derived from rather than silently restating it.
- `make docker-tei-bge-large` / `make docker-tei-gte-large` targets; both
  folded into `docker-all`.

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
- Added `test/smoke-test.sh` (and `make test`/`test-skip-docker`/
  `test-skip-build` Makefile targets), formalizing the manual verification
  run while building this repo (shellcheck, per-image builds + entrypoint
  smoke tests, http-pool functional checks, pod-lifecycle argument/config
  validation) into a single repeatable script with no RunPod account or GPU
  required. The `test*` Makefile targets are exempted from the `REGISTRY`
  requirement that the `docker-*` targets have.
- Added `CLAUDE.md`.
