# tei-runpod-gte-large-en-v1.5 — CHANGES

Image versions published as
`ghcr.io/<you>/tei-runpod-gte-large-en-v1.5:vX.Y.Z`.

Semantic versioning, loosely:
- **MAJOR** — incompatible TEI base, different model, or breaking
  pod-template contract.
- **MINOR** — new feature in the image (new tunable, new bundled tool).
- **PATCH** — bug fixes, dependency bumps, small entrypoint tweaks.

## v0.1.0 — new image

Serves `Alibaba-NLP/gte-large-en-v1.5` (1024-dim, **8192-token** cap, CLS
pooling, ~434M params) via TEI, with the model baked in at build time.

The 8192-token context is the reason this image exists separately from
`docker/tei-runpod-bge-large-en-v1.5/`: the two are otherwise near-identical
in shape (same TEI base, same 1024 dims, same CLS pooling, same entrypoint
and watchdog), but a 16× longer context changes both what the model is useful
for and how a pod must be sized for it.

Added as its own directory rather than a `MODEL_ID` override on
`docker/tei-runpod/`, for two reasons: that image's build has a SPECTER2
adapter-merge stage this model doesn't need (and an `adapters` +
pinned-`huggingface_hub` dependency chain that only exists to serve it), and
its Makefile target tags every build as `tei-specter2:$(VERSION)` — not
useful when both models need to be independently addressable and deployable.

Differences from `docker/tei-runpod/` beyond the model itself:

- **No merge stage.** Stage 1 is a plain `snapshot_download` of an
  off-the-shelf repo. `download_model.py` is model-agnostic and takes
  `--model-id`/`--weights`.
- **`MODEL_WEIGHTS` build arg.** TEI's CUDA backends read
  `model.safetensors` while its CPU backend reads `onnx/model.onnx`, so the
  weight format has to be chosen to match `TEI_TAG`. Defaults to
  `safetensors` (GPU); `test/smoke-test.sh` builds with `onnx` + `cpu-1.6`.
  The downloader pulls only `onnx/model.onnx`, deliberately not `onnx/*` —
  upstream also ships fp16/int8/q4/bnb4/uint8 variants TEI doesn't use.
- **Pooling is an env var** (`TEI_POOLING`, default `cls`) rather than
  hardcoded into the entrypoint's `text-embeddings-router` invocation.
- **Lower default batch/concurrency** (`32768`/`512`/`128` vs.
  `131072`/`2048`/`512`) — the SPECTER2 image's values were tuned for
  A100/H100-class cards; this image's suggested GPU is an L4, and 32768
  tokens is already only ~4 maximum-length inputs for this model.

No `trust_remote_code` is involved despite the model's `auto_map`: TEI has a
native Rust implementation for this architecture (`model_type: new`) and
lists the model among its supported ones.

Verified locally on CPU (built against `cpu-1.6`): boots from baked-in
weights with no Hub download, `/info` reports `max_input_length: 8192` and
`pooling: cls`, `/embed` returns 1024 dims, `/metrics` exposes the
`te_request_count` counter the idle watchdog depends on, and embeddings are
semantically sane (~0.78 cosine for a paraphrase pair vs. ~0.39 for
unrelated text). **Not yet built or run on a GPU pod** — the CUDA path and
all GPU sizing guidance in the README are unmeasured.
