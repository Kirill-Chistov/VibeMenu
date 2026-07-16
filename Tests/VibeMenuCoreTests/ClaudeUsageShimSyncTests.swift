import Foundation
import Testing
@testable import VibeMenuCore

// Guards against drift between the embedded shim source (used by the one-click installer) and the
// canonical, human-readable copy at Support/ClaudeUsage/vibemenu-usage-statusline.sh (used for manual
// install + code review). If either is edited without the other, this fails
// (docs/decisions/0016-claude-usage-limits.md).

@Suite("ClaudeUsageStatusLineShim sync")
struct ClaudeUsageShimSyncTests {
    /// The repo's canonical shim script, located relative to this test file's path (Tests/… → repo root).
    private func supportShimURL() -> URL {
        URL(fileURLWithPath: #filePath)                 // …/Tests/VibeMenuCoreTests/ClaudeUsageShimSyncTests.swift
            .deletingLastPathComponent()                // …/Tests/VibeMenuCoreTests
            .deletingLastPathComponent()                // …/Tests
            .deletingLastPathComponent()                // repo root
            .appendingPathComponent("Support/ClaudeUsage/vibemenu-usage-statusline.sh")
    }

    @Test func embeddedShimMatchesSupportFile() throws {
        let fileText = try String(contentsOf: supportShimURL(), encoding: .utf8)
        // Compare ignoring only trailing newline differences between a file and a Swift literal.
        let a = fileText.trimmingCharacters(in: .newlines)
        let b = ClaudeUsageStatusLineShim.source.trimmingCharacters(in: .newlines)
        #expect(a == b, "Support/ClaudeUsage/vibemenu-usage-statusline.sh and ClaudeUsageStatusLineShim.source have drifted — update both.")
    }

    @Test func embeddedShimIsAPosixScript() {
        #expect(ClaudeUsageStatusLineShim.source.hasPrefix("#!/bin/sh"))
        #expect(ClaudeUsageStatusLineShim.fileName == "vibemenu-usage-statusline.sh")
    }
}
