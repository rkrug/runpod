# nli-runpod-bge-m3 — CHANGES

Image versions published as `ghcr.io/<you>/nli-runpod-bge-m3:vX.Y.Z`.

Semantic versioning, loosely:
- **MAJOR** — incompatible base image or breaking API change in `/classify`.
- **MINOR** — new feature (new tunable, new endpoint field).
- **PATCH** — bug fixes, dependency bumps.

## v0.4.0 — idle watchdog no longer races pool bring-up; `passes` parity restored

- **Restored `passes` / `hypothesis` support (drift fix).** Commit 52b263d added
  the `passes:1` direct-classifier mode to `docker/nli-runpod/server.py` only.
  This image kept the zero-shot 3-pass scheme alone and its `ClassifyRequest`
  declared neither field — and pydantic ignores unknown fields by default, so a
  client sending `passes: 1` had it **silently dropped**. Worse, such a client
  sends `hypothesis` and deliberately omits `hypothesis_template`, so the claim
  text was dropped too and every pair would have been scored against the default
  `"This example is {}."` — silently wrong, with no error anywhere. Harmless in
  practice only because every shipped config sends `passes: 3`.

  `server.py` is now re-derived from `nli-runpod/server.py` wholesale rather than
  hand-ported, and verified byte-identical to it after reversing the handful of
  intended per-image substitutions. `/health` consequently also gains `id2label`.


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

## v0.3.0 — published, not documented at the time

Reconstructed retroactively. `ghcr.io/<you>/nli-runpod-bge-m3:v0.3.0` exists and
predates v0.4.0, but no entry was written for it. Verified by inspection: its `/usr/local/bin/nli_idle_watchdog.sh` has no
`STARTUP_GRACE_MIN`, and its `/opt/app/server.py` has no `passes` support —
i.e. for THIS image v0.3.0 carried neither of the two features its version
number might suggest. See the drift note in this image's README.
Recorded here so the version line has no silent gap.

## v0.1.0 — new image, sibling of `nli-runpod`

Added alongside `docker/nli-runpod/` rather than reusing it with a
build-arg override (`nli-runpod`'s own Makefile target already supports
`NLI_MODEL=...` at build time, but tags the result under the same
`nli-runpod:$(VERSION)` name — not useful when both models need to be
addressable/deployable independently). Same `server.py`/`entrypoint.sh`/
`nli_idle_watchdog.sh` contract, copied rather than shared per this repo's
one-self-contained-directory-per-image convention; the only functional
difference is which model `NLI_MODEL` defaults to and the baked-in
`NLI_MAX_LENGTH`.

Bakes in `MoritzLaurer/bge-m3-zeroshot-v2.0-c` (multilingual,
`max_position_embeddings` ~8194) instead of `nli-runpod`'s
`MoritzLaurer/deberta-v3-large-zeroshot-v2.0` (English-capable but
architecturally capped at 512 tokens) — needed by a consuming project's
"claim (hypothesis) is always English, but the paper being checked
(premise) can be in any language" use case, where a longer-context
*English-only* alternative (`MoritzLaurer/ModernBERT-large-zeroshot-v2.0`,
also considered) would still fail on non-English premises.

Not yet built, pushed, or run against a real pod — GPU sizing/throughput
in this image's README is a starting-point guess (same GPU class as
`nli-runpod`'s proven pool), not a measurement, since this model is larger
and this image's intended sequences are much longer.
