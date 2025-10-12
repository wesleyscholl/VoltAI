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

    private var currentTask: Task<Void, Never>? = nil

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
            // Call the asynchronous BoltAICaller which returns stdout or an error string
            let indexPath = FileManager.default.currentDirectoryPath + "/../boltai_index.json"
            let res = await BoltAICaller.query(index: URL(fileURLWithPath: indexPath), q: q, k: 5)
            // debug: log raw response (may include process exit and stderr info)
            fputs("[BoltAIViewModel] Raw response: \(res.prefix(200))\n", stderr)

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                // If the response indicates a missing index, don't show repeated alerts; instead provide
                // a helpful fallback response so the app works out-of-the-box.
                let lower = res.lowercased()
                let isMissingIndex = lower.contains("index file") || lower.contains("does not exist")
                if isMissingIndex {
                    // Fallback: give the user a helpful message and echo their question so UI remains useful
                    let fallback = "I don't have any indexed documents yet. To get document-aware answers, open the Index tab and add files. Meanwhile, here's your question echoed: \(q)"
                    self.messages.append(ChatMessage(role: "assistant", text: fallback))
                    // Do not set lastError for missing index; keep lastError for other, actionable errors
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
            pathsToIndex = paths
        }

        isIndexing = true
        progress = 0.0
        progressMessage = "Preparing to index..."
        indexedDocs = []

        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let total = pathsToIndex.count
            for (i, p) in pathsToIndex.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run { self.progressMessage = "Indexing \(p.lastPathComponent)" }
                let outPath = FileManager.default.currentDirectoryPath + "/../boltai_index.json"
                _ = await BoltAICaller.index(dir: p, out: URL(fileURLWithPath: outPath))
                // increment progress
                await MainActor.run {
                    self.progress = Double(i + 1) / Double(max(1, total))
                }
            }

            // After indexing, attempt to load the index file
            if !Task.isCancelled {
                // nothing placeholder removed; will load index file after loop
                // best-effort: try to read our index
                let f = FileManager.default.currentDirectoryPath + "/../boltai_index.json"
                if FileManager.default.fileExists(atPath: f) {
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: f)), let index = try? JSONDecoder().decode(Index.self, from: data) {
                        await MainActor.run {
                            self.indexedDocs = index.docs
                            self.progressMessage = "Indexing complete"
                            self.isIndexing = false
                            self.progress = 1.0
                        }
                        return
                    }
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
