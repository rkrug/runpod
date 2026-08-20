# bertopic-runpod — CHANGES

Image versions published as `ghcr.io/<you>/bertopic-runpod:vX.Y.Z`.

Semantic versioning, loosely:
- **MAJOR** — incompatible Dockerfile base or breaking CLI change in the GPU script.
- **MINOR** — new feature in the image (new entrypoint behaviour, new bundled tool, etc.).
- **PATCH** — bug fixes, small tweaks, dependency bumps that don't change the surface.

## v0.2.0 — 2026-08-20 — unified `runpod` repo

First build published from this repo. Verified after push: the `runpodctl`
binary is gone from the image and the watchdog stops the pod via the REST
API. Only ~7 MB of new layers were uploaded — the RAPIDS base, apt and pip
layers are byte-identical to `v0.1.20` and were skipped by the registry.

The `v0.1.x` history below is this image's **pre-extraction** lineage,
carried over from the project repo it came from — those numbers describe
builds published before this repo existed. Of those, `v0.1.20` is the last
good one; `v0.1.0` predates the v0.1.17 watchdog fix and still carries the
broken `runpodctl` self-stop, so don't deploy it.

- Extracted from the newest version of this image (previously duplicated,
  with drift, across several downstream project repos) into this
  self-contained repo.
- Generalized: OCI image-source label is now build-arg driven
  (`IMAGE_SOURCE_URL`/`IMAGE_DESCRIPTION`) instead of pointing at one
  specific project's GitHub repo.
- `run_bertopic_gpu.py` moved into this image's own directory (was
  previously shared from a project-level `scripts/runpod/` folder); the
  `COPY` path in the Dockerfile updated to match.
- Dropped the unused `runpodctl` binary from the image — the idle
  watchdog has used the RunPod REST API exclusively since v0.1.17 and
  never called `runpodctl`.

## v0.1.20 — 2026-07-07

Dedup corpus works by id when reading embeddings.

- Works tagged with multiple partitions were embedded once per partition
  (dedup disabled at embed time), so a work's `id` repeats in the
  corpus parquets — up to 11× in one observed run (2,465 works duplicated,
  ~3,100 extra rows). BERTopic was consuming every copy: inflating local
  density for UMAP, biasing HDBSCAN, and double-counting the same abstract
  in c-TF-IDF.
- New `_dedup_by_id()` SQL suffix (`QUALIFY row_number() OVER (PARTITION BY
  id) = 1`) is now applied at every corpus read site: UMAP-fit embeddings
  read, c-TF-IDF per-topic text aggregation, and the fallback-variant stream.
  Duplicate rows carry identical embedding vectors, so which copy survives is
  irrelevant. Keypaper/reference reads are already unique — a no-op there.
- Topic assignments (topics.parquet) are therefore one row per unique work;
  any partition multiplicity re-enters only downstream when the caller maps
  a work's topic back onto each partition it belongs to.
- CACHE NOTE: dedup changes the data the model sees but not any cfg hash, so
  the object-storage `intermediate/` stage cache from a pre-dedup run would
  be reused and mask the fix. Purge the intermediate cache for the config
  (or run under a new config name) after deploying.

## v0.1.19 — 2026-07-07

Harden `stage_ctfidf` against degenerate clusterings.

- When HDBSCAN collapses to very few non-noise topics (a homogeneous corpus
  → 1–2 topics), the configured `vectorizer_min_df`/`vectorizer_max_df` become
  infeasible and sklearn raised `max_df corresponds to < documents than min_df`
  mid-run, killing the whole pod job after UMAP+HDBSCAN had already completed.
  Now the vectorizer step mirrors sklearn's own `max_df * n_docs < min_df`
  check up front, clamps to `min_df=1, max_df=1.0` with a warning when the
  configured pair is infeasible, and wraps the fit in a fallback retry.
- All-noise guard: if every work landed in topic -1 (0 topic-documents), exit
  with a clear message pointing at HDBSCAN retuning / supervised mode instead
  of an opaque vectorizer error.
- Behaviour on healthy runs (enough topics) is unchanged.

## v0.1.18 — 2026-07-07

Supervised UMAP — concept-anchored clustering.

- **Supervised UMAP** (`supervised_umap: true`). In `stage_umap`, each corpus
  work is labelled by its nearest concept — argmax cosine to the concept
  (keypaper) embeddings, computed on the pod from the RAW SPECTER2 vectors
  (same space as the scores) before PCA/centring. Works below
  `supervised_min_similarity` stay unlabelled (`y=-1`). cuml UMAP then fits
  with `target_metric` + `target_weight` (both config-driven), passing
  `y=` labels. New config keys `supervised_umap`, `target_metric`,
  `target_weight`, `supervised_min_similarity` are folded into `umap_hash`, so
  a supervised run caches to its own prefix and does not collide with the
  unsupervised fits. No external label file — the label source is the concept
  embeddings already provided via `reference_emb_dir`. Unsupervised configs
  are unaffected (`supervised_umap` defaults false).

## v0.1.17 — 2026-07-07

Working idle-watchdog via the RunPod REST API + httpfs-retry hardening.

- `bertopic_idle_watchdog.sh`: self-stop calls the RunPod REST API
  (`POST https://rest.runpod.io/v1/pods/<id>/stop`, `Authorization: Bearer
  $RUNPOD_API_KEY`) instead of `runpodctl stop pod`. `runpodctl` needs a
  `runpodctl config` file the pod doesn't have (it failed with "Runpod config
  file not found" / statuscode 400 and, under `set -euo pipefail`, killed the
  watchdog so the pod never stopped). The REST call needs only
  `RUNPOD_API_KEY` (supplied via a RunPod Secret, resolved at pod launch) and
  matches `scripts/runpod/stop_pods.sh`.
- `run_bertopic_gpu.py::_setup_duckdb_s3()`: raise `http_timeout` to 120000ms
  and `http_retries` to 8 (+ `http_retry_wait_ms`/`http_retry_backoff`) so a
  transient object-storage GET blip retries instead of killing a
  near-complete run.

## v0.1.14 — 2026-06-30

Add optional PCA + whitening before UMAP fit, plus corpus mean-centring
(kept for backward compat).

### PCA + whitening (new in v0.1.14)

Diagnosis: mean-centring alone was insufficient in a case where PCA on a
corpus sample showed PC1 explaining only 8% of variance, and 100 PCs
capturing ~86% — genuine multi-dimensional structure exists but is hidden
by a tight cosine cone. PCA + whitening decorrelates dimensions and
rescales them to unit variance, giving UMAP an isotropic input space.

`run_bertopic_gpu.py`:
- `"pca_n_components"`, `"pca_whiten"`, `"pca_sample_size"` added to
  `_UMAP_FIELDS` so enabling PCA produces a new `umap_hash` and fresh
  cache slot.
- New `_apply_preprocessing(X, mean_vec, pca_model)` helper used
  consistently across corpus fit, keypaper projection, and fallback
  chunks.
- `stage_umap`: when `pca_n_components` is set, fits `cuml.PCA`
  (with `whiten=True`) on a random sample of `pca_sample_size` rows,
  transforms the full corpus, then passes the reduced matrix to UMAP.
  PCA model saved as `pca_model.pkl` in the same cache prefix as the UMAP
  model; loaded on cache hit.
- `stage_project_keypapers` / `stage_project_fallback`: accept
  `pca_model=None` kwarg, apply `_apply_preprocessing` before
  `umap_model.transform`.
- `main()`: unpacks 4-tuple `(umap_model, umap_coords, mean_vec,
  pca_model)` from `stage_umap`, threads both through projection stages.
- When `pca_n_components` is absent/null, PCA is skipped and
  `center_embeddings` (mean-centring) still applies — no change to
  existing configs.

No Dockerfile changes; `cuml.decomposition.PCA` is already in the
RAPIDS base image.

### Mean-centring

Add optional corpus mean-centring before UMAP fit.

Diagnosis: in one dataset, HDBSCAN collapsed to 6–7 topics regardless of
tuning because all pairwise cosine similarities in the embedded corpus sat
in a narrow band (e.g. 0.66–0.98). With embeddings packed into a narrow
cone on the unit hypersphere, UMAP's k-NN graph is near-uniformly dense
and UMAP collapses the manifold to one blob regardless of HDBSCAN params.

Fix: subtract the corpus mean vector from every embedding before
passing to UMAP. This shifts the distribution from a cone to a ball
centred on the origin, restoring the local distance structure UMAP
needs.

`run_bertopic_gpu.py`:
- `"center_embeddings"` added to `_UMAP_FIELDS` so enabling it
  produces a new `umap_hash` and a fresh cache slot — no collision
  with existing collapsed runs.
- `stage_umap`: when `center_embeddings: true`, compute
  `mean_vec = X.mean(axis=0)`, subtract it from `X` before
  `cuml.UMAP.fit_transform`, and write `mean_vec.pkl` to the cache
  alongside the UMAP model. On cache hit, loads `mean_vec.pkl` if present.
  Returns `(umap_model, umap_coords, mean_vec)` — `mean_vec` is
  `None` when centering is off, preserving existing behaviour.
- `stage_project_keypapers` and `stage_project_fallback`: accept
  `mean_vec=None` kwarg and subtract it from each input matrix before
  `umap_model.transform()`. Fallback chunks each get the same shift.
- `main()`: unpacks the new three-tuple return from `stage_umap` and
  threads `mean_vec` into both projection stages.

No Dockerfile changes; pure Python script edit.

## v0.1.13, v0.1.12, v0.1.11, v0.1.10, v0.1.9 — folded into v0.1.14

Reliability and memory-pressure fixes discovered across the first full
production dispatches, all folded into the v0.1.14 image (never
individually built/pushed as standalone images):

- **v0.1.13** — cache the fallback variant projection separately from
  HDBSCAN/c-TF-IDF, so a keypaper-set swap doesn't re-pay the ~15-25 min
  fallback-projection cost. New `_FALLBACK_FIELDS` cache branch.
- **v0.1.12** — push the c-TF-IDF per-topic text aggregation into duckdb
  SQL (join + `group_concat`) instead of materialising the full merged
  DataFrame in pandas, cutting peak RAM in that stage from ~115 GB to
  ~35-40 GB.
- **v0.1.11** — new `_read_embeddings_only` reader skips the bulky text
  columns for UMAP fit and keypaper projection (they're not needed until
  c-TF-IDF), cutting the corpus DataFrame from ~50-70 GB to ~14 GB.
- **v0.1.10** — `stage_umap`: explicitly `del df_corpus; gc.collect()`
  before `fit_transform` to free memory ahead of cuml's k-NN scratch
  allocations. Necessary but not sufficient on its own (see v0.1.11).
- **v0.1.9** — (A) large-object uploads switched from a single
  `put_object` call to `upload_fileobj` with multipart `TransferConfig`
  (8 MB threshold, 64 MB chunks, 8-way concurrency) after large model
  pickles (1-3 GB) intermittently failed mid-upload with
  `ssl.SSLEOFError`. (B) fixed a heartbeat-keeper self-match bug in
  `entrypoint.sh`: the bash keeper's own `pgrep -f` matched its own
  subshell argv, so it kept the heartbeat alive forever even after the
  GPU script had died. Anchored the regex with `^python.*` to match only
  the actual workload process.

## v0.1.8 — 2026-06-12

Major refactor: object-storage-backed stage caching.

Three production failures pointed to the same root cause — BERTopic's
monolithic `fit_transform` holds the full corpus in memory through its
Representation step, OOM'ing on a 116 GB pod at multi-million-row scale.
This refactor replaces BERTopic entirely with direct cuml + sklearn
orchestration and adds stage caching backed by object storage (e.g. R2/S3).

- **`run_bertopic_gpu.py`**: rewritten as six explicit stages:
  1. cuml.UMAP fit on corpus primary variant only (keypapers decoupled)
  2. cuml.HDBSCAN fit on UMAP coords
  3. c-TF-IDF on per-topic CONCATENATED corpus docs
     (~500 topic-documents fed to sklearn.CountVectorizer instead of
      millions of individual docs — cuts peak Representation-step RAM
      substantially)
  4. Keypaper projection via umap_model.transform() +
     hdbscan.approximate_predict()
  5. Fallback variant projection (no-abstract corpus works), same
     mechanism, streamed via duckdb anti-join
  6. Final output composition (topic_info / topics / topic_words)

  Each fit-stage writes intermediate state to
  `s3://<bucket>/intermediate/config=<X>/umap_cfg=<hash>/hdbscan_cfg=<hash>/ctfidf_cfg=<hash>/`
  with cascade cfg-hash keying. Re-running with unchanged upstream
  params loads from cache; changing `hdbscan_*` reuses UMAP cache;
  changing `vectorizer_*` reuses UMAP+HDBSCAN; keypaper swap touches
  none of the cache.

- **Dockerfile**: added pip deps `boto3` (S3-compatible client),
  `cloudpickle` (cuml model serialisation — stdlib pickle chokes on
  cuml's C-extensions), and explicit `scikit-learn` (was pulled
  transitively by bertopic; pinned explicitly since v0.1.8 doesn't
  import bertopic at all).

- **bertopic**: still installed in the image for backwards-compat with
  anyone copying an older monolithic script onto a v0.1.8 pod; the
  v0.1.8 script doesn't import it.

Pod template env vars unchanged: `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`
(now also used for cache reads/writes, not only embedding reads),
`RUNPOD_API_KEY`, `PUBLIC_KEY`, `IDLE_MIN`.

## v0.1.7 — 2026-06-11

Robust idle-watchdog handling for long GIL-holding library calls.

A GPU dispatch ran cleanly through the object-storage read + matrix
extraction + GPU upload, then got killed by the idle watchdog ~14 min
into the cuml.UMAP.fit kernel. Root cause: cuml's Python wrapper holds
the GIL through the k-NN graph build phase (~10-15 min), starving the
in-Python heartbeat thread added in v0.1.4. Heartbeat went stale,
watchdog fired, pod stopped — but the GPU workload was healthy
throughout.

- **entrypoint.sh**: add an external bash heartbeat keeper that touches
  `/work/.heartbeat` every 30 s WHILE a `/opt/run_bertopic_gpu.py`
  process is alive. Lives outside Python, no GIL contention. The
  Python-side thread is kept as belt-and-braces for the read phase.
  When the GPU script exits, the external keeper stops touching the
  file and the watchdog can correctly stop the pod.

With this change `IDLE_MIN` can stay at sensible defaults (5-10 min) —
previously users had to bump it to 60-90 min to survive cuml fits,
which delayed legitimate idle-stop after a script crash.

## v0.1.6 — 2026-06-11

- **Dockerfile**: add `ENV PYTHONUNBUFFERED=1`. The GPU script's
  `print()` lines and library messages from cuml/BERTopic were getting
  stuck in the 4 KB SSH pipe buffer for minutes, making the orchestrator
  look stalled while real work was happening. With unbuffered
  stdout/stderr, every log line flushes immediately.

## v0.1.5 — 2026-06-11

Driver-compatibility fix prompted by a cuSPARSE init regression in
NVIDIA driver 550.x running CUDA 12.5.

- **Dockerfile**: drop base image from `rapidsai/base:24.10-cuda12.5-py3.11`
  to `rapidsai/base:24.10-cuda12.0-py3.11`. The 12.0 runtime works
  reliably with driver >= 525 — covers essentially every RunPod node;
  12.5 requires >= 555 which is uncommon. RAPIDS 24.10 ships tags for
  11.8 / 12.0 / 12.5 only (no 12.4). cuml/bertopic functionality is
  identical at 12.0.

## v0.1.4 — 2026-06-11

Survivability fixes:

- **`run_bertopic_gpu.py`**: spawn a daemon thread on script start that
  touches `/work/.heartbeat` every 30 seconds for the script's lifetime.
  Survives long blocking calls (object-storage reads, cuml.UMAP fit,
  HDBSCAN) where the main thread can't manually heartbeat. Daemon
  thread dies with the process, allowing the watchdog to cleanly
  idle-stop the pod after script exit.
- **Dockerfile**: add `ln -sf /opt/conda/bin/python /usr/local/bin/python`
  so `python` resolves in non-interactive sshd-spawned shells. RAPIDS
  base puts python under `/opt/conda/bin/` which isn't on the default
  SSH PATH; without the symlink, `ssh ... 'python ...'` returns exit
  code 127.

## v0.1.3 — 2026-06-09

First object-storage-backed embedding read: the pod reads embeddings
directly via duckdb httpfs instead of an upfront rsync upload.

- **`run_bertopic_gpu.py`**: accepts `s3://bucket/prefix/...` URIs for
  `--corpus-emb-dir` and `--reference-emb-dir`. duckdb httpfs is
  configured at startup from env vars (`R2_ACCESS_KEY_ID`,
  `R2_SECRET_ACCESS_KEY`) plus endpoint/bucket carried in the cfg yaml.
  Local-path inputs still work — the script switches on the `s3://`
  prefix at parse time.
- **Dockerfile**: add `rsync` to the apt install list; pre-install
  duckdb's `httpfs` extension at image build time.
- **Required env vars on the pod template** (as RunPod Secrets):
  `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, plus `PUBLIC_KEY`,
  `RUNPOD_API_KEY`, `IDLE_MIN` as before.

## v0.1.2 — 2026-06-09

- **`run_bertopic_gpu.py`**: streams the fallback variant via duckdb
  anti-join in 50K-row chunks. The primary variant is still
  materialised once for cuml.UMAP.fit (UMAP can't be streamed), but
  afterwards the fit-time DataFrame is freed before the fallback
  transform begins.
- **Dockerfile**: add `duckdb>=1.0,<2` to the pip install line.

## v0.1.1 — 2026-06-08

- **entrypoint.sh**: read `PUBLIC_KEY` env var and write it to
  `/root/.ssh/authorized_keys` at boot, so SSH access works without
  relying on RunPod's image-side key injection.
- **Dockerfile**: add `org.opencontainers.image.source`/`…description`
  LABELs so GHCR auto-links the package to its source repo.
- **entrypoint.sh**: persistent logs to `${LOG_DIR:=/work}` —
  `bertopic-current.log` rotated to `bertopic-previous.log` on every
  boot (keeps exactly one historical log; old previous is overwritten).
- Updated README: "Tagging strategy" section (don't use moving tags for
  templates), documented `PUBLIC_KEY` template env var, added
  "Persistent logs" section.

## v0.1.0 — 2026-06-08

Initial release.

- Base: `rapidsai/base:24.10-cuda12.5-py3.11`.
- BERTopic 0.17.x, pyarrow, pyyaml.
- `runpodctl` v1.14.4 for the idle-watchdog's self-stop call (later
  replaced by the REST API in v0.1.17, and dropped from the image
  entirely in the Unreleased entry at the top of this file).
- sshd for orchestrator transport (rsync + ssh-triggered runs).
- Heartbeat-based idle watchdog (`/work/.heartbeat`, default `IDLE_MIN=5`).
- `/opt/run_bertopic_gpu.py` baked in (cuml UMAP + cuml HDBSCAN +
  c-TF-IDF).
