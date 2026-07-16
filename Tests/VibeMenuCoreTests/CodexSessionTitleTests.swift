import Foundation
import Testing
@testable import VibeMenuCore

// Tests for safe Codex session titles (docs/decisions/0017-codex-session-support.md): the
// `CodexTitleSanitizer` filter, the `CodexSessionIndexParser` (reads only id + thread_name), and the
// `CodexSessionIndexReader` file adapter. All fixtures are synthetic — never the real
// ~/.codex/session_index.jsonl. The sanitiser is the safety net that must drop any title that could
// leak a path, URL, or raw prompt, even though the curated `thread_name` is normally clean.

@Suite("CodexTitleSanitizer — keep safe titles, drop unsafe ones")
struct CodexTitleSanitizerTests {

    @Test("A clean short title is kept, trimmed")
    func cleanTitleKept() {
        #expect(CodexTitleSanitizer.sanitize("Fix the login bug") == "Fix the login bug")
        #expect(CodexTitleSanitizer.sanitize("  Refactor menu layout  ") == "Refactor menu layout")
    }

    @Test("Empty / whitespace-only → nil (fall back to folder)")
    func emptyRejected() {
        #expect(CodexTitleSanitizer.sanitize(nil) == nil)
        #expect(CodexTitleSanitizer.sanitize("") == nil)
        #expect(CodexTitleSanitizer.sanitize("    ") == nil)
        #expect(CodexTitleSanitizer.sanitize("\n\t ") == nil)
    }

    @Test("Generic placeholders → nil")
    func genericRejected() {
        for g in ["New thread", "untitled", "New Chat", "Codex", "codex session", "Conversation"] {
            #expect(CodexTitleSanitizer.sanitize(g) == nil, "\(g) should be rejected as generic")
        }
    }

    @Test("Multi-line / control characters → nil (the raw-prompt shape from state_5.sqlite)")
    func multilineRejected() {
        #expect(CodexTitleSanitizer.sanitize("Fix the branch\nbefore any commit") == nil)
        #expect(CodexTitleSanitizer.sanitize("line one\r\nline two") == nil)
        #expect(CodexTitleSanitizer.sanitize("has\ttab") == nil)
        // U+2028 / U+2029 are line breaks of category Zl/Zp that are NOT in `controlCharacters`; an
        // interior one must still be rejected so a second (prompt) line can't ride along a safe first.
        #expect(CodexTitleSanitizer.sanitize("safe title\u{2028}SECRET_SECOND_LINE") == nil)
        #expect(CodexTitleSanitizer.sanitize("safe title\u{2029}second para") == nil)
        #expect(CodexTitleSanitizer.sanitize("a\u{0085}b") == nil)   // NEL (next line)
    }

    @Test("URLs → nil (no repo/link leakage)")
    func urlsRejected() {
        #expect(CodexTitleSanitizer.sanitize("see https://example.com/repo") == nil)
        #expect(CodexTitleSanitizer.sanitize("http://foo") == nil)
        #expect(CodexTitleSanitizer.sanitize("visit www.example.com") == nil)
        #expect(CodexTitleSanitizer.sanitize("git@github.com:acme/repo.git") == nil)
    }

    @Test("Filesystem-path-looking titles → nil (no path leakage), including no-leading-slash forms")
    func pathsRejected() {
        #expect(CodexTitleSanitizer.sanitize("/Users/someone/Work/Project") == nil)
        #expect(CodexTitleSanitizer.sanitize("~/Work/Project") == nil)
        #expect(CodexTitleSanitizer.sanitize("./relative/path") == nil)
        #expect(CodexTitleSanitizer.sanitize("C:\\Windows\\path") == nil)
        #expect(CodexTitleSanitizer.sanitize("work in /Users/bob/secret") == nil)
        // No leading slash, but still a path fragment that must not leak.
        #expect(CodexTitleSanitizer.sanitize("Users/bob/secret") == nil)
        #expect(CodexTitleSanitizer.sanitize("src/app/secret.ts") == nil)
    }

    @Test("Any slash is treated as suspicious (conservative — falls back to the folder name)")
    func anySlashRejected() {
        // A curated title never contains a slash; rejecting all of them blocks the whole path/URL
        // fragment class. "read/write cache tuning" therefore falls back to the folder name (nil here).
        #expect(CodexTitleSanitizer.sanitize("read/write cache tuning") == nil)
    }

    @Test("Zero-width / bidi-override format characters are rejected (controlCharacters covers Cc+Cf)")
    func formatCharsRejected() {
        #expect(CodexTitleSanitizer.sanitize("safe\u{200B}title") == nil)   // zero-width space (Cf)
        #expect(CodexTitleSanitizer.sanitize("spoof\u{202E}txet") == nil)   // right-to-left override (Cf)
    }

    @Test("Over-long single-line title is truncated with an ellipsis, within the cap")
    func longTitleTruncated() {
        let long = String(repeating: "a", count: 200)
        let out = CodexTitleSanitizer.sanitize(long)
        let s = try! #require(out)
        #expect(s.count <= CodexTitleSanitizer.maxDisplayLength)
        #expect(s.hasSuffix("…"))
    }

    @Test("A title exactly at the cap is not truncated")
    func atCapNotTruncated() {
        let exact = String(repeating: "b", count: CodexTitleSanitizer.maxDisplayLength)
        #expect(CodexTitleSanitizer.sanitize(exact) == exact)
    }
}

@Suite("CodexSessionIndexParser — allowlist id + thread_name only")
struct CodexSessionIndexParserTests {

    @Test("Maps session id → sanitised title; drops unsafe/empty titles")
    func mapsAndDrops() {
        let text = CodexFixture.sessionIndex([
            ("s-1", "Fix login bug"),
            ("s-2", "New thread"),                 // generic → dropped
            ("s-3", "/Users/bob/secret/path"),     // path → dropped
            ("s-4", "Polish the menu"),
        ])
        let map = CodexSessionIndexParser.parse(text: text)
        #expect(map["s-1"] == "Fix login bug")
        #expect(map["s-4"] == "Polish the menu")
        #expect(map["s-2"] == nil)
        #expect(map["s-3"] == nil)
    }

    @Test("Reads ONLY id + thread_name — no forbidden field leaks into the map")
    func noForbiddenFieldLeak() {
        // Every line is stuffed with cwd / first_user_message / preview / git_origin_url (SECRET_*).
        let text = CodexFixture.sessionIndex([("s-1", "Clean title")], includeSensitive: true)
        let map = CodexSessionIndexParser.parse(text: text)
        #expect(map["s-1"] == "Clean title")
        for (_, title) in map {
            for marker in CodexFixture.sensitiveMarkers {
                #expect(!title.contains(marker))
            }
        }
    }

    @Test("Malformed lines are skipped; a valid sibling still parses")
    func malformedSkipped() {
        let text = "not json\n{bad\n" + CodexFixture.sessionIndex([("ok", "Good title")], includeSensitive: false)
        let map = CodexSessionIndexParser.parse(text: text)
        #expect(map == ["ok": "Good title"])
    }

    @Test("A line missing id or thread_name is skipped")
    func missingFieldsSkipped() {
        let text = """
        {"thread_name":"orphan title"}
        {"id":"no-title"}
        {"id":"good","thread_name":"Has both"}
        """
        let map = CodexSessionIndexParser.parse(text: text)
        #expect(map == ["good": "Has both"])
    }
}

@Suite("CodexSessionIndexReader — file adapter")
struct CodexSessionIndexReaderTests {

    @Test("Missing index file → empty map (never a crash)")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-index-\(UUID().uuidString).jsonl")
        #expect(CodexSessionIndexReader(url: url).titles().isEmpty)
    }

    @Test("Reads and sanitises titles from a real temp index file")
    func readsTempFile() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = CodexFixture.writeIndex(
            CodexFixture.sessionIndex([("s-1", "Fix login bug"), ("s-2", "Untitled")]),
            into: dir
        )
        let map = CodexSessionIndexReader(url: url).titles()
        #expect(map == ["s-1": "Fix login bug"])   // "Untitled" dropped as generic
    }
}
