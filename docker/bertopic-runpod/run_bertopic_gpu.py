#!/usr/bin/env python3
"""
BERTopic clustering — GPU full-corpus mode (cuml), with R2 stage caching.

This replaces BERTopic.fit_transform's monolithic pipeline with direct
orchestration of cuml.UMAP + cuml.HDBSCAN + sklearn-based c-TF-IDF.
Two motivations:

  1. BERTopic's Representation step OOM'd at 4.6M rows on a 116 GB pod
     by holding multiple internal copies of the document set. Direct
     orchestration on per-topic concatenated documents (sklearn
     CountVectorizer on ~500 strings, not 4.6M) cuts peak RAM by ~3x.
  2. Each fitting stage (UMAP, HDBSCAN, c-TF-IDF) writes intermediate
     state to R2 keyed by a cascade cfg-hash, so re-running with
     unchanged upstream params loads from cache instead of recomputing.

Pipeline stages:
  1. UMAP fit on corpus primary variant only (keypapers decoupled).
  2. HDBSCAN fit on UMAP coords.
  3. c-TF-IDF on per-topic concatenated corpus docs.
  4. Project keypapers into the fitted UMAP + HDBSCAN.
  5. Project fallback variant (no-abstract corpus works).
  6. Compose final topic_info / topics / topic_words outputs.

R2 cache layout:
  s3://<bucket>/intermediate/
    config=<embedding_config>/
      umap_cfg=<umap_hash>/
        umap_model.pkl              # cuml.UMAP fitted model
        umap_coords.parquet         # id + V1..V_n
        meta.json
        hdbscan_cfg=<hdbscan_hash>/
          hdbscan_model.pkl
          topics.parquet            # id, topic_id, probability
          meta.json
          ctfidf_cfg=<ctfidf_hash>/
            topic_info.parquet      # topic_id, label, top_words
            topic_words.parquet     # topic_id, word, weight, rank
            meta.json

Cascade semantics: changing `hdbscan_min_cluster_size` invalidates the
hdbscan_cfg + ctfidf_cfg subtrees but reuses umap_cfg. Changing
`vectorizer_*` invalidates only ctfidf_cfg. Keypaper-swap workflow
touches none of the cache.

R2 credentials come from env (R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY).
Endpoint + bucket from the cfg yaml's r2: block.

Baked into docker/bertopic-runpod/Dockerfile at /opt/run_bertopic_gpu.py;
invoked over SSH by the orchestrating project's own wrapper script.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import io
import json
import os
import sys
import time
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd
import yaml


HEARTBEAT_PATH = Path("/work/.heartbeat")


def _heartbeat():
    try:
        HEARTBEAT_PATH.parent.mkdir(parents=True, exist_ok=True)
        HEARTBEAT_PATH.touch()
    except OSError:
        pass


def _start_heartbeat_thread(interval_s: int = 30):
    """Background thread keeping /work/.heartbeat fresh during long-running
    blocking library calls. Belt-and-braces only — the entrypoint also runs
    an external bash heartbeat that doesn't depend on the GIL."""
    import threading
    def _loop():
        while True:
            _heartbeat()
            time.sleep(interval_s)
    t = threading.Thread(target=_loop, daemon=True)
    t.start()
    return t


# ---------------------------------------------------------------------------
# Schema helpers
# ---------------------------------------------------------------------------

def _embedding_columns(table_columns):
    ev = [c for c in table_columns if c.startswith("V") and c[1:].isdigit()]
    return sorted(ev, key=lambda c: int(c[1:]))


def _matrix_from_df(df: pd.DataFrame) -> np.ndarray:
    cols = _embedding_columns(df.columns)
    return df[cols].to_numpy(dtype=np.float32)


def _leaf_dir(out_root: Path, config_name: str, run_name: str,
              primary: str) -> Path:
    p = out_root / f"config={config_name}" / f"bertopic={run_name}" / f"variant={primary}"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _glob(emb_root: str, variant: str) -> str:
    root = emb_root.rstrip("/")
    return f"{root}/variant={variant}/**/*.parquet"


# ---------------------------------------------------------------------------
# duckdb httpfs setup (R2)
# ---------------------------------------------------------------------------

def _setup_duckdb_s3(con: duckdb.DuckDBPyConnection, r2_cfg: dict) -> None:
    endpoint = r2_cfg.get("endpoint")
    if not endpoint:
        return
    key_id = os.environ.get("R2_ACCESS_KEY_ID")
    secret = os.environ.get("R2_SECRET_ACCESS_KEY")
    if not (key_id and secret):
        raise SystemExit(
            "R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY env vars must be set on the pod."
        )
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute(f"SET s3_region='{r2_cfg.get('region', 'auto')}'")
    con.execute(f"SET s3_endpoint='{endpoint}'")
    con.execute(f"SET s3_access_key_id='{key_id}'")
    con.execute(f"SET s3_secret_access_key='{secret}'")
    con.execute("SET s3_url_style='path'")
    con.execute("SET s3_use_ssl=true")
    # Defaults (http_timeout=30s, http_retries=3) are too thin for the
    # multi-GB corpus parquet reads in this script — a single slow/dropped
    # R2 response surfaces as a hard IOException instead of retrying. Seen
    # in practice: a transient GET timeout on variant=title/part-0.parquet
    # during stage_project_fallback killed an otherwise-complete run.
    con.execute("SET http_timeout=120000")       # ms; was 30000
    con.execute("SET http_retries=8")             # was 3
    con.execute("SET http_retry_wait_ms=2000")
    con.execute("SET http_retry_backoff=2")


def _dedup_by_id(cols_all=None, id_col: str = "id") -> str:
    """SQL suffix that keeps exactly one row per work id.

    Works tagged with multiple chapters were embedded once per chapter
    partition (dedup was disabled at embed time), so `id` repeats in the corpus
    parquets. Keeping one row per unique work stops the topic model (UMAP
    density, HDBSCAN, c-TF-IDF) from being biased by that multiplicity. The
    duplicate rows carry identical embedding vectors (same text -> same vector),
    so which copy survives is irrelevant. Returns '' when there is no id column
    (nothing to dedup, e.g. a schema without id). Uses QUALIFY rather than
    SELECT DISTINCT because `SELECT *` reads also carry per-copy metadata
    (created_at, batch) that differs between chapter copies."""
    if cols_all is not None and "id" not in cols_all:
        return ""
    return f" QUALIFY row_number() OVER (PARTITION BY {id_col}) = 1"


def _read_embeddings_only(emb_root: str, variant: str, r2_cfg: dict) -> pd.DataFrame:
    """Read id + embedding columns only — no text. Used for UMAP fit and
    keypaper projection stages where the title/abstract text is unneeded.

    Skipping text shrinks the DataFrame from ~50-70 GB to ~14 GB at 4.6M
    rows — the difference between OOM and comfortable on pods with
    ~80-100 GB host RAM."""
    con = duckdb.connect()
    try:
        _setup_duckdb_s3(con, r2_cfg)
        pattern = _glob(emb_root, variant)
        schema = con.execute(
            f"DESCRIBE SELECT * FROM read_parquet('{pattern}', hive_partitioning = false) LIMIT 0"
        ).fetchdf()
        cols_all = schema["column_name"].tolist()
        emb_cols = _embedding_columns(cols_all)
        if not emb_cols:
            raise RuntimeError(f"No embedding columns (V<int>) found at {pattern}")
        keep = (["id"] if "id" in cols_all else []) + emb_cols
        select_list = ", ".join(f'"{c}"' for c in keep)
        df = con.execute(
            f"SELECT {select_list} FROM read_parquet('{pattern}', hive_partitioning = false)"
            f"{_dedup_by_id(cols_all)}"
        ).fetchdf()
        if df.empty:
            raise FileNotFoundError(f"No rows at {pattern}")
        return df
    finally:
        con.close()


def _read_full_variant_with_text(emb_root: str, variant: str, r2_cfg: dict) -> pd.DataFrame:
    """Read embeddings + text columns (title_clean, abstract_clean) via duckdb.
    Kept for backwards-compat / future use; current callers use the
    text-less or text-only variants to bound memory."""
    con = duckdb.connect()
    try:
        _setup_duckdb_s3(con, r2_cfg)
        pattern = _glob(emb_root, variant)
        schema = con.execute(
            f"DESCRIBE SELECT * FROM read_parquet('{pattern}', hive_partitioning = false) LIMIT 0"
        ).fetchdf()
        cols_all = schema["column_name"].tolist()
        emb_cols = _embedding_columns(cols_all)
        if not emb_cols:
            raise RuntimeError(f"No embedding columns (V<int>) found at {pattern}")
        keep = [c for c in ("id", "title_clean", "abstract_clean") if c in cols_all] + emb_cols
        select_list = ", ".join(f'"{c}"' for c in keep)
        df = con.execute(
            f"SELECT {select_list} FROM read_parquet('{pattern}', hive_partitioning = false)"
            f"{_dedup_by_id(cols_all)}"
        ).fetchdf()
        if df.empty:
            raise FileNotFoundError(f"No rows at {pattern}")
        return df
    finally:
        con.close()


def _read_text_only(emb_root: str, variant: str, r2_cfg: dict) -> pd.DataFrame:
    """Read id + text columns only (no embeddings). Used in c-TF-IDF stage
    when umap_coords cache hits but we still need corpus text."""
    con = duckdb.connect()
    try:
        _setup_duckdb_s3(con, r2_cfg)
        pattern = _glob(emb_root, variant)
        df = con.execute(
            f"SELECT id, title_clean, abstract_clean "
            f"FROM read_parquet('{pattern}', hive_partitioning = false)"
            f"{_dedup_by_id()}"
        ).fetchdf()
        return df
    finally:
        con.close()


def _stream_variant_minus_primary(emb_root: str,
                                  fallback_variant: str,
                                  primary_variant: str,
                                  r2_cfg: dict,
                                  chunk_rows: int = 50_000):
    con = duckdb.connect()
    try:
        _setup_duckdb_s3(con, r2_cfg)
        res = con.execute(f"""
            SELECT *
            FROM read_parquet('{_glob(emb_root, fallback_variant)}', hive_partitioning = false) AS f
            WHERE f.id NOT IN (
              SELECT id FROM read_parquet('{_glob(emb_root, primary_variant)}', hive_partitioning = false)
            )
            {_dedup_by_id(id_col="f.id")}
        """)
        while True:
            chunk = res.fetch_df_chunk()
            if chunk is None or len(chunk) == 0:
                break
            yield chunk
    finally:
        con.close()


# ---------------------------------------------------------------------------
# R2 IO helpers (boto3-based for non-parquet artefacts)
# ---------------------------------------------------------------------------

def _r2_client(r2_cfg: dict):
    import boto3
    return boto3.client(
        "s3",
        endpoint_url=f"https://{r2_cfg['endpoint']}",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name=r2_cfg.get("region", "auto"),
    )


def _r2_exists(client, bucket: str, key: str) -> bool:
    try:
        client.head_object(Bucket=bucket, Key=key)
        return True
    except client.exceptions.ClientError:
        return False
    except Exception:
        return False


def _r2_put_bytes(client, bucket: str, key: str, data: bytes) -> None:
    # upload_fileobj auto-chunks via multipart (default threshold 8 MB,
    # part size 8 MB). The cuml.UMAP pickle is 1-3 GB, which a single
    # client.put_object cannot reliably push to R2 — Cloudflare's TLS
    # endpoint drops the connection mid-upload (ssl.SSLEOFError) for
    # large monolithic PUTs. Multipart is also retried per-part on
    # transient failures, no extra retry logic needed in our code.
    import boto3.s3.transfer
    config = boto3.s3.transfer.TransferConfig(
        multipart_threshold=8 * 1024 * 1024,     # 8 MB
        multipart_chunksize=64 * 1024 * 1024,    # 64 MB chunks
        max_concurrency=8,
        use_threads=True,
    )
    client.upload_fileobj(io.BytesIO(data), bucket, key, Config=config)


def _r2_get_bytes(client, bucket: str, key: str) -> bytes:
    obj = client.get_object(Bucket=bucket, Key=key)
    return obj["Body"].read()


def _pickle_to_r2(client, bucket: str, key: str, obj) -> None:
    """cloudpickle handles cuml/numpy/sklearn objects more robustly than
    stdlib pickle."""
    import cloudpickle
    _r2_put_bytes(client, bucket, key, cloudpickle.dumps(obj))


def _unpickle_from_r2(client, bucket: str, key: str):
    import cloudpickle
    return cloudpickle.loads(_r2_get_bytes(client, bucket, key))


def _parquet_to_r2(client, bucket: str, key: str, df: pd.DataFrame) -> None:
    buf = io.BytesIO()
    df.to_parquet(buf, index=False, compression="snappy")
    _r2_put_bytes(client, bucket, key, buf.getvalue())


def _parquet_from_r2(client, bucket: str, key: str) -> pd.DataFrame:
    return pd.read_parquet(io.BytesIO(_r2_get_bytes(client, bucket, key)))


def _meta_to_r2(client, bucket: str, key: str, cfg: dict, stage: str) -> None:
    meta = {
        "stage": stage,
        "cfg": cfg,
        "fit_timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "image_sha": os.environ.get("IMAGE_SHA", "unknown"),
        "python_version": sys.version,
    }
    _r2_put_bytes(client, bucket, key, json.dumps(meta, indent=2).encode())


# ---------------------------------------------------------------------------
# Cfg-hash helpers
# ---------------------------------------------------------------------------
#
# Hashes are blake2b(canonical-json) truncated to 16 hex chars. The
# canonical-json form (sorted keys, no whitespace) is stable across Python
# versions and platforms; xxhash would be marginally faster but blake2b is
# stdlib.
#
# Cascade hashing: hdbscan_cfg includes all umap_cfg fields, ctfidf_cfg
# includes all hdbscan_cfg fields, etc. So changes to upstream params
# invalidate downstream hashes naturally without explicit propagation logic.

_UMAP_FIELDS = (
    "primary_variant", "umap_n_components", "umap_n_neighbors",
    "umap_min_dist", "umap_metric", "random_seed", "center_embeddings",
    "pca_n_components", "pca_whiten", "pca_sample_size",
    # Supervised UMAP (v0.1.18): labels derived on-pod from nearest concept.
    "supervised_umap", "target_metric", "target_weight",
    "supervised_min_similarity",
)

_HDBSCAN_FIELDS = _UMAP_FIELDS + (
    "hdbscan_min_cluster_size", "hdbscan_min_samples",
)

_CTFIDF_FIELDS = _HDBSCAN_FIELDS + (
    "vectorizer_min_df", "vectorizer_max_df", "vectorizer_max_features",
    "vectorizer_ngram", "top_n_words",
)

# Fallback projection depends on the fitted UMAP + HDBSCAN models PLUS the
# fallback variant name. It does NOT depend on the keypaper set or the
# c-TF-IDF params. Putting it on the hdbscan_cfg branch (with an extra
# `fallback_variant` field) keeps the cache valid across keypaper swaps
# and c-TF-IDF re-tunes.
_FALLBACK_FIELDS = _HDBSCAN_FIELDS + (
    "fallback_variant",
)


def _cfg_subset(cl: dict, fields: tuple) -> dict:
    return {k: cl.get(k) for k in fields}


def _cfg_hash(d: dict) -> str:
    canonical = json.dumps(d, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.blake2b(canonical.encode(), digest_size=8).hexdigest()


# ---------------------------------------------------------------------------
# Preprocessing helper — applied consistently to corpus, keypapers, fallback
# ---------------------------------------------------------------------------

def _apply_preprocessing(X: np.ndarray, mean_vec, pca_model) -> np.ndarray:
    """Apply PCA (+ optional whitening, baked into the model) or plain
    mean-centring to an embedding matrix X. Returns float32 array."""
    if pca_model is not None:
        return np.asarray(pca_model.transform(X), dtype=np.float32)
    if mean_vec is not None:
        return (X - mean_vec).astype(np.float32)
    return X


def _nearest_concept_labels(X: np.ndarray, C: np.ndarray,
                            min_sim: float = 0.0,
                            chunk: int = 200_000) -> np.ndarray:
    """Label each corpus row by its nearest concept via cosine similarity.

    X: (n, d) RAW corpus embeddings; C: (K, d) RAW concept (keypaper)
    embeddings. Returns an int32 array of length n: the index (0..K-1) of the
    most-similar concept, or -1 when the best cosine is below `min_sim`
    (cuml/umap-learn treat -1 in a categorical target as unlabeled, so those
    rows are placed by the embedding geometry alone). Computed in row chunks so
    the (n x K) similarity block never materialises in full for a large corpus.
    """
    Cn = C / np.clip(np.linalg.norm(C, axis=1, keepdims=True), 1e-12, None)
    labels = np.full(X.shape[0], -1, dtype=np.int32)
    for s in range(0, X.shape[0], chunk):
        xb  = X[s:s + chunk]
        xbn = xb / np.clip(np.linalg.norm(xb, axis=1, keepdims=True), 1e-12, None)
        sims = xbn @ Cn.T
        best = sims.argmax(axis=1)
        best_sim = sims[np.arange(sims.shape[0]), best]
        lab = best.astype(np.int32)
        lab[best_sim < min_sim] = -1
        labels[s:s + chunk] = lab
    return labels


# ---------------------------------------------------------------------------
# Stage 1: UMAP fit (corpus only, keypapers decoupled)
# ---------------------------------------------------------------------------

def stage_umap(corpus_root: str, r2_cfg: dict, config_name: str,
               cl: dict, umap_hash: str, refer_root: str = None):
    bucket = r2_cfg["bucket"]
    prefix = f"intermediate/config={config_name}/umap_cfg={umap_hash}"
    keys = {
        "model":     f"{prefix}/umap_model.pkl",
        "coords":    f"{prefix}/umap_coords.parquet",
        "meta":      f"{prefix}/meta.json",
        "mean_vec":  f"{prefix}/mean_vec.pkl",   # written when center_embeddings=true (v3)
        "pca_model": f"{prefix}/pca_model.pkl",  # written when pca_n_components set (v4+)
    }
    client  = _r2_client(r2_cfg)
    center  = bool(cl.get("center_embeddings", False))
    pca_n   = int(cl.get("pca_n_components") or 0)

    if _r2_exists(client, bucket, keys["model"]) and _r2_exists(client, bucket, keys["coords"]):
        print(f"[cache hit] UMAP: s3://{bucket}/{prefix}")
        umap_model  = _unpickle_from_r2(client, bucket, keys["model"])
        umap_coords = _parquet_from_r2(client, bucket, keys["coords"])
        pca_model = (
            _unpickle_from_r2(client, bucket, keys["pca_model"])
            if pca_n and _r2_exists(client, bucket, keys["pca_model"])
            else None
        )
        mean_vec = (
            _unpickle_from_r2(client, bucket, keys["mean_vec"])
            if (not pca_n) and center and _r2_exists(client, bucket, keys["mean_vec"])
            else None
        )
        return umap_model, umap_coords, mean_vec, pca_model

    print(f"[cache miss] UMAP: s3://{bucket}/{prefix}")
    print("[step] reading corpus primary variant (embeddings only, no text) for UMAP fit")
    df_corpus = _read_embeddings_only(corpus_root, cl["primary_variant"], r2_cfg)
    n_corpus  = len(df_corpus)
    print(f"        loaded {n_corpus:,} corpus rows")
    _heartbeat()

    ids = df_corpus["id"].astype(str).values
    X   = _matrix_from_df(df_corpus)
    del df_corpus
    gc.collect()
    _heartbeat()

    # ---- Supervised labels (optional): nearest concept per corpus work ---
    # Derived from cosine similarity to the concept (keypaper) embeddings on
    # the RAW SPECTER2 vectors — same space as score_keypapers — computed
    # before any PCA/centring so the labels reflect true concept proximity,
    # not the transformed geometry. Passed as y= to cuml UMAP below.
    y_labels = None
    if bool(cl.get("supervised_umap", False)):
        if not refer_root:
            raise SystemExit("supervised_umap=true but no reference (concept) "
                             "embeddings dir was provided to stage_umap.")
        min_sim = float(cl.get("supervised_min_similarity", 0.0))
        print(f"[step] supervised UMAP: labelling {len(ids):,} works by nearest "
              f"concept (variant={cl['primary_variant']}, min_similarity={min_sim})")
        df_concept = _read_embeddings_only(refer_root, cl["primary_variant"], r2_cfg)
        C = _matrix_from_df(df_concept)
        n_concepts = len(df_concept)
        del df_concept
        gc.collect()
        y_labels = _nearest_concept_labels(X, C, min_sim=min_sim)
        n_labelled = int((y_labels >= 0).sum())
        n_classes  = int(len(np.unique(y_labels[y_labels >= 0])))
        print(f"        {n_concepts} concepts; labelled {n_labelled:,}/{len(ids):,} "
              f"works ({n_labelled / max(len(ids),1):.1%}) into {n_classes} classes; "
              f"{len(ids) - n_labelled:,} left unlabelled (-1)")
        _heartbeat()

    # ---- Preprocessing: PCA (v4+) or mean-centring (v3) ------------------
    pca_model = None
    mean_vec  = None

    if pca_n:
        # PCA + optional whitening. Fit on a random sample to bound GPU
        # memory; transform is a linear projection so the sample
        # approximation is accurate for the full corpus.
        # cuml.PCA(whiten=True) applies both centring and whitening, so
        # all n_components contribute equally to UMAP distances —
        # preventing the first PC from dominating the k-NN graph.
        whiten   = bool(cl.get("pca_whiten", True))
        samp_n   = int(cl.get("pca_sample_size") or 500_000)
        seed     = int(cl.get("random_seed", 13))
        samp_n   = min(samp_n, n_corpus)

        print(f"[step] cuml.PCA fit on {samp_n:,} sample rows "
              f"(n_components={pca_n}, whiten={whiten})")
        from cuml.decomposition import PCA as cumlPCA
        pca_model = cumlPCA(
            n_components=pca_n,
            whiten=whiten,
            random_state=seed,
        )
        rng        = np.random.default_rng(seed)
        sample_idx = rng.choice(n_corpus, samp_n, replace=False)
        t0 = time.time()
        pca_model.fit(X[sample_idx])
        print(f"[time] PCA fit: {time.time() - t0:.1f}s  "
              f"variance explained: "
              f"{float(np.asarray(pca_model.explained_variance_ratio_).sum()):.1%}")
        _heartbeat()

        print(f"[step] PCA transform on {n_corpus:,} corpus rows")
        t0 = time.time()
        X  = np.asarray(pca_model.transform(X), dtype=np.float32)
        print(f"[time] PCA transform: {time.time() - t0:.1f}s  "
              f"shape {X.shape}")
        gc.collect()
        _heartbeat()

    elif center:
        # Plain mean-centring (v3 fallback when PCA is not configured).
        mean_vec = X.mean(axis=0)
        X        = (X - mean_vec).astype(np.float32)
        print(f"[step] mean-centred embeddings "
              f"(|mean| = {float(np.linalg.norm(mean_vec)):.4f})")
        _heartbeat()

    # ---- UMAP fit --------------------------------------------------------
    print(f"[step] cuml.UMAP fit_transform on {n_corpus:,} rows "
          f"(input dim={X.shape[1]})")
    from cuml.manifold import UMAP as cumlUMAP
    umap_kwargs = dict(
        n_components=int(cl.get("umap_n_components", 5)),
        n_neighbors=int(cl.get("umap_n_neighbors",  15)),
        min_dist=float(cl.get("umap_min_dist",       0.0)),
        metric=cl.get("umap_metric", "euclidean"),
        random_state=int(cl.get("random_seed", 13)),
    )
    if y_labels is not None:
        # Semi-/fully-supervised UMAP: target_weight in [0,1] sets how strongly
        # the concept labels pull the layout (0 = ignore labels, 1 = labels
        # dominate). Configurable via bertopic.configs.<name>.target_weight.
        umap_kwargs["target_metric"] = cl.get("target_metric", "categorical")
        umap_kwargs["target_weight"] = float(cl.get("target_weight", 0.5))
        print(f"[step] supervised fit: target_metric={umap_kwargs['target_metric']}, "
              f"target_weight={umap_kwargs['target_weight']}")
    umap_model = cumlUMAP(**umap_kwargs)
    t0 = time.time()
    if y_labels is not None:
        # cuml treats label -1 as unlabelled for a categorical target.
        umap_arr = umap_model.fit_transform(X, y=y_labels.astype(np.float32))
    else:
        umap_arr = umap_model.fit_transform(X)
    print(f"[time] UMAP fit_transform: {time.time() - t0:.1f}s")
    _heartbeat()

    n_comp     = umap_arr.shape[1]
    coord_cols = [f"V{i+1}" for i in range(n_comp)]
    umap_coords = pd.DataFrame(np.asarray(umap_arr, dtype=np.float32), columns=coord_cols)
    umap_coords.insert(0, "id", ids)

    del X, umap_arr
    gc.collect()
    _heartbeat()

    # ---- Cache write -----------------------------------------------------
    print(f"[cache write] UMAP model + coords to s3://{bucket}/{prefix}")
    _pickle_to_r2(client, bucket, keys["model"],  umap_model)
    _parquet_to_r2(client, bucket, keys["coords"], umap_coords)
    _meta_to_r2(client, bucket, keys["meta"], _cfg_subset(cl, _UMAP_FIELDS), "umap")
    if pca_model is not None:
        _pickle_to_r2(client, bucket, keys["pca_model"], pca_model)
    if mean_vec is not None:
        _pickle_to_r2(client, bucket, keys["mean_vec"], mean_vec)
    _heartbeat()

    return umap_model, umap_coords, mean_vec, pca_model


# ---------------------------------------------------------------------------
# Stage 2: HDBSCAN fit
# ---------------------------------------------------------------------------

def stage_hdbscan(umap_coords: pd.DataFrame, r2_cfg: dict, config_name: str,
                  cl: dict, umap_hash: str, hdbscan_hash: str):
    bucket = r2_cfg["bucket"]
    prefix = f"intermediate/config={config_name}/umap_cfg={umap_hash}/hdbscan_cfg={hdbscan_hash}"
    keys = {
        "model":  f"{prefix}/hdbscan_model.pkl",
        "topics": f"{prefix}/topics.parquet",
        "meta":   f"{prefix}/meta.json",
    }
    client = _r2_client(r2_cfg)

    if _r2_exists(client, bucket, keys["model"]) and _r2_exists(client, bucket, keys["topics"]):
        print(f"[cache hit] HDBSCAN: s3://{bucket}/{prefix}")
        hdbscan_model = _unpickle_from_r2(client, bucket, keys["model"])
        topics_corpus = _parquet_from_r2(client, bucket, keys["topics"])
        return hdbscan_model, topics_corpus

    print(f"[cache miss] HDBSCAN: s3://{bucket}/{prefix}")
    coord_cols = sorted(
        [c for c in umap_coords.columns if c.startswith("V") and c[1:].isdigit()],
        key=lambda c: int(c[1:])
    )
    X_umap = umap_coords[coord_cols].to_numpy(dtype=np.float32)

    print(f"[step] cuml.HDBSCAN fit_predict on {len(umap_coords):,} UMAP coords")
    from cuml.cluster import HDBSCAN as cumlHDBSCAN
    hdbscan_model = cumlHDBSCAN(
        min_cluster_size=int(cl["hdbscan_min_cluster_size"]),
        min_samples=int(cl["hdbscan_min_samples"]),
        metric="euclidean",
        cluster_selection_method="eom",
        prediction_data=True,
    )
    t0 = time.time()
    labels = hdbscan_model.fit_predict(X_umap)
    print(f"[time] HDBSCAN fit_predict: {time.time() - t0:.1f}s")
    _heartbeat()

    topics_corpus = pd.DataFrame({
        "id": umap_coords["id"].astype(str).values,
        "topic_id": np.asarray(labels, dtype=np.int64),
        "topic_source": "embedding",
        "probability": np.nan,
    })

    del X_umap
    gc.collect()

    print(f"[cache write] HDBSCAN model + topics to s3://{bucket}/{prefix}")
    _pickle_to_r2(client, bucket, keys["model"], hdbscan_model)
    _parquet_to_r2(client, bucket, keys["topics"], topics_corpus)
    _meta_to_r2(client, bucket, keys["meta"], _cfg_subset(cl, _HDBSCAN_FIELDS), "hdbscan")
    _heartbeat()

    return hdbscan_model, topics_corpus


# ---------------------------------------------------------------------------
# Stage 3: c-TF-IDF on per-topic concatenated docs
# ---------------------------------------------------------------------------
#
# This is the memory-friendly replacement for BERTopic's Representation step
# that OOM'd on the 116 GB pod. Instead of tokenizing 4.6M individual
# documents, we group corpus docs by topic_id, concatenate within each topic,
# then run CountVectorizer on the resulting ~500 topic-documents. That's
# ~10K-fold reduction in tokenizer input size.

def stage_ctfidf(corpus_root: str, topics_corpus: pd.DataFrame,
                 r2_cfg: dict, config_name: str, cl: dict,
                 umap_hash: str, hdbscan_hash: str, ctfidf_hash: str):
    bucket = r2_cfg["bucket"]
    prefix = (f"intermediate/config={config_name}/umap_cfg={umap_hash}/"
              f"hdbscan_cfg={hdbscan_hash}/ctfidf_cfg={ctfidf_hash}")
    keys = {
        "info":  f"{prefix}/topic_info.parquet",
        "words": f"{prefix}/topic_words.parquet",
        "meta":  f"{prefix}/meta.json",
    }
    client = _r2_client(r2_cfg)

    if _r2_exists(client, bucket, keys["info"]) and _r2_exists(client, bucket, keys["words"]):
        print(f"[cache hit] c-TF-IDF: s3://{bucket}/{prefix}")
        topic_info  = _parquet_from_r2(client, bucket, keys["info"])
        topic_words = _parquet_from_r2(client, bucket, keys["words"])
        return topic_info, topic_words

    print(f"[cache miss] c-TF-IDF: s3://{bucket}/{prefix}")

    # Aggregate corpus text per topic ENTIRELY in duckdb. Previous
    # implementation materialised the full merged DataFrame (~50 GB
    # text + 10 GB doc column + ~20 GB groupby intermediates) which
    # OOM'd on 117 GB pods alongside the ~25 GB cuml models already in
    # host RAM. duckdb's C++ join + group_concat streams the parquet
    # files, evaluates the join, groups by topic_id, and concatenates
    # docs all with bounded internal memory (~few GB). Output is just
    # ~500 rows of {topic_id, doc} — total concatenated text ~10 GB.
    print("[step] streaming corpus text + aggregating per topic via duckdb")
    con = duckdb.connect()
    try:
        _setup_duckdb_s3(con, r2_cfg)
        pattern = _glob(corpus_root, cl["primary_variant"])

        # Register topics_corpus DataFrame as a duckdb view. Only the
        # two columns we need; cast id to VARCHAR to match parquet.
        topics_small = topics_corpus[["id", "topic_id"]].copy()
        topics_small["id"] = topics_small["id"].astype(str)
        topics_small["topic_id"] = topics_small["topic_id"].astype("int64")
        con.register("topics_corpus_view", topics_small)

        docs_per_topic = con.execute(f"""
            SELECT
                tc.topic_id AS topic_id,
                string_agg(
                    COALESCE(c.title_clean, '') || ' ' || COALESCE(c.abstract_clean, ''),
                    ' '
                ) AS doc
            FROM (
                SELECT id, title_clean, abstract_clean
                FROM read_parquet('{pattern}', hive_partitioning = false)
                QUALIFY row_number() OVER (PARTITION BY id) = 1
            ) c
            JOIN topics_corpus_view tc
              ON CAST(c.id AS VARCHAR) = tc.id
            WHERE tc.topic_id >= 0
            GROUP BY tc.topic_id
            ORDER BY tc.topic_id
        """).fetchdf()
        del topics_small
    finally:
        con.close()
    gc.collect()
    print(f"        aggregated to {len(docs_per_topic)} topic-documents")
    _heartbeat()

    print(f"[step] CountVectorizer + TfidfTransformer on {len(docs_per_topic)} topic-documents")
    from sklearn.feature_extraction.text import CountVectorizer, TfidfTransformer

    # Degenerate-clustering guard. When HDBSCAN produces very few non-noise
    # topics (e.g. a homogeneous corpus collapsing to 1–2 topics), the
    # configured document-frequency filters can become infeasible and sklearn
    # raises mid-run. sklearn's own check is `max_df * n_docs < min_df` (both
    # as document counts). Rather than crash the whole pod job at this late
    # stage, clamp to a valid, minimally-filtering pair and warn — a tiny topic
    # count is itself the signal that the clustering needs retuning.
    n_docs     = len(docs_per_topic)
    if n_docs == 0:
        raise SystemExit(
            "[ctfidf] no non-noise topics to vectorise — every corpus work "
            "landed in the noise topic (-1). Loosen HDBSCAN "
            "(hdbscan_min_cluster_size / hdbscan_min_samples) or use a "
            "supervised config (supervised_umap: true)."
        )
    ngram      = tuple(cl.get("vectorizer_ngram", [1, 2]))
    max_feat   = int(cl.get("vectorizer_max_features", 20_000))
    req_min_df = int(cl.get("vectorizer_min_df", 2))
    req_max_df = float(cl.get("vectorizer_max_df", 0.95))
    eff_min_df, eff_max_df = req_min_df, req_max_df
    if req_min_df > n_docs or req_max_df * n_docs < req_min_df:
        print(f"[ctfidf] WARNING: only {n_docs} topic-document(s); configured "
              f"min_df={req_min_df}/max_df={req_max_df} is infeasible "
              f"(max_df -> {req_max_df * n_docs:.1f} docs < min_df). Falling "
              f"back to min_df=1, max_df=1.0 (no doc-frequency filtering). "
              f"Topic words will be noisy — this signals a near-degenerate "
              f"clustering; retune HDBSCAN or use a supervised config.")
        eff_min_df, eff_max_df = 1, 1.0

    def _make_cv(min_df, max_df):
        return CountVectorizer(
            stop_words="english", min_df=min_df, max_df=max_df,
            max_features=max_feat, ngram_range=ngram,
        )
    try:
        cv = _make_cv(eff_min_df, eff_max_df)
        counts = cv.fit_transform(docs_per_topic["doc"].values)
    except ValueError as e:
        # Belt-and-braces: any residual infeasibility (e.g. empty vocab after
        # stop-word/max_features pruning) — retry with no df filtering.
        print(f"[ctfidf] WARNING: CountVectorizer failed ({e}); "
              f"retrying with min_df=1, max_df=1.0.")
        cv = _make_cv(1, 1.0)
        counts = cv.fit_transform(docs_per_topic["doc"].values)
    tfidf = TfidfTransformer(smooth_idf=True, sublinear_tf=False)
    weights = tfidf.fit_transform(counts).toarray()
    vocab = np.array(cv.get_feature_names_out())
    _heartbeat()

    top_n = int(cl.get("top_n_words", 15))
    word_rows = []
    info_rows = []
    for i, tid in enumerate(docs_per_topic["topic_id"].values):
        w = weights[i]
        top_idx = np.argsort(-w)[:top_n]
        top_words_list = []
        for rank, idx in enumerate(top_idx, start=1):
            word = str(vocab[idx])
            weight = float(w[idx])
            word_rows.append({"topic_id": int(tid), "word": word,
                              "weight": weight, "rank": rank})
            top_words_list.append(word)
        label = f"{int(tid)}_" + "_".join(top_words_list[:4])
        info_rows.append({
            "topic_id": int(tid),
            "label": label,
            "top_words": top_words_list,
        })

    topic_words = pd.DataFrame(word_rows)
    topic_info  = pd.DataFrame(info_rows)

    # Include noise topic if any rows fell into it (always with empty words).
    if (topics_corpus["topic_id"] == -1).any():
        topic_info = pd.concat([
            topic_info,
            pd.DataFrame([{"topic_id": -1, "label": "-1_noise", "top_words": []}])
        ], ignore_index=True)

    print(f"[cache write] c-TF-IDF outputs to s3://{bucket}/{prefix}")
    _parquet_to_r2(client, bucket, keys["info"],  topic_info)
    _parquet_to_r2(client, bucket, keys["words"], topic_words)
    _meta_to_r2(client, bucket, keys["meta"], _cfg_subset(cl, _CTFIDF_FIELDS), "ctfidf")
    _heartbeat()

    return topic_info, topic_words


# ---------------------------------------------------------------------------
# Stage 4: Project keypapers (decoupled — Option A from TODO)
# ---------------------------------------------------------------------------

def stage_project_keypapers(refer_root: str, umap_model, hdbscan_model,
                            r2_cfg: dict, cl: dict,
                            mean_vec=None, pca_model=None) -> pd.DataFrame:
    print("[step] projecting keypapers into fitted UMAP + HDBSCAN")
    df_kp = _read_embeddings_only(refer_root, cl["primary_variant"], r2_cfg)
    print(f"        loaded {len(df_kp):,} keypapers")
    X_kp    = _matrix_from_df(df_kp)
    X_kp    = _apply_preprocessing(X_kp, mean_vec, pca_model)
    umap_kp = umap_model.transform(X_kp)
    from cuml.cluster.hdbscan import approximate_predict
    labels_kp, probs_kp = approximate_predict(hdbscan_model, umap_kp)

    return pd.DataFrame({
        "id": df_kp["id"].astype(str).values,
        "source": "keypaper",
        "topic_id": np.asarray(labels_kp, dtype=np.int64),
        "topic_source": "projected",
        "probability": np.asarray(probs_kp, dtype=np.float64),
    })


# ---------------------------------------------------------------------------
# Stage 5: Fallback variant projection (no-abstract corpus works)
# ---------------------------------------------------------------------------

def stage_project_fallback(corpus_root: str, umap_model, hdbscan_model,
                           r2_cfg: dict, config_name: str, cl: dict,
                           umap_hash: str, hdbscan_hash: str,
                           fallback_hash: str,
                           mean_vec=None, pca_model=None) -> pd.DataFrame:
    fallback = cl.get("fallback_variant")
    empty_cols = ["id", "source", "topic_id", "topic_source", "probability"]
    if not fallback:
        return pd.DataFrame(columns=empty_cols)

    bucket = r2_cfg["bucket"]
    prefix = (f"intermediate/config={config_name}/umap_cfg={umap_hash}/"
              f"hdbscan_cfg={hdbscan_hash}/fallback_cfg={fallback_hash}")
    keys = {
        "topics": f"{prefix}/fallback_topics.parquet",
        "meta":   f"{prefix}/meta.json",
    }
    client = _r2_client(r2_cfg)

    if _r2_exists(client, bucket, keys["topics"]):
        print(f"[cache hit] fallback: s3://{bucket}/{prefix}")
        return _parquet_from_r2(client, bucket, keys["topics"])

    print(f"[cache miss] fallback: s3://{bucket}/{prefix}")
    print(f"[step] streaming fallback variant ({fallback}) for no-primary corpus works")
    from cuml.cluster.hdbscan import approximate_predict

    fb_chunks = []
    n_done = 0
    for chunk in _stream_variant_minus_primary(
        corpus_root, fallback, cl["primary_variant"], r2_cfg, chunk_rows=50_000
    ):
        X_chunk    = _matrix_from_df(chunk)
        X_chunk    = _apply_preprocessing(X_chunk, mean_vec, pca_model)
        umap_chunk = umap_model.transform(X_chunk)
        labels, probs = approximate_predict(hdbscan_model, umap_chunk)
        fb_chunks.append(pd.DataFrame({
            "id": chunk["id"].astype(str).values,
            "source": "corpus",
            "topic_id": np.asarray(labels, dtype=np.int64),
            "topic_source": "fallback",
            "probability": np.asarray(probs, dtype=np.float64),
        }))
        n_done += len(chunk)
        print(f"        fallback {n_done:,}")
        _heartbeat()
        del chunk, X_chunk, umap_chunk

    if fb_chunks:
        fallback_topics = pd.concat(fb_chunks, ignore_index=True)
    else:
        fallback_topics = pd.DataFrame(columns=empty_cols)

    print(f"[cache write] fallback topics to s3://{bucket}/{prefix}")
    _parquet_to_r2(client, bucket, keys["topics"], fallback_topics)
    _meta_to_r2(client, bucket, keys["meta"], _cfg_subset(cl, _FALLBACK_FIELDS), "fallback")
    _heartbeat()

    return fallback_topics


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--corpus-emb-dir",    required=True)
    p.add_argument("--reference-emb-dir", required=True)
    p.add_argument("--output-dir",        required=True)
    p.add_argument("--bertopic-cfg-yaml", required=True)
    p.add_argument("--run-name",          required=True)
    args = p.parse_args()

    _heartbeat()
    _start_heartbeat_thread(interval_s=30)

    def _is_s3(p: str) -> bool:
        return p.startswith("s3://")

    def _parent(p: str) -> str:
        return p.rstrip("/").rsplit("/", 1)[0]

    def _basename(p: str) -> str:
        return p.rstrip("/").rsplit("/", 1)[-1]

    corpus_root = args.corpus_emb_dir if _is_s3(args.corpus_emb_dir)    else str(Path(args.corpus_emb_dir).resolve())
    refer_root  = args.reference_emb_dir if _is_s3(args.reference_emb_dir) else str(Path(args.reference_emb_dir).resolve())
    out_root    = Path(args.output_dir).resolve()
    cfg_path    = Path(args.bertopic_cfg_yaml).resolve()
    run_name    = args.run_name

    if _parent(corpus_root) != _parent(refer_root):
        sys.exit(
            "corpus and reference must share parent (config dir); got\n"
            f"  corpus:    {corpus_root}\n  reference: {refer_root}"
        )
    config_name = _basename(_parent(corpus_root)).split("=", 1)[1]

    with cfg_path.open("r") as fh:
        cl = yaml.safe_load(fh)

    r2_cfg = cl.get("r2", {}) or {}
    if not r2_cfg.get("endpoint") or not r2_cfg.get("bucket"):
        raise SystemExit(
            "Stage caching requires cfg.r2.endpoint and cfg.r2.bucket. "
            "Either populate them or revert to a pre-v0.1.8 image for the "
            "monolithic flow."
        )

    primary  = cl["primary_variant"]
    fallback = cl.get("fallback_variant")
    print(f"[info] config_name = {config_name}")
    print(f"[info] run_name    = {run_name}")
    print(f"[info] primary     = {primary}    fallback = {fallback}")
    print(f"[info] r2 endpoint = {r2_cfg['endpoint']}  bucket = {r2_cfg['bucket']}")

    # Cascade cfg hashes — printed up front so cache hits/misses are easy to
    # trace in the log.
    umap_hash    = _cfg_hash(_cfg_subset(cl, _UMAP_FIELDS))
    hdbscan_hash = _cfg_hash(_cfg_subset(cl, _HDBSCAN_FIELDS))
    ctfidf_hash   = _cfg_hash(_cfg_subset(cl, _CTFIDF_FIELDS))
    fallback_hash = _cfg_hash(_cfg_subset(cl, _FALLBACK_FIELDS))
    print(f"[info] cfg hashes  umap={umap_hash}  hdbscan={hdbscan_hash}  "
          f"ctfidf={ctfidf_hash}  fallback={fallback_hash}")

    # -------- Stage 1: UMAP fit (or load) --------------------------------
    umap_model, umap_coords, mean_vec, pca_model = stage_umap(
        corpus_root, r2_cfg, config_name, cl, umap_hash, refer_root=refer_root
    )
    _heartbeat()

    # -------- Stage 2: HDBSCAN fit (or load) -----------------------------
    hdbscan_model, topics_corpus = stage_hdbscan(
        umap_coords, r2_cfg, config_name, cl, umap_hash, hdbscan_hash
    )
    _heartbeat()

    del umap_coords
    gc.collect()

    # -------- Stage 3: c-TF-IDF on per-topic docs (or load) --------------
    topic_info, topic_words = stage_ctfidf(
        corpus_root, topics_corpus, r2_cfg, config_name, cl,
        umap_hash, hdbscan_hash, ctfidf_hash
    )
    _heartbeat()

    # -------- Stage 4: project keypapers ---------------------------------
    topics_kp = stage_project_keypapers(
        refer_root, umap_model, hdbscan_model, r2_cfg, cl,
        mean_vec=mean_vec, pca_model=pca_model
    )
    _heartbeat()

    # -------- Stage 5: project fallback variant --------------------------
    topics_fb = stage_project_fallback(
        corpus_root, umap_model, hdbscan_model,
        r2_cfg, config_name, cl,
        umap_hash, hdbscan_hash, fallback_hash,
        mean_vec=mean_vec, pca_model=pca_model
    )
    _heartbeat()

    # -------- Stage 6: combine + per-topic counts + final outputs --------
    print("[step] composing final outputs")
    topics_corpus_out = topics_corpus.copy()
    topics_corpus_out["source"] = "corpus"
    out_topics = pd.concat([topics_corpus_out, topics_kp, topics_fb], ignore_index=True)
    out_topics["topic_id"] = out_topics["topic_id"].astype(np.int64)

    cnt = (
        out_topics.groupby(["topic_id", "source"]).size()
        .unstack(fill_value=0).reset_index()
    )
    if "corpus"   not in cnt.columns: cnt["corpus"]   = 0
    if "keypaper" not in cnt.columns: cnt["keypaper"] = 0
    cnt = cnt.rename(columns={"corpus": "n_corpus", "keypaper": "n_keypapers"})

    kp_thresh = int(cl.get("keypaper_threshold", 3))
    info = topic_info.merge(cnt[["topic_id", "n_corpus", "n_keypapers"]],
                            on="topic_id", how="left")
    info["n_corpus"]    = info["n_corpus"].fillna(0).astype(int)
    info["n_keypapers"] = info["n_keypapers"].fillna(0).astype(int)
    info["n_total"]     = info["n_corpus"] + info["n_keypapers"]
    info["is_relevant"] = info["n_keypapers"] >= kp_thresh

    out_dir = _leaf_dir(out_root, config_name, run_name, primary)

    # Stamp provenance into every parquet so files are self-describing when
    # read directly with read_parquet() — not just when accessed via
    # open_dataset() hive partitioning.
    for df in (out_topics, info, topic_words):
        df["embedding_config"] = config_name
        df["bertopic_config"]  = run_name
        df["variant"]          = primary

    print(f"[step] writing parquets to {out_dir}")
    out_topics.to_parquet( out_dir / "topics.parquet",      index=False)
    info.to_parquet(       out_dir / "topic_info.parquet",  index=False)
    topic_words.to_parquet(out_dir / "topic_words.parquet", index=False)

    n_topics = int((info["topic_id"] >= 0).sum())
    n_noise  = int((out_topics["topic_id"] == -1).sum())
    n_fb     = int((out_topics["topic_source"] == "fallback").sum())
    n_proj   = int((out_topics["topic_source"] == "projected").sum())
    print(f"[done] topics={n_topics}  noise={n_noise:,}  fallback={n_fb:,}  keypapers_projected={n_proj}")
    print(str(out_dir / "topic_info.parquet"))
    _heartbeat()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
