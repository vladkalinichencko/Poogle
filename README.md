# Poogle

Local semantic search for your research-paper library. Point it at a folder of
PDFs and ask in plain language — Poogle returns the papers that actually answer
the query. Everything runs on-device; nothing leaves your Mac.

## How it works

**Indexing**
- Recursively finds PDFs and identifies each by the SHA-256 of its bytes, so
  moving or duplicating a file never re-embeds it.
- Extracts and normalizes text with PyMuPDF, recovers titles and abstracts, and
  drops table-and-number "soup" chunks before they reach the index.
- Embeds 512-token body chunks (128 overlap) with MLX Qwen3-Embedding-4B and
  stores the vectors and text in SQLite (FTS5).

**Search**
- *Recall* — a document enters the pool when its best chunk clears a cosine
  floor on the Qwen body vector, or when it carries a strong exact/lexical match.
- *Precision* — the top candidates are scored by the MLX Qwen3-Reranker, a
  cross-encoder that reads the query and passage together. Only results above a
  relevance threshold are returned, ranked and de-duplicated, so the number of
  results adapts to how much the library actually contains.

The app is native SwiftUI; a small Python sidecar handles embedding and
reranking through MLX on Apple Silicon.

## Run it

Requires macOS 15+ on Apple Silicon, the Xcode toolchain, and Python 3.12.

```sh
./script/build_and_run.sh
```

First run sets up the Python environment, builds the app, installs it to
`/Applications`, and launches it. Open Poogle, choose a folder of PDFs, and let
it index — the MLX models download on first use.

## Layout

- `Sources/Poogle` — SwiftUI app, SQLite index, and search engine.
- `Sources/Poogle/Resources/embedding_worker.py` — MLX embedding and reranking sidecar.
- `script/` — build/run and index-maintenance scripts.
