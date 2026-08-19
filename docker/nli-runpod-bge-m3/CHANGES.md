# nli-runpod-bge-m3 — CHANGES

Image versions published as `ghcr.io/<you>/nli-runpod-bge-m3:vX.Y.Z`.

Semantic versioning, loosely:
- **MAJOR** — incompatible base image or breaking API change in `/classify`.
- **MINOR** — new feature (new tunable, new endpoint field).
- **PATCH** — bug fixes, dependency bumps.

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
