# `test/` — local verification

`smoke-test.sh` is the consistent, repeatable version of the checks that were
originally run by hand while building this repo. Run it after any change to
a Dockerfile, entrypoint, watchdog, or `scripts/runpod/` script — no RunPod
account or GPU required.

```bash
test/smoke-test.sh                # everything
test/smoke-test.sh --skip-docker  # shellcheck + dry-run validation only (no docker needed)
test/smoke-test.sh --skip-build   # smoke-test against already-built runpod-smoketest/* images
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
   - `nli-runpod`: runs on CPU (`NLI_DEVICE=-1`), exercises `/health`,
     `/classify`, and `/metrics`.
   - `bertopic-runpod`: checked via `docker exec` — sshd listening, the
     heartbeat file present, `/opt/run_bertopic_gpu.py` baked in.
   - `tei-runpod`: build-only. Its TEI base tag is GPU-only, so nothing
     further can run on a machine without an NVIDIA GPU; a successful build
     already exercises the Dockerfile's own `RUN test -f
     /merged/config.json` check on the SPECTER2 merge stage.
   - Any other image without a dedicated check: build-only, with a reminder
     printed to add one.

## Adding a new `docker/<name>/` image

You don't have to do anything for it to get build coverage — the loop
discovers `docker/*/` on its own. To also exercise its entrypoint, add a
`smoke_<name>` function (following `smoke_nli`/`smoke_bertopic`) and a case
arm in the per-image dispatch inside `smoke-test.sh`.

## What this doesn't cover

An actual RunPod create → use → idle-stop cycle costs real GPU-hours and
needs a `RUNPOD_API_KEY` against a live account, so it isn't automated here.
See [`docs/RunPodSetup.md`](../docs/RunPodSetup.md) for that walkthrough.
