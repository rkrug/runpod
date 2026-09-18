"""Minimal zero-shot NLI inference server (multilingual, long-context variant).

Loads a single HuggingFace NLI sequence-classification model behind a tiny
FastAPI app and runs zero-shot classification *manually* (tokenize → batched
forward → softmax). The model is baked into the image at build time (see
``download_model.py`` + ``Dockerfile``), so there is no first-request download.

A deliberate COPY of docker/nli-runpod/server.py, not a shared import, per
docker/CLAUDE.md's one-self-contained-directory-per-image convention. The
logic is fully model-agnostic (the entailment index is derived from the
model's own config.label2id, not hardcoded), so the ONLY intended differences
are this docstring, the NLI_MODEL / NLI_MAX_LENGTH defaults and the FastAPI
title. Keep it that way by re-deriving this file FROM that one and re-applying
those few substitutions -- do not hand-port individual features. Commit
52b263d did the latter and added the passes:1 direct-classifier mode to
nli-runpod only; because ClassifyRequest did not declare `passes` or
`hypothesis`, and pydantic ignores unknown fields by default, this image
silently DROPPED both for weeks -- a passes:1 client would have been scored
with 3-pass zero-shot against the default "This example is {}." template
rather than its own hypothesis, with no error anywhere.

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
      "batch_size": 128,
      "passes": 3
    }
  returns one {"labels": [...], "scores": [...]} object per input sequence,
  labels sorted by descending score (same contract as the HF pipeline).

  "passes" (default 3) selects the scoring mechanism, independent of which
  model is loaded:
    - passes: 3 (zero-shot) -- one forward pass per candidate label, each
      with its own reformulated hypothesis (hypothesis_template.format(label)),
      keeping only that pass's entailment logit; the resulting per-label
      entailment logits are cross-normalized (softmax) into the returned
      scores. This is the standard zero-shot-classification-via-NLI
      technique and works with any entailment-capable model regardless of
      how many raw classes its own head has.
    - passes: 1 (direct classifier, e.g. one fine-tuned on this task) -- one
      forward pass on (sequence, "hypothesis") as given verbatim (no
      per-label reformulation: "hypothesis_template" is unused, and a
      literal "hypothesis" string is required instead), reading the model's
      own native N-way softmax directly. Its output classes are matched to
      "candidate_labels" BY NAME (via the model's own config.id2label,
      case/whitespace-normalized), not by raw index position, and the
      request fails loudly if any candidate_labels entry has no matching
      class -- see _direct_label_order() below.
  Either way the response shape and label keys are identical, so a caller
  only needs to pick the right request fields for its own "passes" value;
  everything downstream of the response is scoring-mechanism-agnostic.

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

from fastapi import FastAPI, HTTPException
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


def _norm_label(label: str) -> str:
    return str(label).strip().upper().replace(" ", "_").replace("-", "_")


def _direct_label_order(candidate_labels: List[str]) -> List[int]:
    """Map candidate_labels onto this model's own native class indices, for
    passes == 1 (direct classifier) requests.

    Matches BY NAME (normalised: upper-cased, spaces/hyphens -> underscores),
    not by raw index position -- a fine-tuned model's own label2id ordering
    is an implementation detail of how it happened to be trained, not
    something callers should have to track. Raises ValueError (surfaced as
    a 400) listing exactly which label(s) failed to match, rather than
    silently mis-mapping classes.
    """
    id2label = getattr(_model.config, "id2label", None) or {}
    native = {_norm_label(v): int(k) for k, v in id2label.items()}
    order = []
    unmatched = []
    for label in candidate_labels:
        key = _norm_label(label)
        if key not in native:
            unmatched.append(label)
        else:
            order.append(native[key])
    if unmatched:
        raise ValueError(
            f"passes=1 candidate_labels {unmatched!r} have no matching class "
            f"in this model's id2label {id2label!r}"
        )
    return order

app = FastAPI(title="nli-runpod-bge-m3", version="0.1.0")

# Cumulative count of classified sequences, exposed at /metrics for the
# idle watchdog (a request that classifies N sequences increments by N).
_request_count = 0


class ClassifyRequest(BaseModel):
    sequences: List[str]
    candidate_labels: List[str]
    hypothesis_template: str = "This example is {}."
    # Required (and used verbatim, no .format() applied) instead of
    # hypothesis_template when passes == 1. Ignored otherwise.
    hypothesis: Optional[str] = None
    multi_label: bool = False
    batch_size: int = 128
    # 3 = zero-shot (per-label reformulation + cross-normalized entailment,
    # the only scheme this server used before "passes" existed). 1 = a
    # directly fine-tuned classifier (one forward pass, native head
    # softmax). See the module docstring's POST /classify section.
    passes: int = 3
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
        # This model's own native output classes -- lets a caller verify a
        # passes: 1 (direct classifier) config's candidate_labels will
        # actually match before sending real traffic.
        "id2label": getattr(_model.config, "id2label", None),
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
        f"env default={MAX_LENGTH}) passes={req.passes}",
        flush=True,
    )

    if req.passes == 1:
        # Direct classifier (e.g. a model fine-tuned on this exact task): one
        # forward pass per sequence on (sequence, req.hypothesis) taken
        # verbatim -- no per-label reformulation, no ENTAILMENT_ID logic.
        # Native head softmax, columns reordered to candidate_labels by name.
        if not req.hypothesis:
            raise HTTPException(
                status_code=400, detail="passes=1 requires a non-empty `hypothesis`"
            )
        try:
            label_idx = _direct_label_order(labels)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
        with torch.no_grad():
            logits_out = []
            bs = max(1, req.batch_size)
            hyps = [req.hypothesis] * n_seq
            for start in range(0, n_seq, bs):
                end = start + bs
                enc = _tokenizer(
                    req.sequences[start:end],
                    hyps[start:end],
                    truncation="longest_first",
                    max_length=max_length,
                    padding=True,
                    return_tensors="pt",
                ).to(TORCH_DEVICE)
                logits_out.append(_model(**enc).logits.float().cpu())
            logits = (
                torch.cat(logits_out) if logits_out else torch.empty(0, len(label_idx))
            )
        scores = torch.softmax(logits, dim=-1)[:, label_idx]  # [n_seq, n_lab]
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
