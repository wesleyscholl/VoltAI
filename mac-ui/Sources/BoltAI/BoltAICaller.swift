import Foundation

enum BoltAICaller {
    static func runProcess(launchPath: String, arguments: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        do {
            try p.run()
        } catch {
            return "failed to run: \(error)"
        }
        p.waitUntilExit()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        // If stdout is empty but stderr has content, return stderr so caller can see errors
        if stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.isEmpty {
                msg = "(no output)"
            }
            let code = p.terminationStatus
            return "[process exit \(code)] \(msg)"
        }

        return stdout
    }

    static func index(dir: URL, out: URL) -> String {
        let binary = locateBoltAIBinary()
        fputs("[BoltAICaller] launching binary: \(binary)\n", stderr)
        return runProcess(launchPath: binary, arguments: ["index", "-d", dir.path, "-o", out.path])
    }

    static func query(index: URL, q: String, k: Int) -> String {
        let binary = locateBoltAIBinary()
        fputs("[BoltAICaller] launching binary: \(binary)\n", stderr)
        return runProcess(launchPath: binary, arguments: ["query", "-i", index.path, "-q", q, "-k", String(k)])
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
