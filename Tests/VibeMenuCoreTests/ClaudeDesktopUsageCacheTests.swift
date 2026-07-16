import Foundation
import Testing
@testable import VibeMenuCore

// Claude Desktop usage-cache reader tests (docs/decisions/0016-claude-usage-limits.md). Everything is
// synthetic: raw JSON bodies are hand-written with fake numbers, and the compressed cache bodies are
// zstd frames generated offline (Node) and pasted as base64 — NO real account data or real cache
// payload is committed. We verify the whitelist parse of both payload shapes, that spend/cost/org
// fields can never surface, the Chromium-entry recognition + Date parsing, the full compressed-entry
// decode, the throttled directory scanner, source selection, and last-known-good persistence.

// MARK: - Fixtures (synthetic)

/// A `limits[]` usage body in the **real** Claude Desktop shape (sanitized, fake numbers): the
/// 5-hour window is `kind:"session"`, the weekly windows are `weekly_all` / `weekly_scoped`, the
/// per-model identity is under `scope.model.display_name` ("Fable"/"Sonnet") — NOT the generic
/// `group` bucket ("weekly"/"session") — and `is_active` flags only the currently-binding row.
/// Includes a forbidden spend block and secret model ids to prove the whitelist never surfaces them.
private let limitsBodyJSON = #"""
{
  "five_hour": {
    "limit_dollars": null,
    "remaining_dollars": null,
    "resets_at": "2026-07-09T20:40:00Z",
    "used_dollars": null,
    "utilization": 14
  },
  "seven_day": {
    "limit_dollars": null,
    "remaining_dollars": null,
    "resets_at": "2026-07-12T13:00:00Z",
    "used_dollars": null,
    "utilization": 50
  },
  "limits": [
    {
      "kind": "session",
      "group": "session",
      "is_active": false,
      "percent": 14,
      "resets_at": "2026-07-09T20:40:00Z",
      "scope": null,
      "severity": "normal"
    },
    {
      "kind": "weekly_all",
      "group": "weekly",
      "is_active": false,
      "percent": 50,
      "resets_at": "2026-07-12T13:00:00Z",
      "scope": null,
      "severity": "normal"
    },
    {
      "kind": "weekly_scoped",
      "group": "weekly",
      "is_active": true,
      "percent": 59,
      "resets_at": "2026-07-12T13:00:00Z",
      "scope": {
        "model": {
          "display_name": "Fable",
          "id": "SECRET-MODEL-ID-1"
        },
        "surface": null
      },
      "severity": "normal"
    },
    {
      "kind": "weekly_scoped",
      "group": "weekly",
      "is_active": false,
      "percent": 30,
      "resets_at": "2026-07-12T13:00:00Z",
      "scope": {
        "model": {
          "display_name": "Sonnet",
          "id": "SECRET-MODEL-ID-2"
        },
        "surface": null
      },
      "severity": "normal"
    }
  ],
  "spend": {
    "used": {
      "amount_minor": 1234,
      "currency": "USD",
      "exponent": 2
    },
    "percent": 5,
    "disclaimer": "SECRET-COST-9.99"
  },
  "member_dashboard_available": false
}
"""#

/// zstd(limitsBodyJSON) — the exact bytes Node's `zlib.zstdCompressSync` produced from the JSON
/// string above (offline; no real cache payload committed).
private let limitsBodyZstdB64 = "KLUv/WBsBWUPAJZWRiQwjfNArzKSzJbwy0Yk29iCTa90/h72GMpo8WvfGJQGFlYYUAE7ADoAPgC1+ay8oNRSi6UcCKSYAcUIOMrhXUybTerTAT78fi4BnKtwF0/ZzsXG6L93vLu7UHaxrPGB+fQS3l0oAe5SjBYN9Ei65NO1ZBf79DRqNl+qUTrwLow/p88GH4J3GdSjlqKBOM2kG4M++eTK7rJodjGMT3vi3dMQxodSRC2RdXKFG6ZRwBg4GggHDMSRwHA8nt1FmoBfQzZpJ81v7LzFx7vQUyVt6nGu2cRBuEew6ycjZPrSp5XFfU/NmuwYeZjdmPTI88cQFAAxkAcCQ/r7dtHjwChJODceChF0KWukcJoI/zEKa3zNuxSXJjfsLg71TKiBHUNIUEZCQUFBkuVAAiIgNJV2EuACLQYxJWSMcGaMESDhBCiGgokWPLokAEnk70xFlGCWYQyQrApZA49TD0tOBnTe0w7smeCCweE4ZWjDJq4Xum9fVX+pigLGnaymKvYDCEG+6nmBfHl4DpBz2lMzz0fmMRBH39I4s2g64mnn9KT25/w588ZAli6FCKw/BXggiIRQoaaUcECztrIHnt93MipzwcgxRdd8J0zft3CIbzRixd+Edgqh2IElo9pYkwTjR0abG0tDVeT5umdWAQ=="

/// Top-level five_hour / seven_day window shape (no `limits[]`).
private let windowBodyZstdB64 = "KLUv/SCF5QIAcsUTGoC5OeixrcWUpvMCCqlZJAR6Kf6VL59uyJwRzVEl45IqEIywjlyy+TQe/HgA/gzBUeCouJ/Ry1bbbJn43KEPRJcl9KCrmEEnCmJYuWjBTAMAIDOgYFPM4Qw="

private func b64(_ s: String) -> Data { Data(base64Encoded: s)! }

/// Build a synthetic Chromium Simple Cache entry: header magic + usage key + a zstd body + trailing
/// HTTP metadata (with a Date header). Mirrors the real entry closely enough to exercise the reader.
private func makeUsageCacheEntry(bodyB64: String, date: String? = "Wed, 09 Jul 2026 17:00:00 GMT") -> Data {
    var entry = Data([0x30, 0x5c, 0x72, 0xa7, 0x1b, 0x6d, 0xfb, 0xfc]) // simple-cache header magic
    entry.append(Data("\u{0}\u{0}\u{0}\u{0}1/0/https://claude.ai/api/organizations/00000000-0000-0000-0000-000000000000/usage".utf8))
    entry.append(b64(bodyB64))
    if let date {
        entry.append(Data("\r\nHTTP/1.1 200 OK\r\ndate: \(date)\r\ncontent-encoding:zstd\r\n".utf8))
    }
    return entry
}

private func rfc1123(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: string)!
}

// MARK: - Payload parsing

@Suite("ClaudeDesktopUsageParser (limits[] shape)")
struct DesktopLimitsParseTests {
    private func parsed() -> ClaudeUsageLimitSnapshot? {
        ClaudeDesktopUsageParser.snapshot(fromJSONBody: Data(limitsBodyJSON.utf8), capturedAt: nil)
    }

    @Test func producesOrderedRowsWithPerModelWeekly() throws {
        let snapshot = try #require(parsed())
        #expect(snapshot.source == .desktopCache)
        // 5-hour (from kind:"session"), Weekly all-models (weekly_all), then per-model weekly
        // (weekly_scoped) alphabetically by model — Fable before Sonnet. The all-models row reads a
        // plain "Weekly", never the duplicate "Weekly · Weekly".
        #expect(snapshot.limits.map(\.displayLabel) == [
            "5-hour limit", "Weekly", "Weekly · Fable", "Weekly · Sonnet",
        ])
        #expect(snapshot.limits.map { Int($0.usedPercent) } == [14, 50, 59, 30])
    }

    @Test func extractsFiveHourRowFromSessionKind() throws {
        let snapshot = try #require(parsed())
        let fiveHour = try #require(snapshot.limits.first { $0.kind == .fiveHour })
        #expect(fiveHour.displayLabel == "5-hour limit")
        #expect(Int(fiveHour.usedPercent) == 14)
        #expect(fiveHour.resetsAt != nil)
        #expect(fiveHour.group == nil)   // the 5-hour window is always all-models
    }

    @Test func extractsWeeklyAllModelsRow() throws {
        let snapshot = try #require(parsed())
        let weekly = try #require(snapshot.limits.first { $0.kind == .sevenDay && $0.group == nil })
        #expect(weekly.displayLabel == "Weekly")
        #expect(Int(weekly.usedPercent) == 50)
    }

    @Test func isActiveDoesNotFilterRows() throws {
        // In the real payload only the model-scoped weekly row is is_active:true, yet the base 5-hour
        // and weekly-all windows (is_active:false) are equally real and must still appear.
        let snapshot = try #require(parsed())
        #expect(snapshot.limits.contains { $0.kind == .fiveHour })            // session, is_active:false
        #expect(snapshot.limits.contains { $0.kind == .sevenDay && $0.group == nil })  // weekly_all, false
        #expect(snapshot.limits.count == 4)
    }

    @Test func neverProducesDuplicateWeeklyLabel() throws {
        let snapshot = try #require(parsed())
        #expect(!snapshot.limits.contains { $0.displayLabel == "Weekly · Weekly" })
        // The generic bucket ("weekly"/"session") is never carried as a group.
        #expect(!snapshot.limits.contains { ($0.group ?? "").lowercased() == "weekly" })
        #expect(!snapshot.limits.contains { ($0.group ?? "").lowercased() == "session" })
    }

    @Test func perModelWeeklyUsesScopeModelDisplayName() throws {
        let snapshot = try #require(parsed())
        #expect(snapshot.limits.contains { $0.displayLabel == "Weekly · Fable" })
        #expect(snapshot.limits.contains { $0.displayLabel == "Weekly · Sonnet" })
    }

    @Test func idsAreUniqueAcrossWeeklyRows() throws {
        let snapshot = try #require(parsed())
        #expect(Set(snapshot.limits.map(\.id)).count == snapshot.limits.count)
    }

    @Test func neverSurfacesSpendCostOrModelIDs() throws {
        let snapshot = try #require(parsed())
        // The model has no cost field at all, and only usage windows are produced. Re-encoding the
        // snapshot must not carry the forbidden spend/cost markers nor the scope model ids anywhere.
        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("SECRET-COST"))
        #expect(!text.contains("SECRET-MODEL-ID"))
        #expect(!text.lowercased().contains("amount_minor"))
        #expect(!text.lowercased().contains("disclaimer"))
    }

    @Test func resetsAtParsedForActiveRows() throws {
        let snapshot = try #require(parsed())
        #expect(snapshot.limits.first?.resetsAt != nil)
    }
}

@Suite("ClaudeDesktopUsageParser (window shape + edge cases)")
struct DesktopWindowParseTests {
    @Test func parsesTopLevelWindowShape() throws {
        let json = #"{"five_hour":{"utilization":22,"resets_at":"2026-07-09T20:40:00Z"},"seven_day":{"utilization":63,"resets_at":"2026-07-12T13:00:00Z"}}"#
        let snapshot = try #require(
            ClaudeDesktopUsageParser.snapshot(fromJSONBody: Data(json.utf8), capturedAt: nil)
        )
        #expect(snapshot.limits.map(\.kind) == [.fiveHour, .sevenDay])
        #expect(snapshot.limits.map { Int($0.usedPercent) } == [22, 63])
    }

    @Test func prefersLimitsOverTopLevelWindows() throws {
        let json = #"""
        {"limits":[{"kind":"five_hour","percent":14,"is_active":true}],
         "five_hour":{"utilization":99},"seven_day":{"utilization":99}}
        """#
        let snapshot = try #require(
            ClaudeDesktopUsageParser.snapshot(fromJSONBody: Data(json.utf8), capturedAt: nil)
        )
        #expect(snapshot.limits.count == 1)
        #expect(snapshot.limits.first?.usedPercent == 14)   // from limits[], not the window's 99
    }

    @Test func returnsNilWhenNoUsableRows() {
        #expect(ClaudeDesktopUsageParser.snapshot(fromJSONBody: Data(#"{"spend":{"percent":5}}"#.utf8), capturedAt: nil) == nil)
        #expect(ClaudeDesktopUsageParser.snapshot(fromJSONBody: Data("not json".utf8), capturedAt: nil) == nil)
        #expect(ClaudeDesktopUsageParser.snapshot(fromJSONBody: Data(#"{"limits":[]}"#.utf8), capturedAt: nil) == nil)
    }

    @Test func windowKindMappingToleratesVariants() {
        // Real Claude payload names.
        #expect(ClaudeDesktopUsageParser.windowKind("session") == .fiveHour)
        #expect(ClaudeDesktopUsageParser.windowKind("weekly_all") == .sevenDay)
        #expect(ClaudeDesktopUsageParser.windowKind("weekly_scoped") == .sevenDay)
        // Older / alternate shape names.
        #expect(ClaudeDesktopUsageParser.windowKind("five_hour") == .fiveHour)
        #expect(ClaudeDesktopUsageParser.windowKind("5h") == .fiveHour)
        #expect(ClaudeDesktopUsageParser.windowKind("FIVE_HOUR") == .fiveHour)
        #expect(ClaudeDesktopUsageParser.windowKind("seven_day") == .sevenDay)
        #expect(ClaudeDesktopUsageParser.windowKind("7d") == .sevenDay)
        #expect(ClaudeDesktopUsageParser.windowKind("weekly") == .sevenDay)
        #expect(ClaudeDesktopUsageParser.windowKind("monthly") == nil)
        #expect(ClaudeDesktopUsageParser.windowKind(nil) == nil)
    }

    @Test func groupNormalizationAndPrettify() {
        #expect(ClaudeDesktopUsageParser.normalizedGroup(nil) == nil)
        #expect(ClaudeDesktopUsageParser.normalizedGroup("default") == nil)
        #expect(ClaudeDesktopUsageParser.normalizedGroup("all_models") == nil)
        // Claude's generic bucket names collapse to nil so the all-models row is never "Weekly · Weekly".
        #expect(ClaudeDesktopUsageParser.normalizedGroup("weekly") == nil)
        #expect(ClaudeDesktopUsageParser.normalizedGroup("session") == nil)
        #expect(ClaudeDesktopUsageParser.normalizedGroup("weekly_all") == nil)
        #expect(ClaudeDesktopUsageParser.normalizedGroup("claude_sonnet_4") == "Sonnet")
        #expect(ClaudeDesktopUsageParser.normalizedGroup("claude-3-5-haiku") == "Haiku")
        #expect(ClaudeDesktopUsageParser.normalizedGroup("Opus") == "Opus")
        #expect(ClaudeDesktopUsageParser.normalizedGroup("Fable") == "Fable")
    }

    @Test func resetsAtAcceptsEpochNumber() throws {
        let json = #"{"limits":[{"kind":"five_hour","percent":10,"resets_at":2000,"is_active":true}]}"#
        let snapshot = try #require(
            ClaudeDesktopUsageParser.snapshot(fromJSONBody: Data(json.utf8), capturedAt: nil)
        )
        #expect(snapshot.limits.first?.resetsAt == Date(timeIntervalSince1970: 2000))
    }

    @Test func collapsesDuplicateFiveHourKeepingHighest() throws {
        let json = #"""
        {"limits":[{"kind":"five_hour","group":"a","percent":10,"is_active":true},
                   {"kind":"five_hour","group":"b","percent":40,"is_active":true}]}
        """#
        let snapshot = try #require(
            ClaudeDesktopUsageParser.snapshot(fromJSONBody: Data(json.utf8), capturedAt: nil)
        )
        #expect(snapshot.limits.count == 1)
        #expect(snapshot.limits.first?.usedPercent == 40)
        #expect(snapshot.limits.first?.group == nil)   // 5-hour is always all-models
    }
}

// MARK: - Chromium entry recognition

@Suite("ChromiumSimpleCacheEntry")
struct ChromiumEntryTests {
    @Test func recognisesUsageEndpoint() {
        #expect(ChromiumSimpleCacheEntry.isUsageEndpoint(makeUsageCacheEntry(bodyB64: limitsBodyZstdB64)))
    }

    @Test func rejectsNonUsageEntries() {
        #expect(!ChromiumSimpleCacheEntry.isUsageEndpoint(Data("1/0/https://claude.ai/api/organizations/x/projects".utf8)))
        #expect(!ChromiumSimpleCacheEntry.isUsageEndpoint(Data("1/0/https://example.com/usage".utf8)))
        #expect(!ChromiumSimpleCacheEntry.isUsageEndpoint(Data()))
    }

    @Test func parsesHTTPDateHeader() {
        let entry = makeUsageCacheEntry(bodyB64: limitsBodyZstdB64, date: "Wed, 09 Jul 2026 17:00:00 GMT")
        #expect(ChromiumSimpleCacheEntry.httpDate(in: entry) == rfc1123("Wed, 09 Jul 2026 17:00:00 GMT"))
    }

    @Test func httpDateNilWhenAbsentOrGarbage() {
        #expect(ChromiumSimpleCacheEntry.httpDate(in: makeUsageCacheEntry(bodyB64: limitsBodyZstdB64, date: nil)) == nil)
        #expect(ChromiumSimpleCacheEntry.httpDate(in: Data("date: not-a-date\r\n".utf8)) == nil)
    }
}

// MARK: - Full compressed-entry decode

@Suite("ClaudeDesktopUsageParser.snapshot(fromCacheEntry:)")
struct DesktopCacheEntryDecodeTests {
    @Test func decodesRealCompressedEntryEndToEnd() throws {
        let entry = makeUsageCacheEntry(bodyB64: limitsBodyZstdB64)
        let snapshot = try #require(ClaudeDesktopUsageParser.snapshot(fromCacheEntry: entry, capturedAt: nil))
        #expect(snapshot.source == .desktopCache)
        #expect(snapshot.limits.map(\.displayLabel) == [
            "5-hour limit", "Weekly", "Weekly · Fable", "Weekly · Sonnet",
        ])
        // capturedAt comes from the entry's Date header.
        #expect(snapshot.capturedAt == rfc1123("Wed, 09 Jul 2026 17:00:00 GMT"))
    }

    @Test func windowShapeEntryDecodes() throws {
        let entry = makeUsageCacheEntry(bodyB64: windowBodyZstdB64)
        let snapshot = try #require(ClaudeDesktopUsageParser.snapshot(fromCacheEntry: entry, capturedAt: nil))
        #expect(snapshot.limits.map { Int($0.usedPercent) } == [22, 63])
    }

    @Test func nonUsageEntryReturnsNil() {
        let notUsage = Data("1/0/https://claude.ai/api/organizations/x/projects some bytes".utf8)
        #expect(ClaudeDesktopUsageParser.snapshot(fromCacheEntry: notUsage, capturedAt: nil) == nil)
    }

    @Test func emptyBody304EntryReturnsNil() {
        // A revalidated entry: correct key, but no zstd frame (empty body) → nil, not a crash.
        var entry = Data("\u{0}\u{0}\u{0}\u{0}1/0/https://claude.ai/api/organizations/x/usage".utf8)
        entry.append(Data("\r\nHTTP/1.1 304 Not Modified\r\ndate: Wed, 09 Jul 2026 17:05:00 GMT\r\n".utf8))
        #expect(ClaudeDesktopUsageParser.snapshot(fromCacheEntry: entry, capturedAt: nil) == nil)
    }
}

// MARK: - Directory scanner (I/O adapter)

@Suite("ClaudeDesktopUsageCacheReader")
struct DesktopReaderTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ data: Data, named name: String, in dir: URL) throws {
        try data.write(to: dir.appendingPathComponent(name))
    }

    @Test func readsUsageEntryFromDirectory() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write(makeUsageCacheEntry(bodyB64: limitsBodyZstdB64), named: "aaaa_0", in: dir)
        try write(Data("unrelated cache blob".utf8), named: "bbbb_0", in: dir)

        let reader = ClaudeDesktopUsageCacheReader(cacheDirectory: dir)
        let snapshot = reader.readSnapshot()
        #expect(snapshot.source == .desktopCache)
        #expect(snapshot.limits.count == 4)
    }

    @Test func missingDirectoryIsUnavailable() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("vm-missing-\(UUID().uuidString)")
        #expect(ClaudeDesktopUsageCacheReader(cacheDirectory: missing).readSnapshot() == .unavailable)
    }

    @Test func emptyDirectoryIsUnavailable() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ClaudeDesktopUsageCacheReader(cacheDirectory: dir).readSnapshot() == .unavailable)
    }

    @Test func keepsLastGoodWhenBodyLaterVanishes() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let entryURL = dir.appendingPathComponent("aaaa_0")
        try makeUsageCacheEntry(bodyB64: limitsBodyZstdB64).write(to: entryURL)

        // A clock we can advance so the throttle lets the second scan run.
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_000_000) }
        let clock = Clock()
        let reader = ClaudeDesktopUsageCacheReader(
            cacheDirectory: dir, now: { clock.t }, minRescanInterval: 5
        )
        #expect(reader.readSnapshot().limits.count == 4)

        // The cache entry is revalidated to an empty 304 stub; a fresh scan finds no body...
        try Data("\u{0}\u{0}\u{0}\u{0}1/0/https://claude.ai/api/organizations/x/usage\r\ndate: x\r\n".utf8).write(to: entryURL)
        clock.t = clock.t.addingTimeInterval(10)
        // ...but the reader keeps its last good decode rather than blinking to unavailable.
        #expect(reader.readSnapshot().limits.count == 4)
    }

    @Test func throttleReturnsCachedWithinInterval() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let entryURL = dir.appendingPathComponent("aaaa_0")
        try makeUsageCacheEntry(bodyB64: limitsBodyZstdB64).write(to: entryURL)

        let reader = ClaudeDesktopUsageCacheReader(
            cacheDirectory: dir, now: { Date(timeIntervalSince1970: 5_000) }, minRescanInterval: 60
        )
        #expect(reader.readSnapshot().limits.count == 4)
        // Delete the file; because the clock is frozen inside the throttle window, the cached value stands.
        try FileManager.default.removeItem(at: entryURL)
        #expect(reader.readSnapshot().limits.count == 4)
    }
}
