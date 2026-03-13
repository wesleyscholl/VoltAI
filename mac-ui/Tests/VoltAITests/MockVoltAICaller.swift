import Foundation
@testable import VoltAICore

/// Test double for `VoltAICallerProtocol`.
///
/// Every method records the call and returns the pre-configured value.
/// Mark `@unchecked Sendable` because test code is single-threaded; no shared-state
/// concurrency issues arise in practice.
final class MockVoltAICaller: VoltAICallerProtocol, @unchecked Sendable {

    // MARK: - Configurable return values

    var statusToReturn: OllamaStatus = .notInstalled
    var queryResultToReturn: String = "Test answer from mock."
    var indexResultToReturn: String = "Wrote index to /tmp/voltai_index.json"

    // MARK: - Call tracking

    var checkStatusCallCount = 0
    var queryCallCount = 0
    var indexCallCount = 0

    var lastQuery: (index: URL, q: String, k: Int, model: String?)?
    var lastIndex: (dir: URL, out: URL)?

    // MARK: - VoltAICallerProtocol

    func checkOllamaStatus() async -> OllamaStatus {
        checkStatusCallCount += 1
        return statusToReturn
    }

    func query(index: URL, q: String, k: Int, model: String?) async -> String {
        queryCallCount += 1
        lastQuery = (index, q, k, model)
        return queryResultToReturn
    }

    func index(dir: URL, out: URL) async -> String {
        indexCallCount += 1
        lastIndex = (dir, out)
        return indexResultToReturn
    }
}
