import Foundation
import Testing
@testable import VibeMenuCore

// Enhanced (opt-in) Desktop-title tests (docs/decisions/0014-enhanced-desktop-titles.md).
// Everything here is pure/synthetic — fixtures are hand-written JSON with **fake, non-sensitive**
// data (no real prompts or responses). We verify:
//   * only whitelisted fields are ever decoded (prompt/response-like fields are ignored);
//   * a missing id or empty title drops the record; titles are trimmed and length-capped;
//   * duplicate `cliSessionId` picks the latest `lastActivityAt`, and non-archived beats archived;
//   * the resolver globs both UUID levels, fails closed on a missing directory, and — crucially —
//     reads nothing when the opt-in gate is off;
//   * the composite chain puts the (enabled) Desktop title ahead of the transcript title and falls
//     through to it when the Desktop resolver is off/empty.

// MARK: - Fixtures

/// A synthetic Claude Desktop `local_<uuid>.json` object. `extra` injects raw JSON key/values that
/// must be **ignored** (the forbidden fields), to prove the whitelist boundary holds.
private func indexJSON(
    cli: String? = "cli-1",
    title: String? = "Alpha task",
    source: String? = "auto",
    activity: Double? = 1_000,
    archived: Bool = false,
    sessionId: String = "local_1",
    extra: [String: String] = [:]
) -> Data {
    var obj: [String: Any] = [
        "sessionId": sessionId,
        "isArchived": archived,
    ]
    if let cli { obj["cliSessionId"] = cli }
    if let title { obj["title"] = title }
    if let source { obj["titleSource"] = source }
    if let activity { obj["lastActivityAt"] = activity }
    for (k, v) in extra { obj[k] = v }
    return try! JSONSerialization.data(withJSONObject: obj)
}

// MARK: - Pure parser

@Suite("ClaudeDesktopTitleIndex.parse")
struct ClaudeDesktopParseTests {
    @Test func parsesValidRecord() {
        let record = ClaudeDesktopTitleIndex.parse(record: indexJSON(
            cli: "cli-42", title: "Public repository audit", source: "auto",
            activity: 1_783_030_274_535, archived: false
        ))
        #expect(record == DesktopSessionRecord(
            cliSessionID: "cli-42",
            title: "Public repository audit",
            titleSource: "auto",
            lastActivityAt: 1_783_030_274_535,
            isArchived: false
        ))
    }

    /// A file crammed with the forbidden fields must parse to exactly the whitelisted record —
    /// none of the sensitive content can reach the model because the DTO has no such properties.
    @Test func ignoresNonWhitelistedFields() {
        let record = ClaudeDesktopTitleIndex.parse(record: indexJSON(
            cli: "cli-9", title: "GMT time query",
            extra: [
                "promptSuggestion": "SECRET-PROMPT",
                "alwaysAllowedReasons": "SECRET-REASON",
                "lastPrompt": "SECRET-LASTPROMPT",
                "cwd": "/Users/someone/private",
                "originCwd": "/Users/someone/private",
                "model": "claude-opus-4-8",
            ]
        ))
        #expect(record?.cliSessionID == "cli-9")
        #expect(record?.title == "GMT time query")
        // Structural guarantee: DesktopSessionRecord has no prompt/cwd/message field, so the
        // secret values cannot be present anywhere on the parsed model.
        #expect(record == DesktopSessionRecord(
            cliSessionID: "cli-9", title: "GMT time query",
            titleSource: "auto", lastActivityAt: 1_000, isArchived: false
        ))
    }

    @Test func dropsRecordWithoutSessionID() {
        #expect(ClaudeDesktopTitleIndex.parse(record: indexJSON(cli: nil)) == nil)
    }

    @Test func dropsRecordWithEmptyOrWhitespaceTitle() {
        #expect(ClaudeDesktopTitleIndex.parse(record: indexJSON(title: "")) == nil)
        #expect(ClaudeDesktopTitleIndex.parse(record: indexJSON(title: "   \n ")) == nil)
        #expect(ClaudeDesktopTitleIndex.parse(record: indexJSON(title: nil)) == nil)
    }

    @Test func trimsAndCapsTitle() {
        let padded = ClaudeDesktopTitleIndex.parse(record: indexJSON(title: "  Greeting \n"))
        #expect(padded?.title == "Greeting")

        let long = String(repeating: "x", count: 200)
        let capped = ClaudeDesktopTitleIndex.parse(record: indexJSON(title: long))
        #expect(capped?.title.count == ClaudeSessionTitle.maxTitleLength)
    }

    @Test func returnsNilForMalformedJSON() {
        #expect(ClaudeDesktopTitleIndex.parse(record: Data("not json".utf8)) == nil)
        #expect(ClaudeDesktopTitleIndex.parse(record: Data()) == nil)
        // A JSON array (not an object) must not crash the decoder.
        #expect(ClaudeDesktopTitleIndex.parse(record: Data("[1,2,3]".utf8)) == nil)
    }

    /// Missing `isArchived` defaults to non-archived rather than dropping the record.
    @Test func defaultsArchivedFalseWhenMissing() {
        let data = Data(#"{"cliSessionId":"c","title":"T"}"#.utf8)
        #expect(ClaudeDesktopTitleIndex.parse(record: data)?.isArchived == false)
    }
}

// MARK: - Map building / dedup

@Suite("ClaudeDesktopTitleIndex.buildTitleMap")
struct ClaudeDesktopMapTests {
    @Test func duplicateSessionIDPicksLatestActivity() {
        let records = [
            DesktopSessionRecord(cliSessionID: "c", title: "Older", lastActivityAt: 100),
            DesktopSessionRecord(cliSessionID: "c", title: "Newer", lastActivityAt: 300),
            DesktopSessionRecord(cliSessionID: "c", title: "Middle", lastActivityAt: 200),
        ]
        #expect(ClaudeDesktopTitleIndex.buildTitleMap(from: records) == ["c": "Newer"])
    }

    @Test func nonArchivedBeatsArchivedEvenWhenArchivedIsNewer() {
        let records = [
            DesktopSessionRecord(cliSessionID: "c", title: "Live", lastActivityAt: 100, isArchived: false),
            DesktopSessionRecord(cliSessionID: "c", title: "Archived", lastActivityAt: 999, isArchived: true),
        ]
        #expect(ClaudeDesktopTitleIndex.buildTitleMap(from: records) == ["c": "Live"])
    }

    @Test func archivedUsedWhenNoNonArchivedExists() {
        let records = [
            DesktopSessionRecord(cliSessionID: "c", title: "OldArchived", lastActivityAt: 100, isArchived: true),
            DesktopSessionRecord(cliSessionID: "c", title: "NewArchived", lastActivityAt: 200, isArchived: true),
        ]
        #expect(ClaudeDesktopTitleIndex.buildTitleMap(from: records) == ["c": "NewArchived"])
    }

    @Test func missingActivitySortsOldest() {
        let records = [
            DesktopSessionRecord(cliSessionID: "c", title: "HasTime", lastActivityAt: 1),
            DesktopSessionRecord(cliSessionID: "c", title: "NoTime", lastActivityAt: nil),
        ]
        #expect(ClaudeDesktopTitleIndex.buildTitleMap(from: records) == ["c": "HasTime"])
    }

    @Test func distinctSessionsAllMapped() {
        let records = [
            DesktopSessionRecord(cliSessionID: "a", title: "Alpha"),
            DesktopSessionRecord(cliSessionID: "b", title: "Beta"),
        ]
        #expect(ClaudeDesktopTitleIndex.buildTitleMap(from: records) == ["a": "Alpha", "b": "Beta"])
    }
}

// MARK: - DesktopTitleResolver (temp-dir I/O)

@Suite("DesktopTitleResolver")
struct DesktopTitleResolverTests {
    /// Build a `<root>/<account>/<workspace>/` tree and write the given `local_*.json` payloads
    /// into it. Returns the root; the caller injects it into the resolver.
    private func makeIndexTree(files: [(name: String, data: Data)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-desktop-\(UUID().uuidString)", isDirectory: true)
        let workspace = root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)   // account level
            .appendingPathComponent(UUID().uuidString, isDirectory: true)   // workspace level
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for file in files {
            try file.data.write(to: workspace.appendingPathComponent(file.name))
        }
        return root
    }

    @Test func resolvesTitleWhenEnabled() throws {
        let root = try makeIndexTree(files: [
            ("local_1.json", indexJSON(cli: "cli-1", title: "Public repository audit")),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = DesktopTitleResolver(isEnabled: { true }, sessionsDirectory: root)
        #expect(resolver.title(forSessionID: "cli-1") == "Public repository audit")
        #expect(resolver.title(forSessionID: "unknown") == nil)
    }

    /// The opt-in gate: with the setting off, a valid index that *would* resolve must return `nil`.
    @Test func returnsNilAndReadsNothingWhenDisabled() throws {
        let root = try makeIndexTree(files: [
            ("local_1.json", indexJSON(cli: "cli-1", title: "Public repository audit")),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = DesktopTitleResolver(isEnabled: { false }, sessionsDirectory: root)
        #expect(resolver.title(forSessionID: "cli-1") == nil)
    }

    @Test func missingDirectoryReturnsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-missing-\(UUID().uuidString)", isDirectory: true)
        let resolver = DesktopTitleResolver(isEnabled: { true }, sessionsDirectory: missing)
        #expect(resolver.title(forSessionID: "cli-1") == nil)
    }

    @Test func globsBothUUIDLevelsAndAppliesDedup() throws {
        // Two files under the same tree for the same id: archived + live → live wins.
        let root = try makeIndexTree(files: [
            ("local_live.json", indexJSON(cli: "c", title: "Live", activity: 10, archived: false)),
            ("local_arch.json", indexJSON(cli: "c", title: "Archived", activity: 99, archived: true)),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = DesktopTitleResolver(isEnabled: { true }, sessionsDirectory: root)
        #expect(resolver.title(forSessionID: "c") == "Live")
    }

    /// A live flag flip (setting toggled at runtime) changes behavior on the next lookup without
    /// reconstructing the resolver — mirrors reading `UserDefaults` in the app.
    @Test func honorsLiveEnableFlag() throws {
        let root = try makeIndexTree(files: [
            ("local_1.json", indexJSON(cli: "cli-1", title: "Alpha task")),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled = FlagBox(false)
        let resolver = DesktopTitleResolver(isEnabled: { enabled.value }, sessionsDirectory: root)
        #expect(resolver.title(forSessionID: "cli-1") == nil)
        enabled.value = true
        #expect(resolver.title(forSessionID: "cli-1") == "Alpha task")
    }

    // MARK: - Title-appears-while-active (cache invalidation)
    //
    // Issue 1 (active-title timing): the Claude Desktop index writes a live session's `cliSessionId`
    // + `title` *while the session is still working* (verified against live data), so the radar must
    // reflect that title on the next ~2s tick — not only after the session finishes. Because the app
    // reuses ONE resolver instance across ticks, these tests exercise the cache signature: a title
    // that appears mid-session (as a new index file, or filled into an existing one) must invalidate
    // the cached map so the very next lookup returns it. The signature is paths + mtimes + sizes.

    /// A session with no Desktop record yet resolves to `nil` (radar shows the folder-name
    /// fallback). When Claude Desktop writes that session's index file mid-run — a **new** file in
    /// the tree — the same resolver reflects the title on the next lookup, because the changed file
    /// set changes the signature and rebuilds the map.
    @Test func picksUpTitleWhenIndexFileAppearsMidSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-desktop-\(UUID().uuidString)", isDirectory: true)
        let workspace = root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)   // account level
            .appendingPathComponent(UUID().uuidString, isDirectory: true)   // workspace level
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // An unrelated session is already indexed; the active one has no record yet.
        try indexJSON(cli: "other", title: "Other session")
            .write(to: workspace.appendingPathComponent("local_other.json"))
        let resolver = DesktopTitleResolver(isEnabled: { true }, sessionsDirectory: root)
        #expect(resolver.title(forSessionID: "active-1") == nil)   // fallback name while active

        // Claude Desktop writes the active session's index file while it is still working.
        try indexJSON(cli: "active-1", title: "Live task")
            .write(to: workspace.appendingPathComponent("local_active.json"))
        #expect(resolver.title(forSessionID: "active-1") == "Live task")   // reflected next lookup
    }

    /// The in-place counterpart: a session's index file initially carries no usable title (dropped
    /// → `nil`); when Claude Desktop fills in the auto-generated title by rewriting the **same**
    /// file, the resolver reflects it on the next lookup (the file's size/mtime change moves the
    /// signature). Guards against a stale cache hiding a title that appears while active.
    @Test func picksUpTitleWhenAddedToExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-desktop-\(UUID().uuidString)", isDirectory: true)
        let workspace = root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = workspace.appendingPathComponent("local_active.json")

        // Early in the session Desktop has a record but no title yet → dropped → nil.
        try indexJSON(cli: "active-1", title: nil).write(to: file)
        let resolver = DesktopTitleResolver(isEnabled: { true }, sessionsDirectory: root)
        #expect(resolver.title(forSessionID: "active-1") == nil)

        // Desktop writes the auto-generated title into the same file.
        try indexJSON(cli: "active-1", title: "Auto generated title").write(to: file)
        #expect(resolver.title(forSessionID: "active-1") == "Auto generated title")
    }
}

// MARK: - CompositeTitleResolver + fallback chain

/// Thread-safe mutable flag so a `@Sendable` enable closure can be flipped mid-test.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// In-test resolver backed by a fixed map (no I/O). `nil` map entry ⇒ no title.
private final class FakeResolver: SessionTitleResolving, @unchecked Sendable {
    let map: [String: String]
    init(_ map: [String: String]) { self.map = map }
    func title(forSessionID id: String) -> String? { map[id] }
}

@Suite("CompositeTitleResolver")
struct CompositeTitleResolverTests {
    @Test func firstNonNilWins() {
        let composite = CompositeTitleResolver([
            FakeResolver(["s": "Desktop title"]),   // Desktop source (highest priority)
            FakeResolver(["s": "Transcript title"]), // transcript source
        ])
        #expect(composite.title(forSessionID: "s") == "Desktop title")
    }

    @Test func fallsThroughWhenFirstIsNil() {
        // Models the setting being off: the Desktop resolver returns nil, transcript supplies it.
        let composite = CompositeTitleResolver([
            FakeResolver([:]),                        // disabled / empty Desktop resolver
            FakeResolver(["s": "Transcript title"]),
        ])
        #expect(composite.title(forSessionID: "s") == "Transcript title")
    }

    @Test func returnsNilWhenAllEmpty() {
        let composite = CompositeTitleResolver([FakeResolver([:]), FakeResolver([:])])
        #expect(composite.title(forSessionID: "s") == nil)
    }

    /// End-to-end fallback into `ClaudeSession.displayName`: Desktop off + no transcript title ⇒
    /// the row still falls back to the project folder name, exactly as today.
    @Test func displayNameFallbackChainUnchangedWhenDesktopOff() {
        let composite = CompositeTitleResolver([
            FakeResolver([:]),   // Desktop off
            FakeResolver([:]),   // no transcript title
        ])
        let now = Date()
        let base = ClaudeSession(
            id: "s", state: .working, event: .userPromptSubmit,
            startedAt: now, lastEventAt: now, projectName: "VibeMenu"
        )
        let titled = base.withTitle(composite.title(forSessionID: "s"))
        #expect(titled.displayName == "VibeMenu")   // folder-name fallback intact

        // And when the Desktop title is present, it becomes the display name.
        let onComposite = CompositeTitleResolver([FakeResolver(["s": "GMT time query"]), FakeResolver([:])])
        let onTitled = base.withTitle(onComposite.title(forSessionID: "s"))
        #expect(onTitled.displayName == "GMT time query")
    }
}
