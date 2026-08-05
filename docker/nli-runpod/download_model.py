"""Pre-download the zero-shot NLI model + tokenizer into the image at build time.

Baking the weights in (vs. a first-request download) means the pod is ready
seconds after boot and the exact model bytes are pinned to the image digest —
same rationale as the merged-SPECTER2 step in the TEI image.

The model id comes from the NLI_MODEL build arg (passed through as an env var);
defaults to the doc's recommended model.
"""

import os

from transformers import AutoModelForSequenceClassification, AutoTokenizer

MODEL_ID = os.environ.get(
    "NLI_MODEL", "MoritzLaurer/deberta-v3-large-zeroshot-v2.0"
)

if __name__ == "__main__":
    print(f"[download_model] fetching {MODEL_ID} into the HF cache")
    AutoTokenizer.from_pretrained(MODEL_ID)
    AutoModelForSequenceClassification.from_pretrained(MODEL_ID)
    print("[download_model] done")
