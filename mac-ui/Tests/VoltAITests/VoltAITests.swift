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
