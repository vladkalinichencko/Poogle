# Poogle Status

## Current

| Part | Status |
| --- | --- |
| Native SwiftUI window | Real |
| Folder selection | Real |
| Recursive PDF-only scanner | Real |
| Local PyMuPDF extraction and cleanup | Real |
| Indexing progress | Real |
| Stop and resume indexing | Real |
| Incremental file detection | Real |
| SHA-256 document identity | Real |
| Move and duplicate detection | Real |
| Separate document locations | Real |
| SQLite document ledger | Real |
| SQLite FTS5 section storage | Real |
| FTS5 relevance-ranked search UI | Real |
| Per-file failure isolation | Real |
| Qwen3 512-token body chunking with 128 overlap | Real |
| MLX Qwen3-Embedding-4B embeddings | Real |
| MLX body embedding batch size 16 | Real |
| Persistent semantic index | Real |
| Qwen body cosine and FTS5 candidate retrieval | Real |
| Degenerate numeric chunk rejection | Real |
| MLX Qwen3-Reranker-0.6B relevance ranking | Real |
| Per-result relevance percentage | Real |
| Variable result count from calibrated relevance | Real |
| Google-like Liquid Glass interface | Real |
| Annotated native UI refinement | Built, activates on next app launch |

## Search calibration

| Rule | Current value |
| --- | ---: |
| Qwen body cosine floor (recall) | 0.55 |
| Exact-term admit fraction | 0.50 |
| Reranker candidate ceiling | 64 |
| Final reranker minimum (precision dial) | 0.10 |

Retrieval is a two-stage recall/precision split. Recall: a document enters the
pool when its best Qwen body chunk clears the cosine floor, or when it carries a
strong exact/lexical term match (so precise lookups survive even when the Qwen
vector ranks them low). Precision: the top 64 of that pool are scored in
batches of four by the MLX Qwen3-Reranker, and only
documents at or above the final minimum are returned, sorted by reranker score
and de-duplicated by title and abstract. The result count is therefore adaptive
— a measurement on the query "over-smoothing in video generation" against the
1775-document library returned 11 documents, where the bi-encoder cosines were
indistinguishable (0.73–0.78) but reranker scores separated cleanly (0.42 down
to 0.002). The final minimum is the precision dial: raising it returns fewer,
stricter results.
