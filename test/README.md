# `test/` — local verification

`smoke-test.sh` is the consistent, repeatable version of the checks that were
originally run by hand while building this repo. Run it after any change to
a Dockerfile, entrypoint, watchdog, or `scripts/runpod/` script — no RunPod
account or GPU required.

```bash
make test                  # or: test/smoke-test.sh — everything
make test-skip-docker      # shellcheck + dry-run validation only (no docker needed)
make test-skip-build       # smoke-test against already-built runpod-smoketest/* images
```

## What it checks

1. **`shellcheck -S warning`** over every `.sh` file in the repo.
2. **`create_pods.sh`/`stop_pods.sh` argument and env validation** — missing
   `-n`, unset `RUNPOD_API_KEY`, a missing config/inventory file all fail the
   way they should — plus every `scripts/runpod/config/*.example` template
   sources cleanly and defines `IMAGE`/`GPU_TYPE_ID`.
3. **`scripts/runpod/http-pool/{keep_alive,watch_gpu}.sh`** against a
   throwaway local HTTP server, exercising both the default (nli-runpod)
   contract and an overridden (tei-runpod-style `--path`/`--body`/`--metric`)
   one.
4. **Every `docker/<image>/` builds.** The loop walks `docker/*/`, so a new
   image directory is picked up automatically.
5. **An image-specific entrypoint smoke test, where one exists:**
   - `nli-runpod`, `nli-runpod-bge-m3`: run on CPU (`NLI_DEVICE=-1`),
     exercising `/health`, `/classify`, and `/metrics`. Both share one
     `smoke_nli()` — their `server.py` logic is identical, only the baked-in
     model differs.
   - `tei-runpod-bge-large-en-v1.5`, `tei-runpod-gte-large-en-v1.5`: built
     against TEI's `cpu-1.6` base (`MODEL_WEIGHTS=onnx`) so they can actually
     run here, then checked for `/health`, `/embed` returning **exactly 1024
     dims**, `/metrics` exposing `te_request_count`, and — importantly — that
     the weights were served from the baked-in `/model` rather than
     re-downloaded from the Hub at boot.
   - `bertopic-runpod`: checked via `docker exec` — sshd listening, the
     heartbeat file present, `/opt/run_bertopic_gpu.py` baked in.
   - `tei-runpod`: build-only. Its SPECTER2 stack pins a GPU-only TEI tag, so
     nothing further can run on a machine without an NVIDIA GPU; a successful
     build already exercises the Dockerfile's own `RUN test -f
     /merged/config.json` check on the merge stage.
   - Any other image without a dedicated check: build-only, with a reminder
     printed to add one.

### A caveat worth knowing about the TEI embedding images

They are smoke-tested as their **CPU** variant, not the GPU artifact you
actually deploy — TEI's CUDA backends read `model.safetensors` while its CPU
backend reads `onnx/model.onnx`, so the test build overrides both `TEI_TAG`
and `MODEL_WEIGHTS`. What that verifies is still substantially more than a
build-only check (the model bakes in correctly, the entrypoint works, TEI
serves, dimensionality and pooling are right, no boot-time download), but the
CUDA path itself stays unverified until someone runs it on a real pod.

## Adding a new `docker/<name>/` image

You don't have to do anything for it to get build coverage — the loop
discovers `docker/*/` on its own. To also exercise its entrypoint, add a
`smoke_<name>` function (following `smoke_nli`/`smoke_bertopic`/
`smoke_tei_embedding`) and a case arm in the per-image dispatch inside
`smoke-test.sh`. If the image needs non-default build args to be runnable
locally (as the TEI embedding images do), add them to the `build_args` case
in the build loop too.

Where an existing smoke function already fits, reuse it rather than copying:
the dispatch deliberately routes several images to one function, and
`smoke_tei_embedding()` takes the expected embedding dimensionality as an
argument specifically so a new model can reuse it.

## What this doesn't cover

An actual RunPod create → use → idle-stop cycle costs real GPU-hours and
needs a `RUNPOD_API_KEY` against a live account, so it isn't automated here.
See [`docs/RunPodSetup.md`](../docs/RunPodSetup.md) for that walkthrough.
