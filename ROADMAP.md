# VoltAI — Roadmap

Milestones track the major version goals. Check off items as they ship.

---

## v0.8.2 — Current Release ✅

- [x] Rust CLI: `index`, `query`, `bench` subcommands
- [x] TF-IDF engine with smooth IDF, log-TF, L2 normalization
- [x] Stop-word filtering (72 words)
- [x] PDF, TXT, MD, CSV, JSON file support
- [x] Ollama LLM integration with model auto-detection
- [x] Parallel indexing via Rayon
- [x] GitHub Actions CI (test + lint)
- [x] macOS SwiftUI app: chat, index, settings tabs
- [x] Ollama status detection + UI banner
- [x] `VoltAICore` library extracted for unit testability
- [x] 82 Rust tests, 61 Swift unit tests

---

## v0.8.3 — Hygiene & Bug Fixes ✅

- [x] `PLAN.md` and `ROADMAP.md` in repo root
- [x] DRY-refactor: `print_keyword_fallback()` eliminates 97-line duplication
- [x] Vacuous test assertions replaced with real assertions
- [x] Bench VOCAB: duplicates removed, typo fixed
- [x] Asymmetric TF weighting documented
- [x] Swift `@MainActor` isolation (eliminates Swift 6 concurrency warning)
- [x] "Refresh models" button correctly updates `ollamaStatus`
- [x] Alert title dynamically reflects error type
- [x] Dead `selectedDoc` property removed

---

## v0.9.0 — Performance & Packaging ✅

- [x] Binary index format (`--format binary` via bincode, auto-detect on load)
- [x] Indeterminate progress spinner (removes misleading 0→100% jump)
- [x] macOS `.dmg` artifact from CI (via `hdiutil`); macOS Swift test job added
- [x] Test coverage reporting (tarpaulin + llvm-cov) in CI

---

## v1.0.0 — Production Quality ✅

- [x] `VoltAICallerProtocol` + `MockVoltAICaller` for DI
- [x] `sendQuery` async path fully tested (5 cases)
- [x] `index(paths:)` cancellation path tested
- [x] `init` Ollama check path tested (3 cases)
- [x] 93 Rust tests, 75 Swift tests; clippy clean
- [x] User-configurable `k` (results count) in Settings (UserDefaults-backed Stepper)
- [x] Theme picker wired to `NSAppearance` (`.preferredColorScheme`)
- [x] Document detail panel (tap-to-expand sheet)
- [ ] 90%+ Rust test coverage (tarpaulin)
- [ ] 85%+ Swift test coverage (llvm-cov)
- [ ] Homebrew formula (`brew install voltai`)
- [ ] macOS app notarization (Developer ID)

---

## v2.0.0 — Architecture Evolution ✅ (partially)

- [x] BM25 scoring (Robertson-Sparck Jones IDF, k1=1.2, b=0.75)
- [x] Inverted index for O(T) query (replaces O(N×V) linear scan)
- [ ] Embedding-based reranking via Ollama embedding API
- [ ] Hybrid search: sparse BM25 + dense cosine reranker
- [ ] Background indexing daemon (watcher on indexed directories)
- [ ] Metal/ANE embedding acceleration (Apple Silicon)
- [ ] Streaming Ollama output (token-by-token response in UI)
