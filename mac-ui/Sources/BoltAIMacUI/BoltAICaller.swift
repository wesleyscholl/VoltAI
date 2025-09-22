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

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        return s
    }

    static func index(dir: URL, out: URL) -> String {
        let binary = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("boltai").path ?? "./boltai"
        return runProcess(launchPath: binary, arguments: ["index", "-d", dir.path, "-o", out.path])
    }

    static func query(index: URL, q: String, k: Int) -> String {
        let binary = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("boltai").path ?? "./boltai"
        return runProcess(launchPath: binary, arguments: ["query", "-i", index.path, "-q", q, "-k", String(k)])
    }
}
