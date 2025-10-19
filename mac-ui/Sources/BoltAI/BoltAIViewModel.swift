import Foundation
import Combine
import SwiftUI
import AppKit

final class BoltAIViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = [ChatMessage(role: "system", text: "BoltAI local agent ready.")]
    @Published var input: String = ""
    @Published var isIndexing: Bool = false
    @Published var progress: Double = 0.0
    @Published var progressMessage: String = ""
    @Published var indexedDocs: [Doc] = []
    @Published var selectedDoc: Doc? = nil
    @Published var lastError: String? = nil
    @Published var isLoading: Bool = false
    @Published var statusText: String = ""
    @Published var availableModels: [String] = []
    @Published var selectedModel: String? = nil

    private var currentTask: Task<Void, Never>? = nil

    var aborted = false

    init() {
        Task {
            let models = await BoltAICaller.listOllamaModels()
            await MainActor.run {
                self.availableModels = models
                // If model list contains a fast gemma-like model prefer it
                if self.selectedModel == nil {
                    if models.contains("llama2:1b") { self.selectedModel = "llama2:1b" }
                    else if models.contains("gemma3:1b") { self.selectedModel = "gemma3:1b" }
                    else if models.contains("mistral:latest") { self.selectedModel = "mistral:latest" }
                }
            }
        }
    }

    func sendQuery() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // Debug: log user query append
        fputs("[BoltAIViewModel] Appending user message: \(q)\n", stderr)
        messages.append(ChatMessage(role: "user", text: q))
        input = ""
        isLoading = true
        statusText = "Thinking..."

        Task.detached(priority: .userInitiated) { [q] in
            await MainActor.run { self.statusText = "Generating response..." }
            fputs("[BoltAIViewModel] sending query: \(q)\n", stderr)
            // Call the asynchronous BoltAICaller which returns stdout or an error string
            let indexPath = FileManager.default.currentDirectoryPath + "/../boltai_index.json"
                let res = await BoltAICaller.query(index: URL(fileURLWithPath: indexPath), q: q, k: 5, model: self.selectedModel)
            fputs("[BoltAIViewModel] query response: \(res.prefix(200))\n", stderr)
            // debug: log raw response (may include process exit and stderr info)
            fputs("[BoltAIViewModel] Raw response: \(res.prefix(200))\n", stderr)

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                // If the response indicates a missing index, don't show repeated alerts; instead provide
                // a helpful fallback response so the app works out-of-the-box.
                let lower = res.lowercased()
                let isMissingIndex = lower.contains("index file") || lower.contains("does not exist")
                let isTimeout = lower.contains("[timeout]")
                if isMissingIndex {
                    // Fallback: give the user a helpful message and echo their question so UI remains useful
                    let fallback = "I don't have any indexed documents yet. To get document-aware answers, open the Index tab and add files. Meanwhile, here's your question echoed: \(q)"
                    self.messages.append(ChatMessage(role: "assistant", text: fallback))
                    // Do not set lastError for missing index; keep lastError for other, actionable errors
                } else if isTimeout {
                    let fallback = "The query timed out. The AI model may be slow or unavailable. Try again or check your Ollama setup."
                    self.messages.append(ChatMessage(role: "assistant", text: fallback))
                } else {
                    self.messages.append(ChatMessage(role: "assistant", text: res))
                }
                self.statusText = ""
                self.isLoading = false
            }
        }
    }

    func index(paths: [URL]) {
        // If no paths provided, fall back to a sensible default (./docs)
        let pathsToIndex: [URL]
        if paths.isEmpty {
            let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../docs")
            // If the fallback docs folder doesn't exist, surface an error to the UI and abort
            if !FileManager.default.fileExists(atPath: fallback.path) {
                // Create an empty index file so the UI has something to load and queries can run (returning helpful fallback answers)
                let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../boltai_index.json")
                let emptyIndex = Index(docs: [], terms: [], vectors: [])
                if let data = try? JSONEncoder().encode(emptyIndex) {
                    try? data.write(to: outURL)
                    fputs("[BoltAIViewModel] wrote empty index to \(outURL.path)\n", stderr)
                } else {
                    DispatchQueue.main.async { self.lastError = "Could not create fallback empty index at \(outURL.path)" }
                    return
                }
            }
            pathsToIndex = [fallback]
        } else {
            // If the user dropped files, we may need to package them into a temp directory
            var dirs: [URL] = []
            var filesToCopy: [URL] = []
            let allowed = ["txt", "md", "csv", "json", "pdf"];
            for p in paths {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        dirs.append(p)
                    } else {
                        let ext = p.pathExtension.lowercased()
                        if allowed.contains(ext) {
                            filesToCopy.append(p)
                        }
                    }
                }
            }

            if !filesToCopy.isEmpty {
                // create a temp folder under currentDirectoryPath
                let tmpName = ".ui_index_tmp_\(UUID().uuidString)"
                let tmpURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(tmpName)
                do {
                    try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true, attributes: nil)
                    for f in filesToCopy {
                        let dest = tmpURL.appendingPathComponent(f.lastPathComponent)
                        // copy the file (skip if already exists)
                        if FileManager.default.fileExists(atPath: dest.path) {
                            try? FileManager.default.removeItem(at: dest)
                        }
                        try FileManager.default.copyItem(at: f, to: dest)
                    }
                    dirs.append(tmpURL)
                } catch {
                    DispatchQueue.main.async { self.lastError = "Failed to prepare temporary index folder: \(error)" }
                    return
                }
            }

            pathsToIndex = dirs
        }

        isIndexing = true
        progress = 0.0
        progressMessage = "Preparing to index..."
        indexedDocs = []

        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            var createdIndexURL: URL? = nil
            for p in pathsToIndex {
                if Task.isCancelled { break }
                await MainActor.run { self.progressMessage = "Indexing \(p.lastPathComponent)" }
                // Use a stable out URL next to the repo root so the GUI can find it
                let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().appendingPathComponent("boltai_index.json")
                let res = await BoltAICaller.index(dir: p, out: outURL)
                fputs("[BoltAIViewModel] index result: \(res.prefix(400))\n", stderr)
                fputs("[BoltAIViewModel] expected outURL: \(outURL.path)\n", stderr)
                fputs("[BoltAIViewModel] checking if index file exists...\n", stderr)
                // If the process returned a failure indicator, surface it immediately
                let lowerRes = res.lowercased()
                let isTimeout = lowerRes.contains("[timeout]")
                if isTimeout {
                    // write raw output to debug file for inspection
                    let dbg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("boltai-index-debug-\(Int(Date().timeIntervalSince1970)).log")
                    try? res.write(to: dbg, atomically: true, encoding: .utf8)
                    await MainActor.run { self.lastError = "Indexing timed out. The indexer was terminated before completion. See debug log: \(dbg.path)"; self.aborted = true }
                    break
                }
                // Note: non-timeout failures are handled below when no index file is found;
                // we avoid duplicating the check here to prevent unreachable/duplicate logic.
                // If file was created, proceed to next path
                if FileManager.default.fileExists(atPath: outURL.path) {
                    fputs("[BoltAIViewModel] found index at \(outURL.path)\n", stderr)
                    // Quick sanity-check: try to read the file size — if it's suspiciously small, treat as likely truncated
                    if let attr = try? FileManager.default.attributesOfItem(atPath: outURL.path),
                       let size = attr[.size] as? UInt64 {
                        if size < 10 {
                            let dbg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("boltai-index-small-\(Int(Date().timeIntervalSince1970)).log")
                            try? res.write(to: dbg, atomically: true, encoding: .utf8)
                            await MainActor.run { self.lastError = "Index file appears to be empty/truncated (size=\(size)). Raw output saved to: \(dbg.path)"; self.aborted = true }
                            break
                        }
                    }
                    // record the created index and stop indexing loop; we'll load docs asynchronously
                    createdIndexURL = outURL
                    await MainActor.run {
                        self.progress = 1.0
                        self.progressMessage = "Index created, loading documents..."
                        self.isIndexing = false
                    }
                    // stop processing further paths; we only care about the produced index
                    break
                } else {
                    fputs("[BoltAIViewModel] index file not found after process. Will try alternate locations.\n", stderr)
                    // write raw output to debug file for inspection
                    let dbg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("boltai-debug-\(Int(Date().timeIntervalSince1970)).log")
                    try? res.write(to: dbg, atomically: true, encoding: .utf8)
                    await MainActor.run { self.lastError = "Indexer ran but no index file was created. Raw output saved to: \(dbg.path)" }
                    // try next path
                    continue
                }
                // progress is updated via progressMessage and on completion; skip per-iteration numeric update here
            }
            // After indexing loop: if an index file was created, load docs asynchronously (so UI isn't blocked)
            if let idxURL = createdIndexURL, !Task.isCancelled && !self.aborted {
                Task.detached(priority: .userInitiated) { [weak self] in
                    guard let self = self else { return }
                    fputs("[BoltAIViewModel] starting async doc load from \(idxURL.path)\n", stderr)
                    do {
                        let docs = try self.loadDocsFromIndexFile(idxURL)
                        fputs("[BoltAIViewModel] loaded \(docs.count) docs successfully\n", stderr)
                        await MainActor.run {
                            self.indexedDocs = docs
                            self.progressMessage = "Indexing complete"
                            self.isIndexing = false
                            self.progress = 1.0
                        }
                        // cleanup any temporary UI index folders we created earlier
                        if let tmp = pathsToIndex.first(where: { $0.lastPathComponent.hasPrefix(".ui_index_tmp_") }) {
                            try? FileManager.default.removeItem(at: tmp)
                        }
                        return
                    } catch {
                        fputs("[BoltAIViewModel] failed to read/parse index json at \(idxURL.path): \(error)\n", stderr)
                        await MainActor.run { self.lastError = "Index created but failed to load: \(error)" }
                    }
                }
            }

            // Skip fallback loading if we already started async load above
            if createdIndexURL != nil {
                return
            }

            if !Task.isCancelled && !self.aborted {
                // Best-effort: try to read our index
                let candPaths = [
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().appendingPathComponent("boltai_index.json"),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("boltai_index.json"),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../boltai_index.json")
                ]
                var loaded = false
                for cand in candPaths {
                    if FileManager.default.fileExists(atPath: cand.path) {
                        // Try a few times to allow the indexer to flush the file on disk (avoid EOF races).
                        // Instead of decoding the entire index (which contains large vectors), parse only the
                        // `docs` array so the UI can display indexed documents quickly.
                        var didLoad = false
                        var lastErr: Error? = nil
                        for _ in 0..<6 {
                            do {
                                let docs = try self.loadDocsFromIndexFile(cand)
                                await MainActor.run {
                                    self.indexedDocs = docs
                                    self.progressMessage = "Indexing complete"
                                    self.isIndexing = false
                                    self.progress = 1.0
                                }
                                didLoad = true
                                break
                            } catch {
                                lastErr = error
                                let msg = String(describing: error).lowercased()
                                if msg.contains("unexpected end of file") || msg.contains("datacorrupted") || msg.contains("end of input") {
                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                    continue
                                } else {
                                    break
                                }
                            }
                        }

                        if didLoad {
                            loaded = true
                            break
                        } else {
                            if let e = lastErr {
                                fputs("[BoltAIViewModel] failed to read/parse index json at \(cand.path): \(e)\n", stderr)
                                await MainActor.run { self.lastError = "Index created but failed to load: \(e)" }
                            } else {
                                await MainActor.run { self.lastError = "Index created but failed to load (unknown error)" }
                            }
                            break
                        }
                    }
                }

                if loaded {
                    // cleanup any temporary UI index folders we created earlier
                    if let tmp = pathsToIndex.first(where: { $0.lastPathComponent.hasPrefix(".ui_index_tmp_") }) {
                        try? FileManager.default.removeItem(at: tmp)
                    }
                    return
                }

                await MainActor.run {
                    self.progressMessage = "Indexing complete (no documents loaded)"
                    self.isIndexing = false
                    self.progress = 1.0
                }
            } else {
                await MainActor.run {
                    self.progressMessage = "Indexing cancelled"
                    self.isIndexing = false
                }
            }
        }
    }

    func cancelIndexing() {
        currentTask?.cancel()
    }
}

// Models used by the UI
struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let role: String
    let text: String
}

struct Doc: Identifiable, Codable {
    let id: String
    let path: String
    let text: String
}

// Index struct for decoding boltai JSON index
struct Index: Codable {
    let docs: [Doc]
    let terms: [String]
    let vectors: [[Float]]
}

extension BoltAIViewModel {
    // Read the index JSON file, decode it, and return a capped preview of docs to avoid UI hangs on large indexes.
    func loadDocsFromIndexFile(_ url: URL) throws -> [Doc] {
        fputs("[BoltAIViewModel] loading index from \(url.path)\n", stderr)
        let data = try Data(contentsOf: url)
        fputs("[BoltAIViewModel] loaded \(data.count) bytes\n", stderr)
        let index = try JSONDecoder().decode(Index.self, from: data)
        fputs("[BoltAIViewModel] decoded index with \(index.docs.count) docs\n", stderr)
        let maxDocs = 10
        let maxText = 100
        var docs: [Doc] = []
        for d in index.docs.prefix(maxDocs) {
            let truncated = d.text.count > maxText ? String(d.text.prefix(maxText)) + "…" : d.text
            docs.append(Doc(id: d.id, path: d.path, text: truncated))
        }
        fputs("[BoltAIViewModel] returning \(docs.count) docs\n", stderr)
        return docs
    }}
