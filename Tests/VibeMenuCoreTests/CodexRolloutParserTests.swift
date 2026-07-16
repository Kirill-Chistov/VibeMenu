import Foundation
import Testing
@testable import VibeMenuCore

// Pure parser tests (docs/decisions/0017-codex-session-support.md). All fixtures are synthetic
// (CodexTestSupport) — no real ~/.codex data. The privacy suite is the important one: it feeds a
// rollout stuffed with forbidden content and proves none of it reaches the summary.

@Suite("CodexRolloutParser — basic parsing")
struct CodexRolloutParserBasicTests {
    let start = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("Parses a Desktop rollout: id, originator, folder basename, start, completion")
    func parsesDesktopRollout() throws {
        let text = CodexFixture.rollout(
            sessionID: "sess-xyz",
            cwd: "/Users/someone/Work/VibeMenu",
            start: start,
            events: [(0, "task_started", [:]), (5, "task_complete", [:])]
        )
        let summary = try #require(CodexRolloutParser.parse(text: text))
        #expect(summary.sessionID == "sess-xyz")
        #expect(summary.originator == "Codex Desktop")
        #expect(summary.folderName == "VibeMenu")
        #expect(summary.startedAt == start)
        #expect(summary.endedWithCompletion == true)
        #expect(summary.lastActivity == start.addingTimeInterval(5))
    }

    @Test("A turn that has not completed reports endedWithCompletion == false")
    func midTurnNotCompleted() throws {
        let text = CodexFixture.rollout(
            start: start,
            events: [(0, "task_started", [:]), (2, "user_message", [:])]
        )
        let summary = try #require(CodexRolloutParser.parse(text: text))
        #expect(summary.endedWithCompletion == false)
    }

    @Test("A new prompt after a prior completion reads as not-completed (turn in progress)")
    func newPromptAfterCompletion() throws {
        let text = CodexFixture.rollout(
            start: start,
            events: [
                (0, "task_started", [:]), (3, "task_complete", [:]),
                (60, "task_started", [:]), (61, "user_message", [:]),
            ]
        )
        let summary = try #require(CodexRolloutParser.parse(text: text))
        #expect(summary.endedWithCompletion == false)   // last event is not task_complete
        #expect(summary.lastActivity == start.addingTimeInterval(61))
    }

    @Test("Both fractional and plain ISO timestamps parse")
    func timestampFormats() throws {
        // Plain (no fractional seconds) session_meta timestamp still yields a start date.
        let plain = """
        {"timestamp":"2026-07-10T14:14:14Z","type":"session_meta","payload":{"session_id":"s","id":"s","originator":"Codex Desktop","cwd":"/a/b/Proj","timestamp":"2026-07-10T14:14:14Z"}}
        {"timestamp":"2026-07-10T14:14:20.123Z","type":"event_msg","payload":{"type":"task_complete"}}
        """
        let summary = try #require(CodexRolloutParser.parse(text: plain))
        #expect(summary.folderName == "Proj")
        #expect(summary.endedWithCompletion == true)
        #expect(summary.lastActivity > summary.startedAt)
    }
}

@Suite("CodexRolloutParser — robustness")
struct CodexRolloutParserRobustnessTests {
    let start = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("Empty text yields nil")
    func emptyText() {
        #expect(CodexRolloutParser.parse(text: "") == nil)
        #expect(CodexRolloutParser.parse(text: "\n\n") == nil)
    }

    @Test("Missing session_meta yields nil (no id/originator to gate)")
    func noSessionMeta() {
        let text = CodexFixture.rollout(start: start, events: [(0, "task_started", [:])], includeMeta: false)
        #expect(CodexRolloutParser.parse(text: text) == nil)
    }

    @Test("Malformed / junk lines are skipped, valid lines still parse")
    func malformedLinesIgnored() throws {
        let valid = CodexFixture.rollout(
            sessionID: "s1", cwd: "/x/y/Zed", start: start,
            events: [(0, "task_started", [:]), (4, "task_complete", [:])]
        )
        // Interleave garbage that must not crash or corrupt the parse.
        let text = """
        not json at all
        {"partial":
        {"timestamp":"garbage","type":"event_msg","payload":{"type":"task_started"}}
        \(valid)
        {"unbalanced":[1,2,3
        """
        let summary = try #require(CodexRolloutParser.parse(text: text))
        #expect(summary.sessionID == "s1")
        #expect(summary.folderName == "Zed")
    }

    @Test("Folder name is the basename only — never a path or parent directory")
    func folderNameBasenameOnly() throws {
        let text = CodexFixture.rollout(
            cwd: "/Users/SECRET_USER/Work/SECRET_PARENT/MyProject", start: start,
            events: [(0, "task_complete", [:])]
        )
        let summary = try #require(CodexRolloutParser.parse(text: text))
        #expect(summary.folderName == "MyProject")
        #expect(summary.folderName?.contains("SECRET_USER") == false)
        #expect(summary.folderName?.contains("SECRET_PARENT") == false)
        #expect(summary.folderName?.contains("/") == false)
    }

    @Test("Root / empty cwd yields no folder name rather than \"/\"")
    func rootCwdNoFolder() throws {
        let text = CodexFixture.rollout(cwd: "/", start: start, events: [(0, "task_complete", [:])])
        let summary = try #require(CodexRolloutParser.parse(text: text))
        #expect(summary.folderName == nil)
    }

    @Test("CLI originator is still parsed verbatim (the reader gates, not the parser)")
    func cliOriginatorPreserved() throws {
        let text = CodexFixture.rollout(originator: "codex_cli_rs", start: start, events: [(0, "task_complete", [:])])
        let summary = try #require(CodexRolloutParser.parse(text: text))
        #expect(summary.originator == "codex_cli_rs")
        #expect(summary.originator != CodexRolloutParser.desktopOriginator)
    }

    @Test("source flags a subagent rollout; a string/absent source is not a subagent")
    func subagentFlag() throws {
        let sub = try #require(CodexRolloutParser.parse(
            text: CodexFixture.rollout(start: start, events: [(0, "task_started", [:])],
                                       source: ["subagent": ["other": "guardian"]])))
        #expect(sub.isSubagent)
        let vscode = try #require(CodexRolloutParser.parse(
            text: CodexFixture.rollout(start: start, events: [(0, "task_started", [:])], source: "vscode")))
        #expect(!vscode.isSubagent)
        let none = try #require(CodexRolloutParser.parse(
            text: CodexFixture.rollout(start: start, events: [(0, "task_started", [:])])))
        #expect(!none.isSubagent)
    }

    @Test("isDesktopOriginator accepts the spaced + codex_*_desktop family, rejects CLI/lookalikes")
    func desktopOriginatorGate() {
        // Canonical spaced form (case/whitespace tolerant).
        #expect(CodexRolloutParser.isDesktopOriginator("Codex Desktop"))
        #expect(CodexRolloutParser.isDesktopOriginator("  codex desktop  "))
        // Anchored underscore family — the id newer Codex Desktop builds emit (seen in real data).
        #expect(CodexRolloutParser.isDesktopOriginator("codex_work_desktop"))
        #expect(CodexRolloutParser.isDesktopOriginator("CODEX_WORK_DESKTOP"))
        #expect(CodexRolloutParser.isDesktopOriginator("codex_personal_desktop"))
        // The CLI, editor, and lookalikes stay rejected — the match is anchored at both ends, never a `contains`.
        #expect(!CodexRolloutParser.isDesktopOriginator("codex_cli_rs"))
        #expect(!CodexRolloutParser.isDesktopOriginator("codex_vscode"))
        #expect(!CodexRolloutParser.isDesktopOriginator("codex_cli_desktop_evil.example.com"))
        #expect(!CodexRolloutParser.isDesktopOriginator("not_codex_work_desktop"))
        #expect(!CodexRolloutParser.isDesktopOriginator("some desktop app"))
        #expect(!CodexRolloutParser.isDesktopOriginator("codex__desktop"))   // empty middle
        #expect(!CodexRolloutParser.isDesktopOriginator(""))
    }
}

@Suite("CodexRolloutParser — privacy (no forbidden field ever surfaces)")
struct CodexRolloutParserPrivacyTests {
    let start = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("A rollout stuffed with prompts/responses/tool/reasoning/git/account/auth surfaces none of it")
    func noSensitiveFieldSurfaces() throws {
        let text = CodexFixture.completedTurnWithSensitivePayloads(start: start)
        let summary = try #require(CodexRolloutParser.parse(text: text))

        // The summary's only string fields are sessionID, originator, folderName — assert none of
        // them carry any sensitive marker, and the folder is the safe basename.
        let fields = [summary.sessionID, summary.originator, summary.folderName ?? ""]
        for marker in CodexFixture.sensitiveMarkers {
            for field in fields {
                #expect(!field.contains(marker), "‘\(marker)’ leaked into ‘\(field)’")
            }
        }
        #expect(summary.folderName == "MyProject")
        #expect(summary.endedWithCompletion == true)   // task_complete was still detected
    }

    @Test("The summary type structurally carries only metadata (compile-time guarantee, checked here)")
    func summaryShapeIsMetadataOnly() throws {
        // A red-team fixture whose *folder name itself* is safe but everything else is sensitive.
        let text = CodexFixture.rollout(
            sessionID: "safe-id",
            cwd: "/tmp/Proj",
            start: start,
            events: [
                (0, "task_started", ["command": "SECRET_COMMAND rm -rf /"]),
                (1, "agent_message", ["message": "SECRET_RESPONSE", "api_key": "sk-SECRETKEY"]),
                (2, "task_complete", [:]),
            ],
            includeSensitive: true
        )
        let summary = try #require(CodexRolloutParser.parse(text: text))
        // Mirror.reflection: every stored value is either a safe String, a Date, or a Bool — and no
        // String value contains a marker.
        let mirror = Mirror(reflecting: summary)
        for child in mirror.children {
            if let s = child.value as? String {
                for marker in CodexFixture.sensitiveMarkers {
                    #expect(!s.contains(marker), "‘\(marker)’ leaked into field \(child.label ?? "?")")
                }
            }
        }
    }
}
