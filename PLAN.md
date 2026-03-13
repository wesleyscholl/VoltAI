# VoltAI — Implementation Plan

> **Read this file before starting any session.** Update it after every session to reflect
> completed items, new findings, and blockers.

## Current State

Version `0.9.0`. Working Rust TF-IDF CLI + macOS SwiftUI app. 88 Rust tests, 61 Swift tests.
CI: Linux Rust test/lint + macOS Swift test + macOS DMG packaging. Phases 1–2 complete.

---

## Phase 1 — Project Hygiene & Bug Fixes (`v0.8.3`)

**Status:** ✅ Complete

| # | Task | File(s) | Status |
|---|---|---|---|
| 1.1 | Create PLAN.md and ROADMAP.md | `PLAN.md`, `ROADMAP.md` | ✅ Done |
| 1.2 | Rust: DRY-refactor duplicate fallback logic → `print_keyword_fallback()` | `src/main.rs` | ✅ Done |
| 1.3 | Rust: Fix vacuous test assertions (lines 1109, 1188) | `src/main.rs` | ✅ Done |
| 1.4 | Rust: Fix bench VOCAB duplicates and "probabilistic" typo | `src/main.rs` | ✅ Done |
| 1.5 | Rust: Document asymmetric TF weighting (inline comment) | `src/main.rs` | ✅ Done |
| 1.6 | Swift: Fix `@MainActor` concurrency warning in `VoltAIViewModel` | `VoltAIViewModel.swift` | ✅ Done |
| 1.7 | Swift: Fix "Refresh models" button to call `checkOllamaStatus()` | `ContentView.swift` | ✅ Done |
| 1.8 | Swift: Fix hardcoded alert title ("Index file missing" for all errors) | `ContentView.swift` | ✅ Done |
| 1.9 | Swift: Remove dead `selectedDoc` `@Published` property | `VoltAIViewModel.swift` | ✅ Done |

**Acceptance criteria:** ✅ All met
- `cargo test` 85 tests, no tautology assertions, `clippy` clean
- `swift test` 61 tests, zero Swift 6 concurrency warnings
- Both docs committed to repo root

---

## Phase 2 — v0.9.0 Milestones

**Status:** ✅ Complete (`v0.9.0`)

| # | Task | File(s) | Status |
|---|---|---|---|
| 2.1 | Rust: Binary index format (`--format json\|binary`, bincode) | `src/main.rs`, `Cargo.toml` | ✅ Done |
| 2.2 | Swift: Replace fake progress bar with indeterminate spinner | `ContentView.swift` | ✅ Done |
| 2.3 | CI: macOS Swift test job + `.dmg` packaging via `hdiutil` | `.github/workflows/ci.yml` | ✅ Done |

**Acceptance criteria:** ✅ All met
- `voltai index --format binary` produces a bincode file; `voltai query` auto-detects by extension
- 88 Rust tests, 61 Swift tests all pass; `clippy` clean
- CI has `swift-test` (macos-latest) and `package` (DMG artifact) jobs

---

## Phase 3 — Test Coverage (≥ 90%)

**Status:** ⬜ Pending

| # | Task | File(s) | Status |
|---|---|---|---|
| 3.1 | Swift: Define `VoltAICallerProtocol` | `VoltAICore/VoltAICallerProtocol.swift` (new) | ⬜ |
| 3.2 | Swift: Create `MockVoltAICaller` in test target | `Tests/VoltAITests/MockVoltAICaller.swift` (new) | ⬜ |
| 3.3 | Swift: Test `sendQuery` async path (6 cases) | `VoltAITests.swift` | ⬜ |
| 3.4 | Swift: Test `init` async Ollama check (3 cases) | `VoltAITests.swift` | ⬜ |
| 3.5 | Swift: Test cancellation path | `VoltAITests.swift` | ⬜ |
| 3.6 | Rust: Test `print_keyword_fallback` after Phase 1.2 | `src/main.rs` | ✅ Done (Phase 1) |
| 3.7 | CI: Add `cargo-tarpaulin` + `swift test --enable-code-coverage` | `ci.yml` | ⬜ |

**Acceptance criteria:**
- Rust coverage ≥ 90% (tarpaulin)
- Swift coverage ≥ 85% (llvm-cov)
- CHANGELOG updated with real figures

---

## Phase 4 — UX Features & Architecture Evolution

**Status:** ⬜ Pending

| # | Task | File(s) | Status |
|---|---|---|---|
| 4.1 | Swift: User-configurable `k` via `@AppStorage` + Settings stepper | `VoltAIViewModel.swift`, `ContentView.swift` | ⬜ |
| 4.2 | Swift: Theme picker wired to `.preferredColorScheme` | `VoltAIViewModel.swift`, `ContentView.swift` | ⬜ |
| 4.3 | Swift: Background indexing toggle backed by `@AppStorage` | `VoltAIViewModel.swift`, `ContentView.swift` | ⬜ |
| 4.4 | Swift: Document detail panel (`selectedDoc` + `.sheet`) | `VoltAIViewModel.swift`, `ContentView.swift` | ⬜ |
| 4.5 | Rust: BM25 scoring (Robertson-Sparck Jones IDF, k1=1.2, b=0.75) | `src/main.rs` | ⬜ |
| 4.6 | Rust: Inverted index for O(T) query | `src/main.rs` | ⬜ |

**Acceptance criteria:**
- Settings persist across restarts
- BM25 bench results measurably faster than TF-IDF baseline
- ROADMAP `v2.0.0` items checked off

---

## Verification Commands

```bash
# After every phase
cargo test --all && cargo fmt --check && cargo clippy -- -D warnings
swift build --package-path mac-ui && swift test --package-path mac-ui

# After Phase 3
cargo tarpaulin --out Xml
swift test --package-path mac-ui --enable-code-coverage
```
