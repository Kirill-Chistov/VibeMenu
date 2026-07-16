import Foundation
import Testing
@testable import VibeMenuCore

// Session-title extraction tests (docs/decisions/0013-session-title-and-dismiss.md). Everything
// here is pure and synthetic — the fixtures are hand-written JSONL with **fake, non-sensitive**
// data (no real prompts or responses). We verify:
//   * the last custom-title wins, and custom beats ai;
//   * only title records are ever consulted (prompt/response/lastPrompt/tool lines are ignored,
//     even when they happen to contain the marker text);
//   * malformed / empty / oversized titles are handled without crashing;
//   * the resolver's session-id safety gate blocks path traversal.

@Suite("ClaudeSessionTitle.parse")
struct ClaudeSessionTitleParseTests {
    /// A synthetic transcript line for a title record (fake title text).
    private func titleLine(_ type: String, field: String, _ value: String, session: String = "s1") -> String {
        #"{"type":"\#(type)","\#(field)":"\#(value)","sessionId":"\#(session)"}"#
    }

    @Test func returnsNilForNoTitleRecords() {
        let lines = [
            #"{"type":"user","message":{"role":"user"},"sessionId":"s1"}"#,
            #"{"type":"assistant","message":{"role":"assistant"},"sessionId":"s1"}"#
        ]
        #expect(ClaudeSessionTitle.parse(lines: lines) == nil)
    }

    @Test func readsAITitleWhenNoCustom() {
        let lines = [
            #"{"type":"user","sessionId":"s1"}"#,
            titleLine("ai-title", field: "aiTitle", "Greeting")
        ]
        #expect(ClaudeSessionTitle.parse(lines: lines) == "Greeting")
    }

    @Test func customTitleBeatsAITitle() {
        // AI title first, then a user rename — the custom title must win regardless of order.
        let lines = [
            titleLine("ai-title", field: "aiTitle", "Auto generated name"),
            titleLine("custom-title", field: "customTitle", "My renamed session")
        ]
        #expect(ClaudeSessionTitle.parse(lines: lines) == "My renamed session")

        // Even when the AI title comes *after* the custom one, custom still wins.
        let reversed = [
            titleLine("custom-title", field: "customTitle", "My renamed session"),
            titleLine("ai-title", field: "aiTitle", "Auto generated name")
        ]
        #expect(ClaudeSessionTitle.parse(lines: reversed) == "My renamed session")
    }

    @Test func lastCustomTitleWins() {
        // A session renamed several times: the newest custom title is what Claude Code shows.
        let lines = [
            titleLine("custom-title", field: "customTitle", "First name"),
            titleLine("custom-title", field: "customTitle", "Second name"),
            titleLine("custom-title", field: "customTitle", "Third name")
        ]
        #expect(ClaudeSessionTitle.parse(lines: lines) == "Third name")
    }

    @Test func lastAITitleWinsAmongAITitles() {
        let lines = [
            titleLine("ai-title", field: "aiTitle", "Old auto title"),
            titleLine("ai-title", field: "aiTitle", "New auto title")
        ]
        #expect(ClaudeSessionTitle.parse(lines: lines) == "New auto title")
    }

    /// A message body that merely contains the literal marker text must not be mistaken for a
    /// title — its `type` is not a title type, so nothing is extracted from it. This is the
    /// privacy guarantee that prompt/response content never becomes a title.
    @Test func nonTitleRecordContainingMarkerTextIsIgnored() {
        let lines = [
            // A user prompt that literally mentions the marker string — must be ignored.
            #"{"type":"user","message":{"text":"please add a \"custom-title\" field"},"sessionId":"s1"}"#,
            #"{"type":"assistant","message":{"text":"talking about \"ai-title\" here"},"sessionId":"s1"}"#
        ]
        #expect(ClaudeSessionTitle.parse(lines: lines) == nil)
    }

    /// `last-prompt` records carry prompt text in `lastPrompt`; they are never a title source.
    @Test func lastPromptRecordIsNeverUsed() {
        let lines = [
            #"{"type":"last-prompt","lastPrompt":"do not read me","leafUuid":"x","sessionId":"s1"}"#
        ]
        #expect(ClaudeSessionTitle.parse(lines: lines) == nil)
    }

    @Test func emptyOrWhitespaceTitleFallsThrough() {
        // An empty custom title must not mask a real ai title.
        let lines = [
            titleLine("custom-title", field: "customTitle", "   "),
            titleLine("ai-title", field: "aiTitle", "Real title")
        ]
        #expect(ClaudeSessionTitle.parse(lines: lines) == "Real title")
    }

    @Test func titleIsTrimmedAndLengthCapped() {
        let long = String(repeating: "x", count: 200)
        let lines = [titleLine("custom-title", field: "customTitle", "  \(long)  ")]
        let result = ClaudeSessionTitle.parse(lines: lines)
        #expect(result?.count == ClaudeSessionTitle.maxTitleLength)
    }

    @Test func malformedLinesAreSkipped() {
        let lines = [
            #"{ not valid json "custom-title" ]["#,
            "",
            titleLine("ai-title", field: "aiTitle", "Survivor")
        ]
        #expect(ClaudeSessionTitle.parse(lines: lines) == "Survivor")
    }

    @Test func parseFromDataSplitsLines() {
        let text = [
            #"{"type":"user","sessionId":"s1"}"#,
            #"{"type":"ai-title","aiTitle":"From bytes","sessionId":"s1"}"#
        ].joined(separator: "\n")
        #expect(ClaudeSessionTitle.parse(transcript: Data(text.utf8)) == "From bytes")
    }

    @Test func nonUTF8DataReturnsNil() {
        let data = Data([0xFF, 0xFE, 0xFD])
        #expect(ClaudeSessionTitle.parse(transcript: data) == nil)
    }
}

// Filesystem-isolated tests for the resolver's transcript *lookup* (the one adapter that opens a
// transcript). Each test builds a throwaway `projects/` tree in a temp directory and injects it,
// so nothing touches the real `~/.claude`. Fixtures use fake, non-sensitive data.
@Suite("TranscriptTitleResolver transcript lookup")
struct TranscriptTitleResolverLookupTests {
    private let fm = FileManager.default

    /// Build a temp `projects/` directory holding the given transcripts. Each entry writes
    /// `projects/<encodedDir>/<id>.jsonl` with the given lines, optionally stamping an mtime.
    private func makeProjects(
        _ entries: [(dir: String, id: String, lines: [String], mtime: Date?)]
    ) throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent("vibemenu-tt-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        for e in entries {
            let dir = projects.appendingPathComponent(e.dir, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(e.id).jsonl")
            try Data((e.lines.joined(separator: "\n") + "\n").utf8).write(to: file)
            if let mtime = e.mtime {
                try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
            }
        }
        return projects
    }

    private func aiTitle(_ value: String, session: String = "s") -> String {
        #"{"type":"ai-title","aiTitle":"\#(value)","sessionId":"\#(session)"}"#
    }

    /// The resolver finds a transcript by session id even though it has no idea which encoded
    /// project directory holds it (the heartbeat only carries the folder *name*, not the cwd).
    @Test func findsTranscriptBySessionIDAcrossEncodedDirs() throws {
        let id = "94e549f9-804d-4de6-b5d1-ed1ab69e1c76"
        let projects = try makeProjects([
            ("-Users-kirill-Work-Apps-Other", "aaaa-1111", [aiTitle("Other session")], nil),
            ("-Users-kirill-Work-Apps-VibeMenu", id, [aiTitle("Public repository audit")], nil),
            ("-Users-kirill-Some-Third-Project", "bbbb-2222", [aiTitle("Third")], nil),
        ])
        let resolver = TranscriptTitleResolver(projectsDirectory: projects)
        #expect(resolver.title(forSessionID: id) == "Public repository audit")
    }

    /// A session id present under *several* encoded directories (e.g. resumed from a different
    /// cwd) resolves deterministically to the **most recently modified** transcript.
    @Test func multipleProjectDirsPickNewestTranscript() throws {
        let id = "dup-session-id"
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let projects = try makeProjects([
            ("-Users-kirill-old-cwd", id, [aiTitle("Stale title")], old),
            ("-Users-kirill-new-cwd", id, [aiTitle("Live title")], new),
        ])
        let resolver = TranscriptTitleResolver(projectsDirectory: projects)
        #expect(resolver.title(forSessionID: id) == "Live title")
    }

    /// A transcript with no title record resolves to `nil` so the caller falls back to the folder
    /// name — even when it is full of prompt/response/last-prompt content. This is the privacy
    /// guarantee at the adapter level: no prompt/response record is ever turned into a display name.
    @Test func noTitleRecordResolvesToNilIgnoringPromptContent() throws {
        let id = "no-title-session"
        let projects = try makeProjects([(
            "-Users-kirill-Work-Apps-VibeMenu", id,
            [
                #"{"type":"user","message":{"role":"user","content":"secret prompt text"},"sessionId":"x"}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":"secret response"},"sessionId":"x"}"#,
                #"{"type":"last-prompt","lastPrompt":"do not read me","sessionId":"x"}"#,
            ], nil
        )])
        let resolver = TranscriptTitleResolver(projectsDirectory: projects)
        #expect(resolver.title(forSessionID: id) == nil)
    }

    /// Only the title record drives the result even when prompt/response lines are interleaved
    /// around it — the resolver returns the title and nothing derived from message bodies.
    @Test func returnsOnlyTheTitleAmongPromptContent() throws {
        let id = "titled-session"
        let projects = try makeProjects([(
            "-Users-kirill-Work-Apps-VibeMenu", id,
            [
                #"{"type":"user","message":{"content":"please rename to custom-title"},"sessionId":"x"}"#,
                aiTitle("Greeting", session: "x"),
                #"{"type":"assistant","message":{"content":"long assistant reply"},"sessionId":"x"}"#,
            ], nil
        )])
        let resolver = TranscriptTitleResolver(projectsDirectory: projects)
        #expect(resolver.title(forSessionID: id) == "Greeting")
    }

    /// An unknown session id (no matching transcript in any project dir) resolves to `nil`.
    @Test func unknownSessionIDResolvesToNil() throws {
        let projects = try makeProjects([
            ("-Users-kirill-Work-Apps-VibeMenu", "some-other-id", [aiTitle("X")], nil),
        ])
        let resolver = TranscriptTitleResolver(projectsDirectory: projects)
        #expect(resolver.title(forSessionID: "missing-id") == nil)
    }
}

@Suite("TranscriptTitleResolver.isSafeSessionID")
struct TranscriptTitleResolverSafetyTests {
    @Test func acceptsRealSessionIDs() {
        #expect(TranscriptTitleResolver.isSafeSessionID("94e549f9-804d-4de6-b5d1-ed1ab69e1c76"))
        #expect(TranscriptTitleResolver.isSafeSessionID("unknown-session"))
        #expect(TranscriptTitleResolver.isSafeSessionID("abc123._-"))
    }

    /// Anything that could traverse or escape `<id>.jsonl` is rejected, so a malformed session id
    /// can never build a path outside the projects tree.
    @Test func rejectsUnsafeIDs() {
        #expect(!TranscriptTitleResolver.isSafeSessionID(""))
        #expect(!TranscriptTitleResolver.isSafeSessionID("../secret"))
        #expect(!TranscriptTitleResolver.isSafeSessionID("a/b"))
        #expect(!TranscriptTitleResolver.isSafeSessionID("a b"))       // space
        #expect(!TranscriptTitleResolver.isSafeSessionID("a\u{0000}b")) // NUL
        #expect(!TranscriptTitleResolver.isSafeSessionID("id;rm"))
    }
}
