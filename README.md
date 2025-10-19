
# BoltAI — Local fast AI agent (MVP)

BoltAI is a compact, local-first AI agent implemented in Rust with a companion macOS SwiftUI front-end (mac-ui). It demonstrates a practical, privacy-respecting information retrieval and local-LLM orchestration workflow suitable for developer tooling, research workflows, and offline indexing use-cases.

Why this project
-----------------
- Local-first: keeps data on your machine — no cloud upload by default. Ideal for sensitive documents and private datasets.
- Fast & lightweight: TF-IDF indexer with parallel processing (rayon) for quick indexing of developer repos and document collections.
- Extensible: designed as an MVP scaffold to add embeddings, local LLMs (llama.cpp / Ollama), vector DBs (Qdrant), or hybrid pipelines.

Highlights
----------
- Indexing: recursive indexing of common formats (.txt, .md, .csv, .json, .pdf) into a compact JSON index.
- Query CLI: run similarity search and quick queries against local indexes.
- Desktop UI: macOS SwiftUI front-end for drag-and-drop indexing, chat-style queries, and document previews.
- Privacy-first defaults: keeps file contents local and provides safeguards against accidentally printing full documents to the UI or logs.

Quick start (developer)
-----------------------
Prerequisites
- Rust + cargo: https://rustup.rs
- (Optional) Xcode or macOS command line tools for the mac-ui

Build the CLI

```bash
# from the repo root
cargo build --release

# the resulting binary is at `target/release/boltai`
```

Index a folder

```bash
./target/release/boltai index -d /path/to/docs -o boltai_index.json
```

Run a query

```bash
./target/release/boltai query -i boltai_index.json -q "summarize the indexed documents" -k 5
```

Run the macOS UI

```bash
cd mac-ui
swift run
# or build in Xcode for development
```

Project structure
-----------------
- `src/` — Rust CLI implementation (indexing, query prompting, PDF extraction)
- `mac-ui/` — macOS SwiftUI front-end, drop-to-index UI, and chat interface
- `boltai_index.json` — typical output index file produced by the CLI

Security and privacy notes
--------------------------
BoltAI is intentionally local-first. The UI and CLI avoid printing full raw documents into model prompts or to UI fallbacks to reduce the risk of accidental data leakage. If you connect an external LLM or remote service, review its configuration and network policy to maintain privacy.

Roadmap / extension ideas
-------------------------
1) Embeddings + local LLM
   - Add an embeddings pipeline (llama.cpp, Ollama, or a local API) and store vectors for semantic search.
2) Vector DB
   - Integrate Qdrant or an SQLite-backed vector store for scale and persistence.
3) Two-pass summarization
   - Extract top-k snippets, then run an abstractive summarizer for robust paraphrase results.
4) CI / packaging
   - Build Homebrew formula or macOS app packaging for easy installs.

For portfolio use
-----------------
If you want to showcase BoltAI on your portfolio (https://wesleyscholl.github.io/) I can:

- Add a concise one-line summary for the project page.
- Create a short demo GIF (screen recording) showing drag-drop indexing and a sample chat summarize flow.
- Export a minimal `README.md` blurb suitable for a GitHub project card.

Contact / credits
-----------------
Built by Wesley Scholl. Code and contributions welcome — open an issue or PR.

