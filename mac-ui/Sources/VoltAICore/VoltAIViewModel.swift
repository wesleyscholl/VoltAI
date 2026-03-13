import Foundation
import Combine
import SwiftUI
import AppKit

@MainActor
public final class VoltAIViewModel: ObservableObject {
    @Published public var messages: [ChatMessage] = [
        ChatMessage(role: "system", text: "VoltAI local agent ready.")
    ]
    @Published public var input: String = ""
    @Published public var isIndexing: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var progressMessage: String = ""
    @Published public var indexedDocs: [Doc] = []
    @Published public var lastError: String? = nil
    @Published public var isLoading: Bool = false
    @Published public var statusText: String = ""
    @Published public var availableModels: [String] = []
    @Published public var selectedModel: String? = nil
    @Published public var ollamaStatus: OllamaStatus = .notInstalled
    @Published public var resultCount: Int = {
        let v = UserDefaults.standard.integer(forKey: "resultCount")
        return v > 0 ? v : 5
    }() {
        didSet { UserDefaults.standard.set(resultCount, forKey: "resultCount") }
    }
    @Published public var selectedDoc: Doc? = nil

    private let caller: any VoltAICallerProtocol
    private var currentTask: Task<Void, Never>? = nil
    public var aborted = false

    public init(caller: any VoltAICallerProtocol = DefaultVoltAICaller()) {
        self.caller = caller
        // Inherits @MainActor context — no `await MainActor.run` needed inside.
        Task { [weak self] in
            guard let self else { return }
            let status = await self.caller.checkOllamaStatus()
            self.ollamaStatus = status
            if case .ready(let models) = status {
                self.availableModels = models
                if self.selectedModel == nil {
                    self.selectedModel = Self.selectPreferredModel(from: models)
                }
            }
        }
    }

    /// Picks a preferred model from the available list, falling back to the first available.
    public nonisolated static func selectPreferredModel(from models: [String]) -> String? {
        let preferred = ["llama2:1b", "gemma3:1b", "gemma3:4b", "mistral:latest", "llama3.2:latest"]
        for p in preferred {
            if models.contains(p) { return p }
        }
        return models.first
    }

    public func sendQuery() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        messages.append(ChatMessage(role: "user", text: q))
        input = ""
        isLoading = true
        statusText = "Thinking..."

        // Unstructured task inherits @MainActor context — no MainActor.run wrappers needed.
        Task(priority: .userInitiated) { [weak self, q] in
            guard let self else { return }
            self.statusText = "Generating response..."
            let indexPath = FileManager.default.currentDirectoryPath + "/../voltai_index.json"
            let res = await self.caller.query(
                index: URL(fileURLWithPath: indexPath), q: q, k: self.resultCount, model: self.selectedModel)

            let lower = res.lowercased()
            let isMissingIndex = lower.contains("index file") || lower.contains("does not exist")
            let isTimeout = lower.contains("[timeout]")
            let isOllamaUnavailable = lower.contains("connection refused")
                || lower.contains("failed to connect")
                || lower.contains("could not connect")
                || (lower.contains("[process exit") && lower.contains("ollama"))

            if isMissingIndex {
                // No index yet — give a helpful prompt rather than a raw error.
                let fallback =
                    "I don't have any indexed documents yet. To get document-aware answers, open the Index tab and add files. Meanwhile, here's your question echoed: \(q)"
                self.messages.append(ChatMessage(role: "assistant", text: fallback))
                // Do not set lastError for missing index; keep lastError for actionable errors only.
            } else if isTimeout {
                let fallback =
                    "The query timed out. The AI model may be slow or unavailable. Try again or check your Ollama setup."
                self.messages.append(ChatMessage(role: "assistant", text: fallback))
            } else if isOllamaUnavailable {
                let fallback =
                    "Ollama is not responding. Make sure it is running: open Terminal and run `ollama serve`, then try again."
                self.messages.append(ChatMessage(role: "assistant", text: fallback))
                self.ollamaStatus = .notRunning
            } else {
                self.messages.append(ChatMessage(role: "assistant", text: res))
            }
            self.statusText = ""
            self.isLoading = false
        }
    }

    public func index(paths: [URL]) {
        let pathsToIndex: [URL]
        if paths.isEmpty {
            let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("../docs")
            if !FileManager.default.fileExists(atPath: fallback.path) {
                // Write an empty index so queries return a helpful fallback instead of crashing.
                let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("../voltai_index.json")
                let emptyIndex = Index(docs: [], terms: [], vectors: [])
                if let data = try? JSONEncoder().encode(emptyIndex) {
                    try? data.write(to: outURL)
                } else {
                    self.lastError = "Could not create fallback empty index at \(outURL.path)"
                    return
                }
            }
            pathsToIndex = [fallback]
        } else {
            var dirs: [URL] = []
            var filesToCopy: [URL] = []
            let allowed = ["txt", "md", "csv", "json", "pdf"]
            for p in paths {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        dirs.append(p)
                    } else if allowed.contains(p.pathExtension.lowercased()) {
                        filesToCopy.append(p)
                    }
                }
            }

            if !filesToCopy.isEmpty {
                let tmpName = ".ui_index_tmp_\(UUID().uuidString)"
                let tmpURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(tmpName)
                do {
                    try FileManager.default.createDirectory(
                        at: tmpURL, withIntermediateDirectories: true, attributes: nil)
                    for f in filesToCopy {
                        let dest = tmpURL.appendingPathComponent(f.lastPathComponent)
                        if FileManager.default.fileExists(atPath: dest.path) {
                            try? FileManager.default.removeItem(at: dest)
                        }
                        try FileManager.default.copyItem(at: f, to: dest)
                    }
                    dirs.append(tmpURL)
                } catch {
                    self.lastError = "Failed to prepare temporary index folder: \(error)"
                    return
                }
            }

            pathsToIndex = dirs
        }

        isIndexing = true
        progress = 0.0
        progressMessage = "Preparing to index..."
        indexedDocs = []

        // Unstructured task inherits @MainActor context — all property mutations are safe.
        currentTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var createdIndexURL: URL? = nil

            for p in pathsToIndex {
                if Task.isCancelled { break }
                self.progressMessage = "Indexing \(p.lastPathComponent)"

                // Stable output path one level above the mac-ui working directory.
                let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("voltai_index.json")

                let res = await self.caller.index(dir: p, out: outURL)
                let lowerRes = res.lowercased()

                if lowerRes.contains("[timeout]") {
                    let dbg = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(
                            "voltai-index-debug-\(Int(Date().timeIntervalSince1970)).log")
                    try? res.write(to: dbg, atomically: true, encoding: .utf8)
                    self.lastError =
                        "Indexing timed out. The indexer was terminated before completion. See debug log: \(dbg.path)"
                    self.aborted = true
                    break
                }

                if FileManager.default.fileExists(atPath: outURL.path) {
                    // Sanity-check: a valid index is always larger than a few bytes.
                    if let attr = try? FileManager.default.attributesOfItem(atPath: outURL.path),
                        let size = attr[.size] as? UInt64, size < 10
                    {
                        let dbg = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(
                                "voltai-index-small-\(Int(Date().timeIntervalSince1970)).log")
                        try? res.write(to: dbg, atomically: true, encoding: .utf8)
                        self.lastError =
                            "Index file appears to be empty/truncated (size=\(size)). Raw output saved to: \(dbg.path)"
                        self.aborted = true
                        break
                    }
                    createdIndexURL = outURL
                    self.progress = 1.0
                    self.progressMessage = "Index created, loading documents..."
                    self.isIndexing = false
                    break
                } else {
                    let dbg = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(
                            "voltai-debug-\(Int(Date().timeIntervalSince1970)).log")
                    try? res.write(to: dbg, atomically: true, encoding: .utf8)
                    self.lastError =
                        "Indexer ran but no index file was created. Raw output saved to: \(dbg.path)"
                    continue
                }
            }

            // Load docs asynchronously from the produced index so the UI isn't blocked.
            if let idxURL = createdIndexURL, !Task.isCancelled && !self.aborted {
                Task(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    do {
                        let docs = try self.loadDocsFromIndexFile(idxURL)
                        self.indexedDocs = docs
                        self.progressMessage = "Indexing complete"
                        self.isIndexing = false
                        self.progress = 1.0
                        if let tmp = pathsToIndex.first(where: {
                            $0.lastPathComponent.hasPrefix(".ui_index_tmp_")
                        }) {
                            try? FileManager.default.removeItem(at: tmp)
                        }
                    } catch {
                        self.lastError = "Index created but failed to load: \(error)"
                    }
                }
                return
            }

            if !Task.isCancelled && !self.aborted {
                // Best-effort fallback: try candidate paths in case the index landed elsewhere.
                let candPaths = [
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .deletingLastPathComponent().appendingPathComponent("voltai_index.json"),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent("voltai_index.json"),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent("../voltai_index.json"),
                ]
                var loaded = false
                for cand in candPaths {
                    guard FileManager.default.fileExists(atPath: cand.path) else { continue }
                    // Retry up to 6 times to handle EOF races where the indexer hasn't flushed yet.
                    var didLoad = false
                    var lastErr: Error? = nil
                    for _ in 0..<6 {
                        do {
                            let docs = try self.loadDocsFromIndexFile(cand)
                            self.indexedDocs = docs
                            self.progressMessage = "Indexing complete"
                            self.isIndexing = false
                            self.progress = 1.0
                            didLoad = true
                            break
                        } catch {
                            lastErr = error
                            let msg = String(describing: error).lowercased()
                            if msg.contains("unexpected end of file")
                                || msg.contains("datacorrupted") || msg.contains("end of input")
                            {
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
                        self.lastError =
                            "Index created but failed to load: \(lastErr?.localizedDescription ?? "unknown error")"
                        break
                    }
                }

                if loaded {
                    if let tmp = pathsToIndex.first(where: {
                        $0.lastPathComponent.hasPrefix(".ui_index_tmp_")
                    }) {
                        try? FileManager.default.removeItem(at: tmp)
                    }
                    return
                }

                self.progressMessage = "Indexing complete (no documents loaded)"
                self.isIndexing = false
                self.progress = 1.0
            } else {
                self.progressMessage = "Indexing cancelled"
                self.isIndexing = false
            }
        }
    }

    public func cancelIndexing() {
        currentTask?.cancel()
    }
}

// MARK: - Supporting types

public struct ChatMessage: Identifiable, Codable {
    public var id = UUID()
    public let role: String
    public let text: String
    public init(id: UUID = UUID(), role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct Doc: Identifiable, Codable {
    public let id: String
    public let path: String
    public let text: String
}

/// Mirrors the JSON index file produced by the Rust CLI.
public struct Index: Codable {
    public let docs: [Doc]
    public let terms: [String]
    public let vectors: [[Float]]
    public init(docs: [Doc], terms: [String], vectors: [[Float]]) {
        self.docs = docs
        self.terms = terms
        self.vectors = vectors
    }
}

// MARK: - Index loading

extension VoltAIViewModel {
    /// Reads the index JSON, decodes it, and returns a capped preview of docs to avoid UI hangs
    /// on large indexes. Truncates document text to `maxText` characters.
    public nonisolated func loadDocsFromIndexFile(_ url: URL) throws -> [Doc] {
        let data = try Data(contentsOf: url)
        let index = try JSONDecoder().decode(Index.self, from: data)
        let maxDocs = 10
        let maxText = 100
        return index.docs.prefix(maxDocs).map { d in
            let truncated = d.text.count > maxText ? String(d.text.prefix(maxText)) + "…" : d.text
            return Doc(id: d.id, path: d.path, text: truncated)
        }
    }
}
