# BoltAI — Local Fast AI Agent (MVP)

BoltAI is a small, local, fast AI agent MVP that demonstrates a self-contained information retrieval workflow using Rust. This initial scaffold implements a TF-IDF based indexer and a simple query CLI. It's designed to be extended with local LLM inference (llama.cpp) or a vector DB (Qdrant) later.

Features
- Index a directory of text files (txt, md, csv, json)
- Query the index from the CLI, returning top-k similar documents
- Rust + rayon parallelism for fast local processing

Getting started

1) Install Rust (if not installed):
```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```
2) Build:
```bash
   cargo build --release
```
3) Index a directory:
```bash
   ./target/release/boltai index -d path/to/docs -o boltai_index.json
```
4) Query the index:
```bash
   ./target/release/boltai query -i boltai_index.json -q "search terms" -k 5
```
Next steps

- Replace TF-IDF vectorizer with embeddings from a local LLM (llama.cpp) for semantic search.
- Add Qdrant or SQLite-backed vector store for large collections.
- Add file watchers for live indexing and a TUI for exploration.

Quick next-step roadmap

1) Local LLM (llama.cpp) integration
   - Create an embeddings interface that sends file contents or document chunks to a local llama.cpp process and stores 768/1024-d float vectors.
   - Swap TF-IDF vectors for those embeddings and use cosine similarity for semantic search.

2) Vector DB (Qdrant)
   - When collection sizes grow, persist vectors to Qdrant and use its nearest-neighbours API.
   - Keep document metadata (path, id) in the DB to fetch and display results.

3) CLI to Agent + LLM pipeline
   - Add a `summarize` command that loads top-k results and calls a local or remote LLM to produce an executive summary.

