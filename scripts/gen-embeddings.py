#!/usr/bin/env python3
"""gen-embeddings.py — генерация pgvector-эмбеддингов для knowledge_base.

Использует all-MiniLM-L6-v2 (ONNX, кэш Holix/ChromaDB) через onnxruntime.
Обрабатывает записи knowledge_base БЕЗ embedding (embedding IS NULL), обновляет
колонку embedding (vector). Вектор 384-dim, mean pooling, L2-нормализация.

Запуск: python3 ~/studio/scripts/gen-embeddings.py [--all]
"""
import json
import os
import subprocess
import sys

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

MODEL_DIR = os.path.expanduser("~/.cache/chroma/onnx_models/all-MiniLM-L6-v2/onnx")
DB = ["docker", "exec", "-i", "nocodb-postgres-db", "psql", "-U", "nocodb_user", "-d", "hermes_brain", "-t", "-A", "-F", "|||", "-c"]
DIM = 384


def psql(sql: str) -> str:
    r = subprocess.run(DB + [sql], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ! psql error: {r.stderr.strip()[:160]}", file=sys.stderr)
    return r.stdout.strip()


def embed(texts: list[str]) -> np.ndarray:
    tok = Tokenizer.from_file(os.path.join(MODEL_DIR, "tokenizer.json"))
    sess = ort.InferenceSession(os.path.join(MODEL_DIR, "model.onnx"), providers=["CPUExecutionProvider"])
    enc = tok.encode_batch(texts)
    max_len = max(len(e.ids) for e in enc)
    max_len = min(max_len, 256) or 1
    ids = np.zeros((len(texts), max_len), dtype=np.int64)
    mask = np.zeros((len(texts), max_len), dtype=np.int64)
    for i, e in enumerate(enc):
        ids[i, : len(e.ids[:max_len])] = e.ids[:max_len]
        mask[i, : len(e.ids[:max_len])] = 1
    out = sess.run(None, {"input_ids": ids, "attention_mask": mask, "token_type_ids": np.zeros_like(ids)})[0]  # (N, L, H)
    # mean pooling по маске
    mask3 = mask[..., None].astype(np.float32)
    pooled = (out * mask3).sum(1) / np.maximum(mask3.sum(1), 1e-9)
    # L2 normalize
    pooled = pooled / np.maximum(np.linalg.norm(pooled, axis=1, keepdims=True), 1e-9)
    return pooled


def main() -> None:
    only_missing = "AND embedding IS NULL" if "--all" not in sys.argv else ""
    rows_raw = psql(f"SELECT id, title, content FROM knowledge_base WHERE status='active' {only_missing} ORDER BY id;")
    rows = []
    for line in rows_raw.splitlines():
        parts = line.split("|||", 2)
        if len(parts) == 3:
            rows.append((int(parts[0].strip()), parts[1], parts[2]))
    if not rows:
        print("no rows to embed")
        return
    print(f"embedding {len(rows)} rows")
    BATCH = 32
    done = 0
    for i in range(0, len(rows), BATCH):
        batch = rows[i : i + BATCH]
        texts = [(t or "") + "\n" + (c or "")[:4000] for _, t, c in batch]
        vecs = embed(texts)
        for (rid, _, _), v in zip(batch, vecs):
            arr = "[" + ",".join(f"{x:.6f}" for x in v) + "]"
            psql(f"UPDATE knowledge_base SET embedding = '{arr}'::vector WHERE id = {rid};")
            done += 1
        print(f"  {done}/{len(rows)}")
    n = psql("SELECT count(*) FROM knowledge_base WHERE embedding IS NOT NULL;")
    print(f"done: {n} rows with embeddings")


if __name__ == "__main__":
    main()
