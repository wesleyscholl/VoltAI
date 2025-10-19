import Foundation
import Darwin

enum BoltAICaller {
    static func runProcessAsync(launchPath: String, arguments: [String], timeout: TimeInterval = 600.0) async -> String {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = arguments

            // Redirect stdout/stderr to temporary files to avoid pipe buffer deadlocks
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            let outURL = tmpDir.appendingPathComponent("boltai-out-\(UUID().uuidString).log")
            let errURL = tmpDir.appendingPathComponent("boltai-err-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: nil)
            let outHandleWrite = try? FileHandle(forWritingTo: outURL)
            let errHandleWrite = try? FileHandle(forWritingTo: errURL)
            if let o = outHandleWrite { p.standardOutput = o }
            if let e = errHandleWrite { p.standardError = e }

            var resumed = false
            let resumeQueue = DispatchQueue(label: "BoltAICaller.safeResume")
            let safeResume: @Sendable (String) -> Void = { s in
                resumeQueue.sync {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: s)
                    }
                }
            }

            do {
                fputs("[BoltAICaller] runProcess: starting \(launchPath) args=\(arguments)\n", stderr)
                try p.run()
                fputs("[BoltAICaller] runProcess: started pid=\(p.processIdentifier)\n", stderr)
            } catch {
                safeResume("failed to run: \(error)")
                return
            }

            // schedule timeout: attempt graceful terminate, then escalate to kill
            let timeoutWorkItem = DispatchWorkItem {
                if p.isRunning {
                    // attempt graceful termination
                    fputs("[BoltAICaller] runProcess: timeout reached, terminating pid=\(p.processIdentifier)\n", stderr)
                    p.terminate()
                    // schedule kill after short grace period
                    let pidToKill = p.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                        if p.isRunning {
                            // force-kill via POSIX kill
                            fputs("[BoltAICaller] runProcess: force-killing pid=\(pidToKill)\n", stderr)
                            kill(pidToKill, SIGKILL)
                        }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            p.terminationHandler = { proc in
                // cancel timeout work if still pending
                timeoutWorkItem.cancel()

                fputs("[BoltAICaller] runProcess: terminationHandler called pid=\(proc.processIdentifier) status=\(proc.terminationStatus)\n", stderr)

                // Close write handles so file contents are flushed
                if let o = outHandleWrite { try? o.close() }
                if let e = errHandleWrite { try? e.close() }
                // Read files
                let outData = (try? Data(contentsOf: outURL)) ?? Data()
                let errData = (try? Data(contentsOf: errURL)) ?? Data()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                // cleanup temp files
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)

                if stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if msg.isEmpty { msg = "(no output)" }
                    let code = proc.terminationStatus
                    if code == 15 || code == 9 { // SIGTERM or SIGKILL
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

    static func index(dir: URL, out: URL) async -> String {
        let binary = locateBoltAIBinary()
        fputs("[BoltAICaller] launching binary: \(binary)\n", stderr)
        // Indexing can take a while for large folders; give a long timeout (10 minutes)
        return await runProcessAsync(launchPath: binary, arguments: ["index", "-d", dir.path, "-o", out.path], timeout: 600.0)
    }

    static func query(index: URL, q: String, k: Int) async -> String {
        let binary = locateBoltAIBinary()
        fputs("[BoltAICaller] launching binary: \(binary)\n", stderr)
        return await runProcessAsync(launchPath: binary, arguments: ["query", "-i", index.path, "-q", q, "-k", String(k)], timeout: 60.0)
    }

    static func query(index: URL, q: String, k: Int, model: String?) async -> String {
        let binary = locateBoltAIBinary()
        fputs("[BoltAICaller] launching binary: \(binary) (model: \(model ?? "auto"))\n", stderr)
        var args = ["query", "-i", index.path, "-q", q, "-k", String(k)]
        if let m = model, !m.isEmpty {
            args.append(contentsOf: ["-m", m])
        }
        return await runProcessAsync(launchPath: binary, arguments: args, timeout: 60.0)
    }

    // Return a list of installed ollama models (names) by parsing `ollama list` output.
    static func listOllamaModels() async -> [String] {
        // Try to run `ollama list` synchronously but off the main thread
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/local/bin/ollama")
                p.arguments = ["list"]
                let out = Pipe()
                p.standardOutput = out
                do {
                    try p.run()
                    p.waitUntilExit()
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    let s = String(data: outData, encoding: .utf8) ?? ""
                    var models: [String] = []
                    for line in s.split(separator: "\n") {
                        let parts = line.split(separator: " ").map({ String($0) })
                        if parts.count > 0 {
                            let name = parts[0]
                            // skip header lines or empty
                            if name.lowercased() == "name" { continue }
                            models.append(name)
                        }
                    }
                    cont.resume(returning: models)
                } catch {
                    cont.resume(returning: [])
                }
            }
        }
    }

    // Try a few reasonable locations for the boltai binary so the UI can find it during development
    static func locateBoltAIBinary() -> String {
        // First, try relative to the bundle: ../../../../target/release/boltai (from mac-ui/.build/.../ to BoltAI/target/release/)
        if let bundleExe = Bundle.main.executableURL {
            let rustFromBundle = bundleExe
                .deletingLastPathComponent() // debug
                .deletingLastPathComponent() // arm64-apple-macosx
                .deletingLastPathComponent() // .build
                .deletingLastPathComponent() // mac-ui
                .appendingPathComponent("target")
                .appendingPathComponent("release")
                .appendingPathComponent("boltai").path
            if isExecutableFile(atPath: rustFromBundle) {
                fputs("[BoltAICaller] selected binary: \(rustFromBundle)\n", stderr)
                return rustFromBundle
            }
        }

        // Prefer the Rust CLI built in ../target/release/boltai (common dev path)
        let relCandidate = FileManager.default.currentDirectoryPath + "/../target/release/boltai"
        if isExecutableFile(atPath: relCandidate) {
            // Skip candidates that live in the GUI's build directory to avoid launching the app
            if !relCandidate.contains("/.build/") {
                if let bundleExe = Bundle.main.executableURL?.path, bundleExe != relCandidate {
                    fputs("[BoltAICaller] selected binary: \(relCandidate)\n", stderr)
                    return relCandidate
                }
            }
        }

        // Next, prefer a local ./boltai (e.g., copied into the mac-ui folder)
        let cwdCandidate = FileManager.default.currentDirectoryPath + "/boltai"
        if isExecutableFile(atPath: cwdCandidate) {
            if !cwdCandidate.contains("/.build/") {
                if let bundleExe = Bundle.main.executableURL?.path, bundleExe != cwdCandidate {
                    fputs("[BoltAICaller] selected binary: \(cwdCandidate)\n", stderr)
                    return cwdCandidate
                }
            }
        }

        // Finally check next to the GUI executable (useful when bundled into an .app) but ensure
        // we don't accidentally try to execute an .app bundle or directory.
        if let bundleExe = Bundle.main.executableURL {
            let candidate = bundleExe.deletingLastPathComponent().appendingPathComponent("boltai").path
            // avoid returning the GUI executable or an .app bundle or anything in the GUI build folder
            if candidate != bundleExe.path && isExecutableFile(atPath: candidate) && !candidate.contains("/.build/") {
                fputs("[BoltAICaller] selected binary: \(candidate)\n", stderr)
                return candidate
            }
        }

        // Last resort: return ./boltai (likely to fail with clear error), keep for backwards compat
        let fallback = "./boltai"
        if isExecutableFile(atPath: fallback) && !fallback.contains("/.build/") {
            fputs("[BoltAICaller] selected binary: \(fallback)\n", stderr)
            return fallback
        }
        // As a very last fallback, return something that will fail clearly, not the GUI executable
        fputs("[BoltAICaller] no binary found, returning fallback\n", stderr)
        return fallback
    }

    // Helper that ensures the path exists, is not a directory, and is executable
    private static func isExecutableFile(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            // Don't treat .app bundles as a runnable CLI
            if path.hasSuffix(".app") { return false }
            return !isDir.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }
        return false
    }
}
