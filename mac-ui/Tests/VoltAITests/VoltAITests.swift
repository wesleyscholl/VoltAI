import XCTest
@testable import VoltAICore

// MARK: - VoltAICaller.parseOllamaListOutput

final class ParseOllamaListOutputTests: XCTestCase {

    func test_emptyString_returnsEmptyArray() {
        XCTAssertEqual(VoltAICaller.parseOllamaListOutput(""), [])
    }

    func test_headerOnlyUppercase_returnsEmptyArray() {
        let header = "NAME              ID              SIZE    MODIFIED"
        XCTAssertEqual(VoltAICaller.parseOllamaListOutput(header), [])
    }

    func test_headerOnlyLowercase_returnsEmptyArray() {
        XCTAssertEqual(VoltAICaller.parseOllamaListOutput("name   id   size"), [])
    }

    func test_headerOnlyMixedCase_returnsEmptyArray() {
        XCTAssertEqual(VoltAICaller.parseOllamaListOutput("Name   ID   Size"), [])
    }

    func test_singleModel_returnsModelName() {
        let output = "NAME\nllama3.2:latest   abc123   2.0 GB   2 days ago"
        XCTAssertEqual(VoltAICaller.parseOllamaListOutput(output), ["llama3.2:latest"])
    }

    func test_multipleModels_returnsAllNames() {
        let output = """
        NAME
        llama3.2:latest   abc123   2.0 GB   2 days ago
        mistral:latest    def456   4.1 GB   5 days ago
        gemma3:1b         ghi789   1.3 GB   1 day ago
        """
        XCTAssertEqual(
            VoltAICaller.parseOllamaListOutput(output),
            ["llama3.2:latest", "mistral:latest", "gemma3:1b"]
        )
    }

    func test_trailingNewline_doesNotProduceSpuriousEntry() {
        let output = "NAME\nllama3.2:latest   abc123   2.0 GB   2 days ago\n"
        XCTAssertEqual(VoltAICaller.parseOllamaListOutput(output), ["llama3.2:latest"])
    }

    func test_modelNameWithNoSpaces_returnsThatName() {
        // A line that is just a model name with no spaces
        let output = "NAME\ncodellama"
        XCTAssertEqual(VoltAICaller.parseOllamaListOutput(output), ["codellama"])
    }

    func test_onlyNewlines_returnsEmptyArray() {
        XCTAssertEqual(VoltAICaller.parseOllamaListOutput("\n\n\n"), [])
    }

    func test_preservesOrder() {
        let output = "NAME\nalpha:v1   x\nbeta:v2   y\ngamma:v3   z"
        let result = VoltAICaller.parseOllamaListOutput(output)
        XCTAssertEqual(result, ["alpha:v1", "beta:v2", "gamma:v3"])
    }
}

// MARK: - VoltAICaller.locateVoltAIBinary

final class LocateVoltAIBinaryTests: XCTestCase {

    func test_returnsNonEmptyString() {
        let path = VoltAICaller.locateVoltAIBinary()
        XCTAssertFalse(path.isEmpty)
    }

    func test_endsWithVoltai() {
        // The binary is always named "voltai" — whether found or the fallback "./voltai"
        let path = VoltAICaller.locateVoltAIBinary()
        XCTAssertTrue(path.hasSuffix("voltai"), "Expected path ending in 'voltai', got '\(path)'")
    }

    func test_doesNotHaveAppSuffix() {
        // isExecutableFile guards against .app bundles; the return value must never be an
        // .app path.
        let path = VoltAICaller.locateVoltAIBinary()
        XCTAssertFalse(path.hasSuffix(".app"))
    }
}

// MARK: - VoltAIViewModel.selectPreferredModel

final class SelectPreferredModelTests: XCTestCase {

    func test_emptyList_returnsNil() {
        XCTAssertNil(VoltAIViewModel.selectPreferredModel(from: []))
    }

    func test_singleNonPreferred_returnsThatModel() {
        XCTAssertEqual(
            VoltAIViewModel.selectPreferredModel(from: ["mycustom:latest"]),
            "mycustom:latest"
        )
    }

    func test_preferredModelPresent_returnsPreferred() {
        let models = ["gemma3:1b", "random:model"]
        XCTAssertEqual(VoltAIViewModel.selectPreferredModel(from: models), "gemma3:1b")
    }

    func test_noPreferredModelInList_returnsFirstElement() {
        let models = ["exotic:model", "another:one"]
        XCTAssertEqual(VoltAIViewModel.selectPreferredModel(from: models), "exotic:model")
    }

    func test_llama2Beats_gemma3_1b() {
        // llama2:1b is first in the preference list; gemma3:1b is third
        let models = ["gemma3:1b", "llama2:1b"]
        XCTAssertEqual(VoltAIViewModel.selectPreferredModel(from: models), "llama2:1b")
    }

    func test_gemma3_1bBeats_gemma3_4b() {
        let models = ["gemma3:4b", "gemma3:1b"]
        XCTAssertEqual(VoltAIViewModel.selectPreferredModel(from: models), "gemma3:1b")
    }

    func test_gemma3_4bBeats_mistral() {
        let models = ["mistral:latest", "gemma3:4b"]
        XCTAssertEqual(VoltAIViewModel.selectPreferredModel(from: models), "gemma3:4b")
    }

    func test_mistralBeats_llama3_2() {
        let models = ["llama3.2:latest", "mistral:latest"]
        XCTAssertEqual(VoltAIViewModel.selectPreferredModel(from: models), "mistral:latest")
    }

    func test_allPreferredPresent_returnsHighestRanked() {
        let models = ["llama3.2:latest", "mistral:latest", "gemma3:4b", "gemma3:1b", "llama2:1b"]
        XCTAssertEqual(VoltAIViewModel.selectPreferredModel(from: models), "llama2:1b")
    }
}

// MARK: - VoltAIViewModel.loadDocsFromIndexFile

@MainActor
final class LoadDocsFromIndexFileTests: XCTestCase {

    private func writeTempIndex(_ index: Index) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltai_test_\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(index)
        try data.write(to: url)
        return url
    }

    func test_validSmallIndex_returnsAllDocs() throws {
        let docs = (0..<5).map { Doc(id: "\($0)", path: "/p\($0).txt", text: "short text") }
        let url = try writeTempIndex(Index(docs: docs, terms: ["short", "text"], vectors: []))
        let result = try VoltAIViewModel().loadDocsFromIndexFile(url)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[0].id, "0")
        XCTAssertEqual(result[4].id, "4")
    }

    func test_moreThanTenDocs_capsAtTen() throws {
        let docs = (0..<15).map { Doc(id: "\($0)", path: "/p\($0).txt", text: "text") }
        let url = try writeTempIndex(Index(docs: docs, terms: ["text"], vectors: []))
        let result = try VoltAIViewModel().loadDocsFromIndexFile(url)
        XCTAssertEqual(result.count, 10)
    }

    func test_longText_truncatedAtHundredChars() throws {
        let longText = String(repeating: "x", count: 200)
        let docs = [Doc(id: "1", path: "/p.txt", text: longText)]
        let url = try writeTempIndex(Index(docs: docs, terms: [], vectors: []))
        let result = try VoltAIViewModel().loadDocsFromIndexFile(url)
        let expected = String(repeating: "x", count: 100) + "…"
        XCTAssertEqual(result[0].text, expected)
    }

    func test_textExactly100Chars_notTruncated() throws {
        let exactText = String(repeating: "b", count: 100)
        let docs = [Doc(id: "1", path: "/p.txt", text: exactText)]
        let url = try writeTempIndex(Index(docs: docs, terms: [], vectors: []))
        let result = try VoltAIViewModel().loadDocsFromIndexFile(url)
        XCTAssertEqual(result[0].text, exactText)
    }

    func test_text99Chars_notTruncated() throws {
        let text99 = String(repeating: "c", count: 99)
        let docs = [Doc(id: "1", path: "/p.txt", text: text99)]
        let url = try writeTempIndex(Index(docs: docs, terms: [], vectors: []))
        let result = try VoltAIViewModel().loadDocsFromIndexFile(url)
        XCTAssertEqual(result[0].text, text99)
    }

    func test_emptyIndex_returnsEmptyArray() throws {
        let url = try writeTempIndex(Index(docs: [], terms: [], vectors: []))
        let result = try VoltAIViewModel().loadDocsFromIndexFile(url)
        XCTAssertTrue(result.isEmpty)
    }

    func test_invalidJSON_throws() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltai_bad_\(UUID().uuidString).json")
        try "not valid json {{{{".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try VoltAIViewModel().loadDocsFromIndexFile(url))
    }

    func test_missingFile_throws() {
        let missing = URL(fileURLWithPath: "/tmp/voltai_nonexistent_\(UUID().uuidString).json")
        XCTAssertThrowsError(try VoltAIViewModel().loadDocsFromIndexFile(missing))
    }

    func test_docPathAndIdPreserved() throws {
        let docs = [Doc(id: "doc-abc", path: "/my/docs/file.md", text: "hello")]
        let url = try writeTempIndex(Index(docs: docs, terms: ["hello"], vectors: [[1.0]]))
        let result = try VoltAIViewModel().loadDocsFromIndexFile(url)
        XCTAssertEqual(result[0].path, "/my/docs/file.md")
        XCTAssertEqual(result[0].id, "doc-abc")
    }
}

// MARK: - VoltAIViewModel state and synchronous behaviour

@MainActor
final class VoltAIViewModelStateTests: XCTestCase {

    func test_initialMessages_containsSystemMessage() {
        let vm = VoltAIViewModel()
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages[0].role, "system")
    }

    func test_initialState_fieldsAreDefaultValues() {
        let vm = VoltAIViewModel()
        XCTAssertFalse(vm.isIndexing)
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.input.isEmpty)
        XCTAssertTrue(vm.indexedDocs.isEmpty)
        XCTAssertNil(vm.lastError)
        XCTAssertTrue(vm.statusText.isEmpty)
        XCTAssertTrue(vm.availableModels.isEmpty)
        XCTAssertNil(vm.selectedModel)
    }

    func test_sendQuery_emptyInput_doesNotAppendMessage() {
        let vm = VoltAIViewModel()
        let before = vm.messages.count
        vm.input = ""
        vm.sendQuery()
        XCTAssertEqual(vm.messages.count, before)
        XCTAssertFalse(vm.isLoading)
    }

    func test_sendQuery_whitespaceOnlyInput_doesNotAppendMessage() {
        let vm = VoltAIViewModel()
        let before = vm.messages.count
        vm.input = "   \t\n  "
        vm.sendQuery()
        XCTAssertEqual(vm.messages.count, before)
        XCTAssertFalse(vm.isLoading)
    }

    func test_sendQuery_nonEmptyInput_appendsUserMessage() {
        let vm = VoltAIViewModel()
        vm.input = "What is VoltAI?"
        vm.sendQuery()
        XCTAssertTrue(vm.messages.contains { $0.role == "user" && $0.text == "What is VoltAI?" })
    }

    func test_sendQuery_clearsInputAfterSend() {
        let vm = VoltAIViewModel()
        vm.input = "some query"
        vm.sendQuery()
        XCTAssertTrue(vm.input.isEmpty)
    }

    func test_sendQuery_setsIsLoading() {
        let vm = VoltAIViewModel()
        vm.input = "test question"
        vm.sendQuery()
        XCTAssertTrue(vm.isLoading)
    }

    func test_sendQuery_setsStatusText() {
        let vm = VoltAIViewModel()
        vm.input = "test question"
        vm.sendQuery()
        XCTAssertFalse(vm.statusText.isEmpty)
    }

    func test_cancelIndexing_withNoActiveTask_doesNotCrash() {
        let vm = VoltAIViewModel()
        // Must not crash when called before any indexing starts
        vm.cancelIndexing()
    }

    func test_cancelIndexing_calledTwice_doesNotCrash() {
        let vm = VoltAIViewModel()
        vm.cancelIndexing()
        vm.cancelIndexing()
    }

    func test_aborted_initiallyFalse() {
        let vm = VoltAIViewModel()
        XCTAssertFalse(vm.aborted)
    }

    func test_selectedDoc_initiallyNil() {
        let vm = VoltAIViewModel()
        XCTAssertNil(vm.selectedDoc)
    }

    func test_selectedDoc_canBeSetAndCleared() {
        let vm = VoltAIViewModel()
        let doc = Doc(id: "1", path: "/tmp/test.txt", text: "hello")
        vm.selectedDoc = doc
        XCTAssertEqual(vm.selectedDoc?.id, "1")
        vm.selectedDoc = nil
        XCTAssertNil(vm.selectedDoc)
    }
}

// MARK: - VoltAIViewModel result count

@MainActor
final class ResultCountTests: XCTestCase {

    func test_resultCount_defaultIsFive() {
        // Clear any persisted value from previous test runs.
        UserDefaults.standard.removeObject(forKey: "resultCount")
        let vm = VoltAIViewModel(caller: MockVoltAICaller())
        XCTAssertEqual(vm.resultCount, 5)
    }

    func test_sendQuery_usesResultCount() async {
        defer { UserDefaults.standard.removeObject(forKey: "resultCount") }
        let mock = MockVoltAICaller()
        let vm = VoltAIViewModel(caller: mock)
        vm.resultCount = 7
        vm.input = "what is BM25?"
        vm.sendQuery()
        await waitForTasks()

        XCTAssertEqual(mock.queryCallCount, 1)
        XCTAssertEqual(mock.lastQuery?.k, 7)
    }

    func test_resultCount_withinBounds() {
        defer { UserDefaults.standard.removeObject(forKey: "resultCount") }
        let mock = MockVoltAICaller()
        let vm = VoltAIViewModel(caller: mock)
        vm.resultCount = 1
        XCTAssertEqual(vm.resultCount, 1)
        vm.resultCount = 20
        XCTAssertEqual(vm.resultCount, 20)
    }
}

// MARK: - ChatMessage

final class ChatMessageTests: XCTestCase {

    func test_twoInstances_haveUniqueIds() {
        let m1 = ChatMessage(role: "user", text: "hi")
        let m2 = ChatMessage(role: "user", text: "hi")
        XCTAssertNotEqual(m1.id, m2.id)
    }

    func test_explicitId_preservedOnInit() {
        let fixedId = UUID()
        let m = ChatMessage(id: fixedId, role: "user", text: "hello")
        XCTAssertEqual(m.id, fixedId)
    }

    func test_properties_matchInitArguments() {
        let m = ChatMessage(role: "assistant", text: "I'm VoltAI")
        XCTAssertEqual(m.role, "assistant")
        XCTAssertEqual(m.text, "I'm VoltAI")
    }

    func test_codableRoundTrip() throws {
        let original = ChatMessage(role: "assistant", text: "Hello, world!")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.text, original.text)
    }

    func test_differentRoles_encodedAndDecoded() throws {
        for role in ["user", "assistant", "system"] {
            let m = ChatMessage(role: role, text: "test")
            let data = try JSONEncoder().encode(m)
            let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
            XCTAssertEqual(decoded.role, role)
        }
    }
}

// MARK: - Doc

final class DocTests: XCTestCase {

    func test_properties_matchInitArguments() {
        let d = Doc(id: "doc-1", path: "/path/to/file.txt", text: "sample content")
        XCTAssertEqual(d.id, "doc-1")
        XCTAssertEqual(d.path, "/path/to/file.txt")
        XCTAssertEqual(d.text, "sample content")
    }

    func test_codableRoundTrip() throws {
        let original = Doc(id: "doc-42", path: "/docs/notes.md", text: "content here")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Doc.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.path, original.path)
        XCTAssertEqual(decoded.text, original.text)
    }

    func test_identifiable_idMatchesDocId() {
        let d = Doc(id: "my-id", path: "/f.txt", text: "t")
        XCTAssertEqual(d.id, "my-id")
    }
}

// MARK: - Index

final class IndexTests: XCTestCase {

    func test_init_fieldsMatchArguments() {
        let docs = [Doc(id: "1", path: "/a.txt", text: "alpha")]
        let terms = ["alpha", "beta"]
        let vectors: [[Float]] = [[0.1, 0.9], [0.5, 0.5]]
        let index = Index(docs: docs, terms: terms, vectors: vectors)
        XCTAssertEqual(index.docs.count, 1)
        XCTAssertEqual(index.terms, ["alpha", "beta"])
        XCTAssertEqual(index.vectors, [[0.1, 0.9], [0.5, 0.5]])
    }

    func test_codableRoundTrip() throws {
        let docs = [Doc(id: "1", path: "/a.txt", text: "alpha")]
        let original = Index(docs: docs, terms: ["alpha"], vectors: [[0.5, 0.5]])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Index.self, from: data)
        XCTAssertEqual(decoded.docs.count, 1)
        XCTAssertEqual(decoded.docs[0].id, "1")
        XCTAssertEqual(decoded.terms, ["alpha"])
        XCTAssertEqual(decoded.vectors, [[0.5, 0.5]])
    }

    func test_emptyIndex_codableRoundTrip() throws {
        let original = Index(docs: [], terms: [], vectors: [])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Index.self, from: data)
        XCTAssertTrue(decoded.docs.isEmpty)
        XCTAssertTrue(decoded.terms.isEmpty)
        XCTAssertTrue(decoded.vectors.isEmpty)
    }
}

// MARK: - OllamaStatus

final class OllamaStatusTests: XCTestCase {

    func test_notInstalled_equalsItself() {
        XCTAssertEqual(OllamaStatus.notInstalled, OllamaStatus.notInstalled)
    }

    func test_notRunning_equalsItself() {
        XCTAssertEqual(OllamaStatus.notRunning, OllamaStatus.notRunning)
    }

    func test_noModels_equalsItself() {
        XCTAssertEqual(OllamaStatus.noModels, OllamaStatus.noModels)
    }

    func test_readyWithSameModels_equal() {
        XCTAssertEqual(OllamaStatus.ready(["llama3.2"]), OllamaStatus.ready(["llama3.2"]))
    }

    func test_readyWithDifferentModels_notEqual() {
        XCTAssertNotEqual(OllamaStatus.ready(["llama3.2"]), OllamaStatus.ready(["mistral"]))
    }

    func test_readyWithEmptyModels_equalsItself() {
        XCTAssertEqual(OllamaStatus.ready([]), OllamaStatus.ready([]))
    }

    func test_differentCases_notEqual() {
        XCTAssertNotEqual(OllamaStatus.notInstalled, OllamaStatus.notRunning)
        XCTAssertNotEqual(OllamaStatus.notInstalled, OllamaStatus.noModels)
        XCTAssertNotEqual(OllamaStatus.notRunning, OllamaStatus.noModels)
        XCTAssertNotEqual(OllamaStatus.notRunning, OllamaStatus.ready([]))
        XCTAssertNotEqual(OllamaStatus.noModels, OllamaStatus.ready([]))
    }

    func test_allCasesEqualThemselves() {
        let cases: [OllamaStatus] = [
            .notInstalled, .notRunning, .noModels, .ready([]), .ready(["m:v"]),
        ]
        for s in cases {
            XCTAssertEqual(s, s)
        }
    }
}

// MARK: - Helpers

/// Suspends the current task for 150 ms, releasing the main actor so that any
/// unstructured Tasks spawned inside VoltAIViewModel have time to run to completion.
/// Works reliably with immediately-returning MockVoltAICaller instances.
private func waitForTasks() async {
    try? await Task.sleep(nanoseconds: 150_000_000)
}

// MARK: - VoltAIViewModel.sendQuery async paths

@MainActor
final class SendQueryAsyncTests: XCTestCase {

    func test_normalResponse_appendsAssistantMessage() async {
        let mock = MockVoltAICaller()
        mock.queryResultToReturn = "Here is your answer."
        let vm = VoltAIViewModel(caller: mock)
        vm.input = "what is search?"
        vm.sendQuery()
        await waitForTasks()

        XCTAssertEqual(mock.queryCallCount, 1)
        XCTAssertEqual(vm.messages.last?.role, "assistant")
        XCTAssertEqual(vm.messages.last?.text, "Here is your answer.")
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.statusText.isEmpty)
    }

    func test_missingIndexResponse_appendsCannedMessage_noLastError() async {
        let mock = MockVoltAICaller()
        mock.queryResultToReturn = "Error: index file does not exist at path"
        let vm = VoltAIViewModel(caller: mock)
        vm.input = "find my notes"
        vm.sendQuery()
        await waitForTasks()

        XCTAssertNil(vm.lastError, "missing-index should not set lastError")
        XCTAssertTrue(
            vm.messages.last?.text.contains("don't have any indexed documents") == true,
            "expected canned missing-index message, got: \(vm.messages.last?.text ?? "(nil)")")
    }

    func test_timeoutResponse_appendsCannedTimeoutMessage() async {
        let mock = MockVoltAICaller()
        mock.queryResultToReturn = "[timeout] Process timed out after 60 seconds"
        let vm = VoltAIViewModel(caller: mock)
        vm.input = "slow query"
        vm.sendQuery()
        await waitForTasks()

        XCTAssertTrue(
            vm.messages.last?.text.contains("timed out") == true,
            "expected timeout message, got: \(vm.messages.last?.text ?? "(nil)")")
    }

    func test_ollamaUnavailableResponse_setsStatusNotRunning() async {
        let mock = MockVoltAICaller()
        mock.queryResultToReturn = "connection refused while trying to connect"
        let vm = VoltAIViewModel(caller: mock)
        vm.input = "hello"
        vm.sendQuery()
        await waitForTasks()

        XCTAssertEqual(vm.ollamaStatus, .notRunning)
        XCTAssertTrue(
            vm.messages.last?.text.contains("Ollama is not responding") == true,
            "expected Ollama-unavailable message, got: \(vm.messages.last?.text ?? "(nil)")")
    }

    func test_forwardsQueryArgsToCallerCorrectly() async {
        let mock = MockVoltAICaller()
        let vm = VoltAIViewModel(caller: mock)
        vm.selectedModel = "gemma3:4b"
        vm.resultCount = 5   // explicit — independent of UserDefaults state
        vm.input = "distributed systems"
        vm.sendQuery()
        await waitForTasks()

        XCTAssertEqual(mock.queryCallCount, 1)
        XCTAssertEqual(mock.lastQuery?.q, "distributed systems")
        XCTAssertEqual(mock.lastQuery?.k, 5)
        XCTAssertEqual(mock.lastQuery?.model, "gemma3:4b")
    }

}

// MARK: - VoltAIViewModel.init async Ollama check

@MainActor
final class InitOllamaCheckTests: XCTestCase {

    func test_notInstalledStatus_leavesOllamaStatusNotInstalled() async {
        let mock = MockVoltAICaller()
        mock.statusToReturn = .notInstalled
        let vm = VoltAIViewModel(caller: mock)
        await waitForTasks()

        XCTAssertEqual(vm.ollamaStatus, .notInstalled)
        XCTAssertTrue(vm.availableModels.isEmpty)
        XCTAssertNil(vm.selectedModel)
        XCTAssertEqual(mock.checkStatusCallCount, 1)
    }

    func test_readyStatus_populatesModelsAndSelectsPreferred() async {
        let mock = MockVoltAICaller()
        mock.statusToReturn = .ready(["gemma3:1b", "random:model"])
        let vm = VoltAIViewModel(caller: mock)
        await waitForTasks()

        XCTAssertEqual(vm.ollamaStatus, .ready(["gemma3:1b", "random:model"]))
        XCTAssertEqual(vm.availableModels, ["gemma3:1b", "random:model"])
        XCTAssertEqual(vm.selectedModel, "gemma3:1b", "gemma3:1b is higher-ranked than random:model")
    }

    func test_noModelsStatus_leavesAvailableModelsEmpty() async {
        let mock = MockVoltAICaller()
        mock.statusToReturn = .noModels
        let vm = VoltAIViewModel(caller: mock)
        await waitForTasks()

        XCTAssertEqual(vm.ollamaStatus, .noModels)
        XCTAssertTrue(vm.availableModels.isEmpty)
        XCTAssertNil(vm.selectedModel)
    }
}

// MARK: - VoltAIViewModel cancellation path

@MainActor
final class CancellationTests: XCTestCase {

    func test_cancelIndexing_whileRunning_setsIsIndexingFalseAndCancelledMessage() async throws {
        let mock = MockVoltAICaller()
        let vm = VoltAIViewModel(caller: mock)

        // Create a real (but empty) temp directory so the ViewModel adds it to pathsToIndex.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltai-test-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Start indexing, then immediately cancel before the unstructured Task can start.
        vm.index(paths: [tmpDir])
        XCTAssertTrue(vm.isIndexing, "isIndexing should be true immediately after index(paths:)")
        vm.cancelIndexing()

        // Allow the now-cancelled Task to run and drain.
        await waitForTasks()

        XCTAssertFalse(vm.isIndexing, "isIndexing should be false after cancellation")
        XCTAssertEqual(vm.progressMessage, "Indexing cancelled")
    }
}
