import Foundation
import Testing
@testable import VibeMenuCore

// End-to-end test of the real Support/ClaudeUsage/vibemenu-usage-statusline.sh shim
// (docs/decisions/0016-claude-usage-limits.md): it runs the actual script against a temp usage file,
// then decodes that file with the real `FileClaudeUsageLimitReader`, proving the capture → file →
// reader pipeline and the shim's privacy contract (whitelist only; no cost/transcript/cwd leakage).

@Suite("vibemenu-usage-statusline.sh")
struct ClaudeUsageStatusLineScriptTests {
    /// Locate the script relative to this test file so the test is CWD-independent.
    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/VibeMenuCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Support/ClaudeUsage/vibemenu-usage-statusline.sh")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-usage-shim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run the shim with `stdin`, pointing the usage file at `usageFile`; return (exitCode, stdout).
    @discardableResult
    private func run(stdin: String, usageFile: URL, extraArgs: [String] = []) throws -> (code: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path] + extraArgs
        process.environment = [
            "VIBEMENU_USAGE_FILE": usageFile.path,
            "HOME": usageFile.deletingLastPathComponent().path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: outData, encoding: .utf8) ?? "")
    }

    private let fullPayload = #"""
    {"session_id":"sess-42","version":"2.1.202","model":{"display_name":"Opus 4.8"},
     "workspace":{"current_dir":"/Users/x/Work/DemoRepo"},
     "cost":{"total_cost_usd":9.99},"transcript_path":"/secret/path.jsonl",
     "rate_limits":{"five_hour":{"used_percentage":14,"resets_at":1783203600},
                    "seven_day":{"used_percentage":50,"resets_at":1783432800}}}
    """#

    /// Capture → file → the REAL reader: the shim's output decodes into the expected snapshot.
    @Test func capturesRealServerPercentagesThatTheReaderParses() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usageFile = dir.appendingPathComponent("usage.json")

        let result = try run(stdin: fullPayload, usageFile: usageFile)
        #expect(result.code == 0)
        #expect(result.out == "Opus 4.8 · DemoRepo")   // default status line (no wrap)

        let snapshot = FileClaudeUsageLimitReader(url: usageFile).readSnapshot()
        #expect(snapshot.limits.map(\.kind) == [.fiveHour, .sevenDay])
        #expect(snapshot.limits.first?.usedPercent == 14)
        #expect(snapshot.limits.first?.resetsAt == Date(timeIntervalSince1970: 1_783_203_600))
        #expect(snapshot.limits.last?.usedPercent == 50)
        #expect(snapshot.sessionID == "sess-42")
    }

    /// The usage file contains ONLY the whitelisted keys — never cost/transcript/cwd.
    @Test func writesOnlyWhitelistedFields() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usageFile = dir.appendingPathComponent("usage.json")

        _ = try run(stdin: fullPayload, usageFile: usageFile)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: usageFile)) as? [String: Any]
        )
        #expect(Set(object.keys) == ["schemaVersion", "capturedAt", "sessionID", "cliVersion", "fiveHour", "sevenDay"])

        let raw = try String(contentsOf: usageFile, encoding: .utf8).lowercased()
        for forbidden in ["secret", "transcript", "cost", "9.99", "current_dir", "demorepo"] {
            #expect(!raw.contains(forbidden), "usage file leaked '\(forbidden)'")
        }
    }

    /// A render with no `rate_limits` must NOT overwrite the last-known-good snapshot.
    @Test func windowAbsentPreservesLastKnownGood() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usageFile = dir.appendingPathComponent("usage.json")

        _ = try run(stdin: fullPayload, usageFile: usageFile)
        let after = try run(stdin: #"{"session_id":"x","model":{"display_name":"Sonnet"}}"#, usageFile: usageFile)
        #expect(after.code == 0)
        // File still holds the earlier capture.
        #expect(FileClaudeUsageLimitReader(url: usageFile).readSnapshot().limits.count == 2)
    }

    /// `--wrap <base64>` runs the wrapped command with the same stdin and prints its output verbatim.
    @Test func wrapPassesThroughOriginalStatusLine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usageFile = dir.appendingPathComponent("usage.json")

        let wrapped = Data("echo WRAPPED-LINE".utf8).base64EncodedString()
        let result = try run(stdin: fullPayload, usageFile: usageFile, extraArgs: ["--wrap", wrapped])
        #expect(result.code == 0)
        #expect(result.out.contains("WRAPPED-LINE"))
        // Capture still happens even while wrapping.
        #expect(FileClaudeUsageLimitReader(url: usageFile).readSnapshot().limits.count == 2)
    }

    /// Garbage stdin never breaks the status line and never writes a file.
    @Test func garbageStdinExitsZeroAndWritesNothing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usageFile = dir.appendingPathComponent("usage.json")

        let result = try run(stdin: "not json at all", usageFile: usageFile)
        #expect(result.code == 0)
        #expect(!FileManager.default.fileExists(atPath: usageFile.path))
    }
}
