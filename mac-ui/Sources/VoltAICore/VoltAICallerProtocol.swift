import Foundation

/// Abstraction over the process-launching calls that `VoltAIViewModel` makes.
///
/// Every method maps 1-to-1 to a static method on `VoltAICaller`.
/// The protocol exists solely to support dependency injection in unit tests:
/// `VoltAIViewModel.init(caller:)` accepts any conforming type, so tests can
/// pass a `MockVoltAICaller` instead of spawning real subprocesses.
public protocol VoltAICallerProtocol {
    func checkOllamaStatus() async -> OllamaStatus
    func index(dir: URL, out: URL) async -> String
    func query(index: URL, q: String, k: Int, model: String?) async -> String
}

/// Production implementation — thin wrapper that forwards every call to the
/// corresponding static method on `VoltAICaller`.
public struct DefaultVoltAICaller: VoltAICallerProtocol {
    public init() {}

    public func checkOllamaStatus() async -> OllamaStatus {
        await VoltAICaller.checkOllamaStatus()
    }

    public func index(dir: URL, out: URL) async -> String {
        await VoltAICaller.index(dir: dir, out: out)
    }

    public func query(index: URL, q: String, k: Int, model: String?) async -> String {
        await VoltAICaller.query(index: index, q: q, k: k, model: model)
    }
}
