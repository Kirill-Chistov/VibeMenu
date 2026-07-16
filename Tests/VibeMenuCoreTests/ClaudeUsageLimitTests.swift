import Foundation
import Testing
@testable import VibeMenuCore

// Claude usage-limit model tests (docs/decisions/0016-claude-usage-limits.md). Everything here is
// pure/synthetic — fixtures are hand-written JSON with fake numbers (no real account data). We verify
// clamping, percent/reset formatting, snapshot freshness, deterministic ordering, the whitelist-only
// file parse (corrupt/missing/extra-field tolerant), and the read-only file adapter.

// A fixed calendar so reset formatting is deterministic regardless of the test machine's locale/TZ.
private func fixedCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

// MARK: - Kind

@Suite("ClaudeUsageLimitKind")
struct ClaudeUsageLimitKindTests {
    @Test func labelsMatchTheScreenshot() {
        #expect(ClaudeUsageLimitKind.fiveHour.label == "5-hour limit")
        // The all-models weekly row is just "Weekly"; a model suffix is added only for a per-model row.
        #expect(ClaudeUsageLimitKind.sevenDay.label == "Weekly")
    }

    @Test func fiveHourSortsBeforeWeekly() {
        #expect(ClaudeUsageLimitKind.fiveHour.sortOrder < ClaudeUsageLimitKind.sevenDay.sortOrder)
    }
}

// MARK: - Limit value semantics

@Suite("ClaudeUsageLimit value semantics")
struct ClaudeUsageLimitValueTests {
    @Test func clampsPercentIntoRange() {
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: -5, resetsAt: nil).usedPercent == 0)
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 150, resetsAt: nil).usedPercent == 100)
        // Non-finite values (NaN and ±infinity) map to 0 — the documented safe fallback.
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: .nan, resetsAt: nil).usedPercent == 0)
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: .infinity, resetsAt: nil).usedPercent == 0)
    }

    @Test func fractionAndPercentText() {
        let limit = ClaudeUsageLimit(kind: .fiveHour, usedPercent: 50, resetsAt: nil)
        #expect(limit.fraction == 0.5)
        #expect(limit.percentText == "50%")
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 14.6, resetsAt: nil).percentText == "15%")
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 0, resetsAt: nil).percentText == "0%")
    }

    @Test func severityThresholds() {
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 74, resetsAt: nil).severity == .normal)
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 75, resetsAt: nil).severity == .warning)
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 89, resetsAt: nil).severity == .warning)
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 90, resetsAt: nil).severity == .critical)
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 100, resetsAt: nil).severity == .critical)
    }
}

// MARK: - Reset formatting

@Suite("ClaudeUsageLimit.resetText")
struct ClaudeUsageResetTextTests {
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    private func limit(resetInSeconds seconds: TimeInterval?) -> ClaudeUsageLimit {
        ClaudeUsageLimit(
            kind: .fiveHour,
            usedPercent: 14,
            resetsAt: seconds.map { now.addingTimeInterval($0) }
        )
    }

    @Test func relativeHoursAndMinutes() {
        // 2 h 40 min out → matches the attached design ("Resets in 2 hr 40 min").
        #expect(limit(resetInSeconds: 2 * 3600 + 40 * 60).resetText(now: now) == "Resets in 2 hr 40 min")
    }

    @Test func relativeMinutesOnly() {
        #expect(limit(resetInSeconds: 40 * 60).resetText(now: now) == "Resets in 40 min")
    }

    @Test func relativeWholeHours() {
        #expect(limit(resetInSeconds: 2 * 3600).resetText(now: now) == "Resets in 2 hr")
    }

    @Test func soonWhenUnderAMinuteOrPast() {
        #expect(limit(resetInSeconds: 30).resetText(now: now) == "Resets soon")
        #expect(limit(resetInSeconds: -100).resetText(now: now) == "Resets soon")
    }

    @Test func unknownWhenNoResetTime() {
        #expect(limit(resetInSeconds: nil).resetText(now: now) == "Reset time unknown")
    }

    @Test func absoluteWeekdayTimeBeyondADay() {
        // Build a reset that is the next Sunday 1:00 PM in the fixed calendar → "Resets Sun 1:00 PM".
        let calendar = fixedCalendar()
        var day = calendar.date(byAdding: .day, value: 2, to: now)!   // ≥24 h out
        // Walk forward to the next Sunday (Gregorian .weekday == 1).
        while calendar.component(.weekday, from: day) != 1 {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        let onePM = calendar.date(
            bySettingHour: 13, minute: 0, second: 0, of: day
        )!
        let limit = ClaudeUsageLimit(kind: .sevenDay, usedPercent: 50, resetsAt: onePM)
        #expect(limit.resetText(now: now, calendar: calendar) == "Resets Sun 1:00 PM")
    }
}

// MARK: - Snapshot

@Suite("ClaudeUsageLimitSnapshot")
struct ClaudeUsageSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    @Test func limitsAreSortedByKind() {
        let snapshot = ClaudeUsageLimitSnapshot(
            limits: [
                ClaudeUsageLimit(kind: .sevenDay, usedPercent: 50, resetsAt: nil),
                ClaudeUsageLimit(kind: .fiveHour, usedPercent: 14, resetsAt: nil),
            ],
            capturedAt: now, sessionID: nil, source: .statusLine
        )
        #expect(snapshot.limits.map(\.kind) == [.fiveHour, .sevenDay])
    }

    @Test func unavailableWhenEmpty() {
        #expect(ClaudeUsageLimitSnapshot.unavailable.status(now: now) == .unavailable)
        #expect(!ClaudeUsageLimitSnapshot.unavailable.hasData)
    }

    @Test func freshWithinThreshold() {
        let snapshot = ClaudeUsageLimitSnapshot(
            limits: [ClaudeUsageLimit(kind: .fiveHour, usedPercent: 14, resetsAt: nil)],
            capturedAt: now.addingTimeInterval(-60), sessionID: nil, source: .statusLine
        )
        #expect(snapshot.status(now: now) == .fresh)
        #expect(snapshot.ageNote(now: now) == nil)
    }

    @Test func staleBeyondThreshold() {
        let snapshot = ClaudeUsageLimitSnapshot(
            limits: [ClaudeUsageLimit(kind: .fiveHour, usedPercent: 14, resetsAt: nil)],
            capturedAt: now.addingTimeInterval(-11 * 60), sessionID: nil, source: .statusLine
        )
        guard case .stale = snapshot.status(now: now) else {
            Issue.record("expected stale"); return
        }
        #expect(snapshot.ageNote(now: now) == "as of 11m ago")
    }

    @Test func hasDataWithNilTimestampCountsFresh() {
        let snapshot = ClaudeUsageLimitSnapshot(
            limits: [ClaudeUsageLimit(kind: .fiveHour, usedPercent: 14, resetsAt: nil)],
            capturedAt: nil, sessionID: nil, source: .statusLine
        )
        #expect(snapshot.status(now: now) == .fresh)
    }

    @Test func codableRoundTrip() throws {
        let snapshot = ClaudeUsageLimitSnapshot(
            limits: [
                ClaudeUsageLimit(kind: .fiveHour, usedPercent: 14, resetsAt: now),
                ClaudeUsageLimit(kind: .sevenDay, usedPercent: 50, resetsAt: now.addingTimeInterval(3600)),
            ],
            capturedAt: now, sessionID: "abc", source: .statusLine
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ClaudeUsageLimitSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }
}

// MARK: - File parsing

@Suite("ClaudeUsageLimitFile.parse")
struct ClaudeUsageParseTests {
    @Test func parsesBothWindows() {
        let json = Data(#"""
        {"schemaVersion":1,"capturedAt":1000,"sessionID":"s-1","cliVersion":"2.1.202",
         "fiveHour":{"usedPercent":14.0,"resetsAt":2000},
         "sevenDay":{"usedPercent":50.0,"resetsAt":3000}}
        """#.utf8)
        let snapshot = ClaudeUsageLimitFile.parse(fileData: json)
        #expect(snapshot?.limits.count == 2)
        #expect(snapshot?.limits.map(\.kind) == [.fiveHour, .sevenDay])
        #expect(snapshot?.limits.first?.usedPercent == 14)
        #expect(snapshot?.limits.first?.resetsAt == Date(timeIntervalSince1970: 2000))
        #expect(snapshot?.capturedAt == Date(timeIntervalSince1970: 1000))
        #expect(snapshot?.sessionID == "s-1")
        #expect(snapshot?.source == .statusLine)
    }

    @Test func parsesSingleWindow() {
        let json = Data(#"{"capturedAt":1000,"fiveHour":{"usedPercent":14.0,"resetsAt":2000}}"#.utf8)
        let snapshot = ClaudeUsageLimitFile.parse(fileData: json)
        #expect(snapshot?.limits.map(\.kind) == [.fiveHour])
    }

    @Test func validObjectWithNoWindowsIsEmptyNotNil() {
        let snapshot = ClaudeUsageLimitFile.parse(fileData: Data(#"{"capturedAt":1000}"#.utf8))
        #expect(snapshot != nil)
        #expect(snapshot?.limits.isEmpty == true)
        #expect(snapshot?.status(now: Date(timeIntervalSince1970: 1000)) == .unavailable)
    }

    @Test func windowWithoutPercentIsDropped() {
        let json = Data(#"{"fiveHour":{"resetsAt":2000}}"#.utf8)
        #expect(ClaudeUsageLimitFile.parse(fileData: json)?.limits.isEmpty == true)
    }

    @Test func percentWithoutResetStillParses() {
        let json = Data(#"{"fiveHour":{"usedPercent":14.0}}"#.utf8)
        let snapshot = ClaudeUsageLimitFile.parse(fileData: json)
        #expect(snapshot?.limits.first?.usedPercent == 14)
        #expect(snapshot?.limits.first?.resetsAt == nil)
    }

    @Test func malformedJSONReturnsNil() {
        #expect(ClaudeUsageLimitFile.parse(fileData: Data("not json".utf8)) == nil)
        #expect(ClaudeUsageLimitFile.parse(fileData: Data()) == nil)
        #expect(ClaudeUsageLimitFile.parse(fileData: Data("[1,2,3]".utf8)) == nil)
    }

    /// Forbidden/extra fields present in the file are ignored — the DTO has no property for them, so
    /// they can never reach the model, exactly like the heartbeat whitelist.
    @Test func ignoresNonWhitelistedFields() {
        let json = Data(#"""
        {"capturedAt":1000,"fiveHour":{"usedPercent":14.0,"resetsAt":2000},
         "cost":{"total_cost_usd":9.99},"transcript_path":"/secret.jsonl","cwd":"/Users/x/private"}
        """#.utf8)
        let snapshot = ClaudeUsageLimitFile.parse(fileData: json)
        #expect(snapshot?.limits.count == 1)
        #expect(snapshot?.limits.first?.usedPercent == 14)
    }
}

// MARK: - File reader adapter

@Suite("FileClaudeUsageLimitReader")
struct ClaudeUsageReaderTests {
    private func writeTemp(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-usage-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func readsValidFile() throws {
        let url = try writeTemp(#"{"capturedAt":1000,"fiveHour":{"usedPercent":14.0,"resetsAt":2000}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = FileClaudeUsageLimitReader(url: url).readSnapshot()
        #expect(snapshot.limits.map(\.kind) == [.fiveHour])
    }

    @Test func missingFileIsUnavailable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-usage-missing-\(UUID().uuidString).json")
        #expect(FileClaudeUsageLimitReader(url: url).readSnapshot() == .unavailable)
    }

    @Test func corruptFileIsUnavailable() throws {
        let url = try writeTemp("{ truncated")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileClaudeUsageLimitReader(url: url).readSnapshot() == .unavailable)
    }
}

// MARK: - Per-model rows (group) + sources

@Suite("ClaudeUsageLimit group / displayLabel / ordering")
struct ClaudeUsageGroupTests {
    @Test func displayLabelUsesGroupOnlyForWeekly() {
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 10, resetsAt: nil).displayLabel == "5-hour limit")
        // A group on the 5-hour row is ignored — the 5-hour window is always all-models.
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 10, resetsAt: nil, group: "Opus").displayLabel == "5-hour limit")
        #expect(ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil).displayLabel == "Weekly")
        #expect(ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil, group: "Sonnet").displayLabel == "Weekly · Sonnet")
    }

    @Test func displayLabelNeverDuplicatesForGenericWeeklyGroup() {
        // Defensive second line: even if a source leaves a generic bucket in `group`, the row must
        // read plain "Weekly" — never "Weekly · Weekly" — so an already-persisted pre-fix snapshot
        // (which stored group:"Weekly") renders correctly too.
        for generic in ["Weekly", "weekly", "all models", "All models", "session"] {
            #expect(
                ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil, group: generic).displayLabel == "Weekly"
            )
        }
        // A real model name is still shown.
        #expect(ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil, group: "Fable").displayLabel == "Weekly · Fable")
    }

    @Test func blankGroupNormalisesToNil() {
        #expect(ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil, group: "   ").group == nil)
        #expect(ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil, group: "").group == nil)
    }

    @Test func idIsUniquePerKindAndGroup() {
        let all = ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil)
        let sonnet = ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil, group: "Sonnet")
        let opus = ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil, group: "Opus")
        #expect(Set([all.id, sonnet.id, opus.id]).count == 3)
    }

    @Test func snapshotSortsFiveHourThenAllModelsThenPerModelAlphabetical() {
        let snapshot = ClaudeUsageLimitSnapshot(
            limits: [
                ClaudeUsageLimit(kind: .sevenDay, usedPercent: 1, resetsAt: nil, group: "Sonnet"),
                ClaudeUsageLimit(kind: .sevenDay, usedPercent: 1, resetsAt: nil, group: "Opus"),
                ClaudeUsageLimit(kind: .sevenDay, usedPercent: 1, resetsAt: nil),
                ClaudeUsageLimit(kind: .fiveHour, usedPercent: 1, resetsAt: nil),
            ],
            capturedAt: nil, sessionID: nil, source: .desktopCache
        )
        #expect(snapshot.limits.map(\.displayLabel) == [
            "5-hour limit", "Weekly", "Weekly · Opus", "Weekly · Sonnet",
        ])
    }

    @Test func groupSurvivesCodableRoundTrip() throws {
        let snapshot = ClaudeUsageLimitSnapshot(
            limits: [ClaudeUsageLimit(kind: .sevenDay, usedPercent: 30, resetsAt: nil, group: "Opus")],
            capturedAt: nil, sessionID: nil, source: .desktopCache
        )
        let decoded = try JSONDecoder().decode(
            ClaudeUsageLimitSnapshot.self, from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(decoded.source == .desktopCache)
        #expect(decoded.limits.first?.group == "Opus")
    }

    @Test func sourceDisplayNames() {
        #expect(ClaudeUsageLimitSource.statusLine.displayName == "Claude Code (status line)")
        #expect(ClaudeUsageLimitSource.desktopCache.displayName == "Claude Desktop (local cache)")
    }
}
