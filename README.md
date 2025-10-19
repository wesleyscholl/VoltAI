
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

 # BoltAI — Local fast AI agent (MVP)

 BoltAI is a compact, local-first AI agent built as an MVP to demonstrate fast on-device document indexing, similarity search, and local LLM orchestration. It combines a Rust CLI (indexer & query helper) with a macOS SwiftUI desktop front-end for drag-and-drop indexing and chat-style queries.

 This repository is ideal for showcasing systems, privacy-first design, and end-to-end local AI pipelines on your portfolio site.

 ## Live demo (locally)

 - Drag-and-drop a folder of documents into the `mac-ui` app. The app launches the Rust indexer and produces `boltai_index.json`.
 - Ask questions in the chat UI (or use the CLI) to summarize, search, or reason over the indexed documents.

 ## Portfolio blurb (short)

 BoltAI — a lightning-fast, Rust-powered local AI assistant for secure, offline document search and summarization. Built for developers and researchers who need private, low-latency AI on their workstation. ⚡🤖🔒

 ## Why I built BoltAI

 - Demonstrate a practical, privacy-first approach to integrating local LLMs and retrieval pipelines.
 - Showcase engineering trade-offs: TF-IDF for speed & simplicity, with an easy migration path to embeddings & vector stores.
 - Provide a foundation for offline-first tools that can be extended into production-quality desktop agents.

 ## Key features

 - Local TF-IDF indexer (Rust) — fast multithreaded indexing of plain text and PDFs
 - Query CLI — simple commands for search, summarization, and diagnostic output
 - macOS SwiftUI front-end — drag/drop indexing, chat-style interface, and previewed document snippets
 - PDF extraction support and safety measures to avoid dumping raw documents in prompts or UI

 ## Quickstart

 ### Prerequisites

 - Rust (install via rustup)
 - macOS command line tools (for SwiftUI front-end)

 ### Build the CLI

 ```bash
 # From repository root
 cargo build --release

 # Binary: target/release/boltai
 ```

 ### Index a directory

 ```bash
 ./target/release/boltai index -d /path/to/docs -o boltai_index.json
 ```

 ### Query the index

 ```bash
 ./target/release/boltai query -i boltai_index.json -q "summarize the indexed documents" -k 5
 ```

 ### Run the macOS UI (development)

 ```bash
 cd mac-ui
 swift run
 # or open in Xcode to run the app target and inspect the UI
 ```

 ## Example output (CLI)

 After indexing, `boltai query` returns top-k similar documents and a short summary. Example (truncated):

 ```
 Top 3 results:
 1) docs/architecture.md (score: 0.87)
      Excerpt: "BoltAI is designed to be local-first..."
 2) docs/notes.pdf (score: 0.72)
      Excerpt: "Local LLM integration enables..."

 AI summary:
 BoltAI demonstrates a privacy-first local retrieval pipeline that indexes developer documentation and supports fast summarization and search. It uses TF-IDF for initial vectorization and provides clear extension points for embeddings and LLM-based abstraction.
 ```

 ## Project architecture

 - Rust CLI (`src/main.rs`): walks directories, extracts text (including PDFs), computes TF-IDF vectors, and writes `boltai_index.json`.
 - mac-ui SwiftUI: orchestrates indexing runs, loads a capped preview of index docs (to avoid huge JSON parsing on the main thread), and sends queries to the CLI.
 - Extensibility: The CLI prompt layer is isolated to make it easy to swap the query strategy (keywords → embeddings → hybrid retrieval-augmented generation).

 ## Design decisions & trade-offs

 - TF-IDF first: fast to compute, explainable, and sufficient for small-to-medium corpora. Replacing TF-IDF with dense embeddings is an intended next step for semantic search.
 - Local-first: prioritizes data privacy and low-latency responses at the expense of requiring local compute resources.
 - Safety: the UI and CLI avoid including full raw documents in prompts and no longer print raw text as a fallback. The project logs prompts to a local debug file for reproducible tuning.

 ## Roadmap & extension ideas

 ### Short term
 - Add optional embeddings pipeline (llama.cpp, Ollama) and store vectors for semantic search.
 - Implement a two-stage summarization (extract top-k snippets then abstractive summarize).

 ### Medium term
 - Add Qdrant or SQLite-backed vector store for scale.
 - Add Homebrew packaging and an installer for easier distribution.

 ### Long term
 - Provide offline LLM support with a bundled lightweight model for extraction and compression.
 - Add user profiles and fine-grained privacy controls for teams.

 ## Notes for portfolio presentation

 - Suggested one-line project card:
    - BoltAI — lightning-fast local AI agent for secure offline document search & summarization ⚡🤖🔒
 - Suggested short demo steps for a GIF/snippet:
    1) Drag a small project folder with 5–8 markdown files into the UI.
    2) Wait for indexing to complete (show progress bar).  
    3) Type: "summarize the indexed documents" and show the resulting summary.
 - Assets to include on the portfolio page:
    - 240–480px GIF (3–8s) showing drag-drop → index → summary.
    - One-line blurb + link to the GitHub repo.

 ## Contributing

 Contributions are welcome. If you plan to extend BoltAI, open an issue describing the change and submit a pull request with tests where appropriate.

 ## License & credits

 MIT licensed. Built by Wesley Scholl.

