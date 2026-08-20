#!/usr/bin/env python3
"""
Pre-download a plain HuggingFace embedding model into the image at build time.

Baking the weights in (vs. TEI downloading them on first boot) means the pod
serves seconds after boot and the exact model bytes are pinned to the image
digest — same rationale as the merged-SPECTER2 step in docker/tei-runpod/,
minus the adapter-merge stage, since this model needs no merging.

Which weight format gets baked matters, because TEI's two backends read
different files:
  * the CUDA/candle backends (image tags like 89-1.5) read `model.safetensors`
  * the CPU backend (image tags like cpu-1.6) reads `onnx/model.onnx`
so a CPU-tagged image built with only safetensors — or vice versa — will
download the missing format at boot, defeating the point of baking. Pick via
--weights / the MODEL_WEIGHTS build arg.

Usage:
    python download_model.py --model-id Alibaba-NLP/gte-large-en-v1.5 --weights safetensors

Environment overrides:
    MODEL_OUT_DIR   Output directory (default: /model).
"""

import argparse
import os
import sys
from pathlib import Path


# Files TEI needs regardless of backend. snapshot_download simply skips any
# pattern the repo doesn't have, so listing a superset here is harmless and
# keeps this script model-agnostic (BERT-style vocab.txt, sentencepiece
# spm models, and sentence-transformers metadata all appear in some repos
# and not others).
COMMON_PATTERNS = [
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "special_tokens_map.json",
    "vocab.txt",
    "spm.model",
    "sentencepiece.bpe.model",
    "modules.json",
    "config_sentence_transformers.json",
    "sentence_bert_config.json",
    "1_Pooling/*",
]

WEIGHT_PATTERNS = {
    # Exact filenames, not globs: `onnx/*` would also pull the quantized
    # variants (model_fp16/int8/q4/...), which TEI does not use and which
    # would roughly double the layer size for nothing.
    "safetensors": ["model.safetensors"],
    "onnx": ["onnx/model.onnx", "onnx/model.onnx_data"],
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model-id",
        required=True,
        help="HuggingFace model id, e.g. Alibaba-NLP/gte-large-en-v1.5",
    )
    parser.add_argument(
        "--weights",
        choices=("safetensors", "onnx", "both"),
        default="safetensors",
        help=(
            "Which weight format(s) to bake in. safetensors = CUDA/candle TEI "
            "tags; onnx = cpu-* TEI tags; both = one image usable on either "
            "(roughly doubles the size)."
        ),
    )
    parser.add_argument(
        "--out-dir",
        default=os.environ.get("MODEL_OUT_DIR", "/model"),
        help="Destination for the downloaded model (default: /model).",
    )
    args = parser.parse_args()

    try:
        from huggingface_hub import snapshot_download
    except ImportError as e:
        print(
            "Missing Python dependency. Install with:\n"
            "    pip install huggingface_hub\n"
            f"Original error: {e}",
            file=sys.stderr,
        )
        return 2

    if args.weights == "both":
        weight_patterns = WEIGHT_PATTERNS["safetensors"] + WEIGHT_PATTERNS["onnx"]
    else:
        weight_patterns = WEIGHT_PATTERNS[args.weights]

    allow_patterns = COMMON_PATTERNS + weight_patterns
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[download_model] model:   {args.model_id}")
    print(f"[download_model] weights: {args.weights}")
    print(f"[download_model] out:     {out_dir}")

    # huggingface_hub >= 0.23 writes real files (not blob-cache symlinks) into
    # local_dir by default, which is what we need — a symlinked cache lives in
    # this build stage only and would dangle once the final stage COPYs /model
    # out of it. The old local_dir_use_symlinks kwarg that used to control this
    # is deprecated, so rely on the default and pin the floor in the Dockerfile.
    snapshot_download(
        repo_id=args.model_id,
        local_dir=str(out_dir),
        allow_patterns=allow_patterns,
    )

    # Fail the build here rather than at pod boot if the weights the chosen
    # TEI backend needs didn't actually materialise (e.g. a repo that ships
    # no ONNX export, requested with --weights onnx).
    missing = [
        p for p in weight_patterns
        # model.onnx_data only exists for models whose ONNX export exceeds
        # protobuf's 2 GB limit — absent is normal, not an error.
        if not p.endswith("onnx_data") and not (out_dir / p).is_file()
    ]
    if missing:
        print(
            f"[download_model] ERROR: expected weight file(s) not found after "
            f"download: {', '.join(missing)}\n"
            f"Does {args.model_id} publish a '{args.weights}' export?",
            file=sys.stderr,
        )
        return 1

    if not (out_dir / "config.json").is_file():
        print("[download_model] ERROR: config.json missing", file=sys.stderr)
        return 1

    total = sum(f.stat().st_size for f in out_dir.rglob("*") if f.is_file())
    print(f"[download_model] done — {total / 1024 / 1024:.0f} MB in {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
