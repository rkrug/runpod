"""Minimal zero-shot NLI inference server (multilingual, long-context variant).

Loads a single HuggingFace NLI sequence-classification model behind a tiny
FastAPI app and runs zero-shot classification *manually* (tokenize → batched
forward → softmax). The model is baked into the image at build time (see
``download_model.py`` + ``Dockerfile``), so there is no first-request download.

Identical contract to docker/nli-runpod/server.py (this file is a deliberate
copy, not a shared import, per docker/CLAUDE.md's one-self-contained-
directory-per-image convention) — the code itself is fully model-agnostic
(entailment index is derived from the model's own config.label2id, not
hardcoded), so the only real difference between the two images is which
model NLI_MODEL bakes in by default.

Why not the ``zero-shot-classification`` pipeline? On some transformers
versions the pipeline's ChunkPipeline path ignores ``batch_size`` and runs
every (premise, hypothesis) pair through the GPU one at a time — a fraction
of achievable throughput regardless of batch size. Doing the batching by
hand restores real GPU throughput (and per-batch dynamic padding keeps short
inputs cheap).

Endpoints
---------
GET  /health   -> {"status": "ok", "model": "...", "device": N, "dtype": "...",
                   "entailment_id": K}
GET  /metrics  -> Prometheus-style text; exposes ``nli_request_count`` so the
                  idle watchdog can detect inactivity (mirrors TEI).
POST /classify -> body:
    {
      "sequences": ["premise text", ...],
      "candidate_labels": ["supports", "refutes", "is not relevant to"],
      "hypothesis_template": "This example is {}.",
      "multi_label": false,
      "batch_size": 128
    }
  returns one {"labels": [...], "scores": [...]} object per input sequence,
  labels sorted by descending score (same contract as the HF pipeline).

Tuning via env vars (all optional):
  NLI_MODEL        model id (default: MoritzLaurer/bge-m3-zeroshot-v2.0-c)
  NLI_PORT         listen port (default: 8080)
  NLI_DEVICE       device index; -1 = CPU (default: 0 if CUDA available else -1)
  NLI_MAX_LENGTH   tokenizer truncation length (default: 2048 in this image's
                   Dockerfile -- the model's own max_position_embeddings is
                   ~8194, but this default is set to the value the consuming
                   project's nli.configs.bge_m3_zeroshot actually sends)
  NLI_DTYPE        torch dtype: float16, bfloat16, float32
                   (default: float16 on GPU, float32 on CPU). float16/bfloat16
                   use Tensor Cores with no meaningful accuracy loss.
"""

import os
from typing import List, Optional

from fastapi import FastAPI
from pydantic import BaseModel

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

MODEL_ID = os.environ.get(
    "NLI_MODEL", "MoritzLaurer/bge-m3-zeroshot-v2.0-c"
)
MAX_LENGTH = int(os.environ.get("NLI_MAX_LENGTH", "2048"))


def _resolve_device() -> int:
    env = os.environ.get("NLI_DEVICE")
    if env is not None and env != "":
        return int(env)
    return 0 if torch.cuda.is_available() else -1


def _resolve_dtype(device: int) -> torch.dtype:
    env = os.environ.get("NLI_DTYPE", "").lower()
    if env == "float16":
        return torch.float16
    if env in ("bfloat16", "bf16"):
        return torch.bfloat16
    if env == "float32":
        return torch.float32
    # Default: float16 on GPU for Tensor Core throughput; float32 on CPU.
    return torch.float16 if device >= 0 else torch.float32


DEVICE = _resolve_device()
DTYPE = _resolve_dtype(DEVICE)
TORCH_DEVICE = torch.device(f"cuda:{DEVICE}" if DEVICE >= 0 else "cpu")

_tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
_model = AutoModelForSequenceClassification.from_pretrained(MODEL_ID, dtype=DTYPE)
_model.to(TORCH_DEVICE)
_model.eval()


def _entailment_id() -> int:
    """Index of the 'entailment' logit in the model head (mirrors HF pipeline)."""
    label2id = getattr(_model.config, "label2id", None) or {}
    for label, idx in label2id.items():
        if str(label).lower().startswith("entail"):
            return int(idx)
    return -1


ENTAILMENT_ID = _entailment_id()
# Same convention the HF zero-shot pipeline uses to pick the "contradiction"
# logit for multi_label scoring: opposite end of the head from entailment.
CONTRADICTION_ID = -1 if ENTAILMENT_ID == 0 else 0

app = FastAPI(title="nli-runpod-bge-m3", version="0.1.0")

# Cumulative count of classified sequences, exposed at /metrics for the
# idle watchdog (a request that classifies N sequences increments by N).
_request_count = 0


class ClassifyRequest(BaseModel):
    sequences: List[str]
    candidate_labels: List[str]
    hypothesis_template: str = "This example is {}."
    multi_label: bool = False
    batch_size: int = 128
    # Per-request truncation length. Falls back to the NLI_MAX_LENGTH env
    # default when omitted, so the client can drive it from its own config.
    max_length: Optional[int] = None


class ClassifyResult(BaseModel):
    labels: List[str]
    scores: List[float]


@app.get("/health")
def health():
    return {
        "status": "ok",
        "model": MODEL_ID,
        "device": DEVICE,
        "dtype": str(DTYPE).replace("torch.", ""),
        "entailment_id": ENTAILMENT_ID,
        "max_length": MAX_LENGTH,
        "tokenizer_fast": bool(getattr(_tokenizer, "is_fast", False)),
    }


@app.get("/metrics")
def metrics():
    from fastapi.responses import PlainTextResponse

    body = (
        "# HELP nli_request_count Cumulative sequences classified.\n"
        "# TYPE nli_request_count counter\n"
        f"nli_request_count {_request_count}\n"
    )
    return PlainTextResponse(body)


@torch.no_grad()
def _entail_logits(text_pairs, batch_size: int, max_length: int) -> torch.Tensor:
    """Entailment logit for each (premise, hypothesis) pair, in input order.

    Tokenizes and runs the model in batches of ``batch_size`` with per-batch
    dynamic padding (short inputs don't pay for the longest one in the
    request). Returns a 1-D float32 tensor on CPU of length ``len(text_pairs)``.
    """
    premises = [p for p, _ in text_pairs]
    hypotheses = [h for _, h in text_pairs]
    out = []
    for start in range(0, len(text_pairs), batch_size):
        end = start + batch_size
        enc = _tokenizer(
            premises[start:end],
            hypotheses[start:end],
            truncation="longest_first",
            max_length=max_length,
            padding=True,
            return_tensors="pt",
        ).to(TORCH_DEVICE)
        logits = _model(**enc).logits  # [b, n_head_labels]
        out.append(logits[:, ENTAILMENT_ID].float().cpu())
    return torch.cat(out) if out else torch.empty(0)


@app.post("/classify", response_model=List[ClassifyResult])
def classify(req: ClassifyRequest):
    global _request_count

    if not req.sequences:
        return []

    labels = req.candidate_labels
    n_seq = len(req.sequences)
    n_lab = len(labels)
    # Per-request max_length overrides the NLI_MAX_LENGTH env default. Use an
    # explicit None check (not `or`) so a genuine request value is always
    # honoured; only a missing/None field falls back to the env default.
    max_length = req.max_length if req.max_length is not None else MAX_LENGTH
    # Log the effective value + its source so the truncation length actually
    # used is verifiable in the RunPod logs (the /health endpoint only reports
    # the env default, MAX_LENGTH).
    print(
        f"[classify] n_seq={n_seq} n_lab={n_lab} batch_size={req.batch_size} "
        f"max_length={max_length} (from {'request' if req.max_length is not None else 'env NLI_MAX_LENGTH'}; "
        f"env default={MAX_LENGTH})",
        flush=True,
    )
    hypotheses = [req.hypothesis_template.format(lbl) for lbl in labels]

    # All (premise, hypothesis) pairs, premise-major:
    #   pair index = seq_i * n_lab + lab_i
    pairs = [
        (seq, hyp)
        for seq in req.sequences
        for hyp in hypotheses
    ]

    if req.multi_label:
        # Per-label 2-way softmax over (contradiction, entailment) logits.
        with torch.no_grad():
            premises = [p for p, _ in pairs]
            hyps = [h for _, h in pairs]
            entail = []
            contra = []
            bs = max(1, req.batch_size)
            for start in range(0, len(pairs), bs):
                end = start + bs
                enc = _tokenizer(
                    premises[start:end],
                    hyps[start:end],
                    truncation="longest_first",
                    max_length=max_length,
                    padding=True,
                    return_tensors="pt",
                ).to(TORCH_DEVICE)
                logits = _model(**enc).logits.float()
                entail.append(logits[:, ENTAILMENT_ID].cpu())
                contra.append(logits[:, CONTRADICTION_ID].cpu())
            entail = torch.cat(entail).reshape(n_seq, n_lab)
            contra = torch.cat(contra).reshape(n_seq, n_lab)
        # entailment prob per (seq, label) from its own 2-logit softmax
        stacked = torch.stack([contra, entail], dim=-1)  # [n_seq, n_lab, 2]
        scores = torch.softmax(stacked, dim=-1)[..., 1]  # [n_seq, n_lab]
    else:
        # Single-label: softmax the entailment logits across candidate labels.
        entail = _entail_logits(
            pairs, max(1, req.batch_size), max_length
        ).reshape(n_seq, n_lab)
        scores = torch.softmax(entail, dim=-1)

    _request_count += n_seq

    results = []
    for i in range(n_seq):
        row = scores[i]
        order = torch.argsort(row, descending=True).tolist()
        results.append(
            ClassifyResult(
                labels=[labels[j] for j in order],
                scores=[float(row[j]) for j in order],
            )
        )
    return results
