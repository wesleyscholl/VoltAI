import Foundation
import Combine
import SwiftUI

final class BoltAIViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = [ChatMessage(role: "system", text: "BoltAI local agent ready.")]
    @Published var input: String = ""
    @Published var isIndexing: Bool = false
    @Published var progress: Double = 0.0
    @Published var progressMessage: String = ""
    @Published var indexedDocs: [Doc] = []
    @Published var selectedDoc: Doc? = nil

    private var currentTask: Task<Void, Never>? = nil

    func sendQuery() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        messages.append(ChatMessage(role: "user", text: q))
        input = ""

        Task.detached(priority: .userInitiated) {
            let res = BoltAICaller.query(index: URL(fileURLWithPath: "boltai_index.json"), q: q, k: 5)
            await MainActor.run {
                self.messages.append(ChatMessage(role: "assistant", text: res))
            }
        }
    }

    func index(paths: [URL]) {
        guard !paths.isEmpty else { return }
        isIndexing = true
        progress = 0.0
        progressMessage = "Preparing to index..."
        indexedDocs = []

        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let total = paths.count
            for (i, p) in paths.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run { self.progressMessage = "Indexing \(p.lastPathComponent)" }
                _ = BoltAICaller.index(dir: p, out: URL(fileURLWithPath: "boltai_index.json"))
                // increment progress
                await MainActor.run {
                    self.progress = Double(i + 1) / Double(max(1, total))
                }
            }

            // After indexing, attempt to load the index file
            if !Task.isCancelled {
                // nothing placeholder removed; will load index file after loop
                // best-effort: try to read our index
                let f = FileManager.default.currentDirectoryPath + "/boltai_index.json"
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
