
# ⚡️🤖 BoltAI — Local fast AI agent

BoltAI is a compact, local-first AI agent implemented in Rust with a companion macOS SwiftUI front-end (mac-ui). It demonstrates a practical, privacy-respecting information retrieval and local-LLM orchestration workflow suitable for developer tooling, research workflows, and offline indexing use-cases.

## ▶️ Demo

![DemoForBoltAI](https://github.com/user-attachments/assets/03a24efc-f34d-4490-beb7-59b1e01cde14)

👨🏻‍💻 Why this project
-----------------
- Local-first: keeps data on your machine — no cloud upload by default. Ideal for sensitive documents and private datasets.
- Fast & lightweight: TF-IDF indexer with parallel processing (rayon) for quick indexing of developer repos and document collections.
- Extensible: designed as an MVP scaffold to add embeddings, local LLMs (llama.cpp / Ollama), vector DBs (Qdrant), or hybrid pipelines.

❇️ Highlights
----------
- Indexing: recursive indexing of common formats (.txt, .md, .csv, .json, .pdf) into a compact JSON index.
- Query CLI: run similarity search and quick queries against local indexes.
- Desktop UI: macOS SwiftUI front-end for drag-and-drop indexing, chat-style queries, and document previews.
- Privacy-first defaults: keeps file contents local and provides safeguards against accidentally printing full documents to the UI or logs.

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
 - **NLP capabilities** — Named Entity Recognition, Sentiment Analysis, and Text Summarization
   - Pattern-based NER for extracting names, locations, organizations, dates, emails, and monetary values
   - Lexicon-based sentiment analysis (positive, neutral, negative)
   - Extractive text summarization using sentence scoring

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

 ### Use NLP features

 #### Named Entity Recognition (NER)

 Extract entities like names, locations, organizations, dates, emails, and monetary values from text:

 ```bash
 # Analyze a single file
 ./target/release/boltai ner -i document.txt

 # Analyze all files in a directory
 ./target/release/boltai ner -i /path/to/docs

 # Save results to a file
 ./target/release/boltai ner -i document.txt -o entities.txt
 ```

 #### Sentiment Analysis

 Determine sentiment (positive, neutral, or negative) of text:

 ```bash
 # Analyze a single file
 ./target/release/boltai sentiment -i review.txt

 # Batch analyze multiple files
 ./target/release/boltai sentiment -i /path/to/reviews -o sentiment_results.txt
 ```

 #### Text Summarization

 Generate extractive summaries of documents:

 ```bash
 # Summarize a single file
 ./target/release/boltai summarize -i article.txt

 # Summarize multiple files in a directory
 ./target/release/boltai summarize -i /path/to/articles -o summaries.txt
 ```

 **Supported file formats**: `.txt`, `.md`, `.csv`, `.json`, `.pdf`

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

 ### NLP Feature Examples

 **Named Entity Recognition output:**
 ```
 Named Entities found in document.txt:
   - John Smith (PERSON): score 0.750
   - john.smith@example.com (EMAIL): score 0.950
   - New York (LOCATION): score 0.850
   - Microsoft Corporation (ORGANIZATION): score 0.800
   - $150,000 (MONEY): score 0.900
   - Jan 15, 2024 (DATE): score 0.900
 ```

 **Sentiment Analysis output:**
 ```
 Sentiment analysis for review.txt:
   - Label: Positive, Score: 0.857
 ```

 **Text Summarization output:**
 ```
 Summary of article.txt:
 Artificial intelligence has become one of the most transformative technologies. 
 Deep learning has achieved remarkable breakthroughs in computer vision and natural 
 language processing. Machine learning algorithms optimize trading strategies and 
 detect fraudulent transactions.
 ```

 ## Project architecture

 - Rust CLI (`src/main.rs`): walks directories, extracts text (including PDFs), computes TF-IDF vectors, and writes `boltai_index.json`.
 - NLP module (`src/nlp/`): provides pattern-based NER, lexicon-based sentiment analysis, and extractive text summarization.
 - mac-ui SwiftUI: orchestrates indexing runs, loads a capped preview of index docs (to avoid huge JSON parsing on the main thread), and sends queries to the CLI.
 - Extensibility: The CLI prompt layer is isolated to make it easy to swap the query strategy (keywords → embeddings → hybrid retrieval-augmented generation). NLP features use lightweight rule-based approaches but can be upgraded to ML models (rust-bert) when libtorch is available.

 ## Design decisions & trade-offs

 - TF-IDF first: fast to compute, explainable, and sufficient for small-to-medium corpora. Replacing TF-IDF with dense embeddings is an intended next step for semantic search.
 - Rule-based NLP: Uses regex patterns and lexicons for NER and sentiment analysis. Fast, no external dependencies, but less accurate than ML models. Can be upgraded to rust-bert/transformers when libtorch is available in the environment.
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

 ## Contributing

 Contributions are welcome. If you plan to extend BoltAI, open an issue describing the change and submit a pull request with tests where appropriate.

 ## License & credits

 MIT licensed. Built by Wesley Scholl.

