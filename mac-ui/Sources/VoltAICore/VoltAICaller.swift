import Foundation
import Darwin

/// Describes the current state of the local Ollama installation.
public enum OllamaStatus: Equatable {
    /// The `ollama` binary could not be found at any known path.
    case notInstalled
    /// The binary exists but `ollama list` exited non-zero — daemon is likely not running.
    case notRunning
    /// Daemon is running but no models are installed yet.
    case noModels
    /// Daemon is running and at least one model is available.
    case ready([String])
}

public enum VoltAICaller {

    // MARK: - voltai subprocess

    /// Runs a subprocess, captures output to temp files (avoids pipe buffer deadlocks),
    /// and returns stdout. Falls back to stderr with an exit code prefix when stdout is empty.
    /// Terminates the process after `timeout` seconds with a SIGTERM→SIGKILL escalation.
    static func runProcessAsync(
        launchPath: String, arguments: [String], timeout: TimeInterval = 600.0
    ) async -> String {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = arguments

            // Redirect stdout/stderr to temp files to avoid pipe buffer deadlocks.
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            let outURL = tmpDir.appendingPathComponent("voltai-out-\(UUID().uuidString).log")
            let errURL = tmpDir.appendingPathComponent("voltai-err-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: nil)
            let outHandleWrite = try? FileHandle(forWritingTo: outURL)
            let errHandleWrite = try? FileHandle(forWritingTo: errURL)
            if let o = outHandleWrite { p.standardOutput = o }
            if let e = errHandleWrite { p.standardError = e }

            // Ensure the continuation is resumed exactly once even if both the timeout
            // and the termination handler fire in close succession.
            var resumed = false
            let resumeQueue = DispatchQueue(label: "VoltAICaller.safeResume")
            let safeResume: @Sendable (String) -> Void = { s in
                resumeQueue.sync {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: s)
                    }
                }
            }

            do {
                try p.run()
            } catch {
                safeResume("failed to run: \(error)")
                return
            }

            // Timeout: graceful terminate first, then escalate to SIGKILL after 3 s.
            let timeoutWorkItem = DispatchWorkItem {
                if p.isRunning {
                    p.terminate()
                    let pidToKill = p.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                        if p.isRunning { kill(pidToKill, SIGKILL) }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            p.terminationHandler = { proc in
                timeoutWorkItem.cancel()
                if let o = outHandleWrite { try? o.close() }
                if let e = errHandleWrite { try? e.close() }
                let outData = (try? Data(contentsOf: outURL)) ?? Data()
                let errData = (try? Data(contentsOf: errURL)) ?? Data()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderrText = String(data: errData, encoding: .utf8) ?? ""
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)

                if stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var msg = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if msg.isEmpty { msg = "(no output)" }
                    let code = proc.terminationStatus
                    if code == 15 || code == 9 {
                        safeResume("[timeout] Process timed out after \(timeout) seconds")
                    } else {
                        safeResume("[process exit \(code)] \(msg)")
                    }
                } else {
                    safeResume(stdout)
                }
            }
        }
    }

    public static func index(dir: URL, out: URL) async -> String {
        let binary = locateVoltAIBinary()
        return await runProcessAsync(
            launchPath: binary,
            arguments: ["index", "-d", dir.path, "-o", out.path],
            timeout: 600.0)
    }

    public static func query(index: URL, q: String, k: Int, model: String?) async -> String {
        let binary = locateVoltAIBinary()
        var args = ["query", "-i", index.path, "-q", q, "-k", String(k)]
        if let m = model, !m.isEmpty { args.append(contentsOf: ["-m", m]) }
        return await runProcessAsync(launchPath: binary, arguments: args, timeout: 60.0)
    }

    // MARK: - Ollama discovery

    /// Returns the list of installed Ollama model names, or an empty array if Ollama is unavailable.
    public static func listOllamaModels() async -> [String] {
        if case .ready(let models) = await checkOllamaStatus() { return models }
        return []
    }

    /// Checks whether Ollama is installed, running, and has models available.
    public static func checkOllamaStatus() async -> OllamaStatus {
        guard let binary = locateOllamaBinary() else { return .notInstalled }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = ["list"]
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                    p.waitUntilExit()
                    guard p.terminationStatus == 0 else {
                        cont.resume(returning: .notRunning)
                        return
                    }
                    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let models = parseOllamaListOutput(s)
                    cont.resume(returning: models.isEmpty ? .noModels : .ready(models))
                } catch {
                    cont.resume(returning: .notRunning)
                }
            }
        }
    }

    /// Parses the text output of `ollama list` into model name strings.
    /// Pure function — no subprocess calls, directly unit-testable.
    public static func parseOllamaListOutput(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let name = line.split(separator: " ").first.map(String.init) ?? ""
            return (name.isEmpty || name.lowercased() == "name") ? nil : name
        }
    }

    /// Finds the `ollama` binary at known install paths. Returns nil if not found.
    private static func locateOllamaBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ollama",  // Apple Silicon Homebrew (M1/M2/M3)
            "/usr/local/bin/ollama",     // Intel Homebrew or manual install
            "/usr/bin/ollama",           // System package manager install
        ]
        return candidates.first { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && !isDir.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    // MARK: - voltai binary discovery

    /// Locates the compiled `voltai` Rust binary by checking bundle-relative and CWD-relative paths.
    public static func locateVoltAIBinary() -> String {
        // 1. Bundle-relative: navigate from the GUI executable up to the repo root,
        //    then down to target/release/voltai (matches `swift build` layout).
        if let bundleExe = Bundle.main.executableURL {
            let candidate = bundleExe
                .deletingLastPathComponent()  // debug/
                .deletingLastPathComponent()  // arm64-apple-macosx/
                .deletingLastPathComponent()  // .build/
                .deletingLastPathComponent()  // mac-ui/
                .appendingPathComponent("target/release/voltai")
                .path
            if isExecutableFile(atPath: candidate) { return candidate }
        }

        // 2. ../target/release/voltai relative to CWD (common dev path).
        let rel = FileManager.default.currentDirectoryPath + "/../target/release/voltai"
        if isExecutableFile(atPath: rel), !rel.contains("/.build/"),
            Bundle.main.executableURL?.path != rel
        {
            return rel
        }

        // 3. ./voltai in CWD.
        let cwd = FileManager.default.currentDirectoryPath + "/voltai"
        if isExecutableFile(atPath: cwd), !cwd.contains("/.build/"),
            Bundle.main.executableURL?.path != cwd
        {
            return cwd
        }

        // 4. Next to the GUI executable inside an .app bundle.
        if let bundleExe = Bundle.main.executableURL {
            let candidate = bundleExe.deletingLastPathComponent()
                .appendingPathComponent("voltai").path
            if candidate != bundleExe.path, isExecutableFile(atPath: candidate),
                !candidate.contains("/.build/")
            {
                return candidate
            }
        }

        // Fallback — will fail with a clear error message from the shell.
        return "./voltai"
    }

    /// Returns true if `path` names a regular executable file (not a directory or .app bundle).
    private static func isExecutableFile(atPath path: String) -> Bool {
        guard !path.hasSuffix(".app") else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
