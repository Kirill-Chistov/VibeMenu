import Foundation

// Reading Claude **Desktop**'s local usage data (docs/decisions/0016-claude-usage-limits.md).
//
// Claude Desktop is an Electron/Chromium app; when it renders Settings → Usage it fetches
// `GET https://claude.ai/api/organizations/{org}/usage` and Chromium stores the response in its
// "Simple Cache" on disk at `~/Library/Application Support/Claude/Cache/Cache_Data/<hash>_0`. The
// response body is **zstd-compressed** (`content-encoding: zstd`). This reader:
//
//   1. finds the cache entry whose key is the usage endpoint (byte-scanning the entry, robust to the
//      exact Chromium header layout — we never rely on private cache internals staying fixed),
//   2. decodes the first zstd frame inside it with the vendored decompressor (Sources/CZstd),
//   3. parses ONLY the whitelisted usage fields, and
//   4. normalises them into VibeMenu's own `ClaudeUsageLimitSnapshot`.
//
// It is strictly **read-only** and touches only Claude's cache; it never writes, deletes, or opens a
// network connection. It reads no cookies, no API keys, and no credentials. It decodes only the
// usage-limit fields and deliberately ignores the payload's `spend`/cost/billing and the org UUID
// (the UUID is never persisted). Everything here fails closed: a missing directory, an evicted or
// half-written entry, an empty (304-revalidated) body, a corrupt zstd frame, or an unexpected JSON
// shape all yield `.unavailable` rather than a crash.
//
// Split like the other readers: a pure, synthetic-data-tested parser + a thin, throttled I/O adapter.

// MARK: - Byte helpers

private extension Data {
    /// First index of `pattern` at or after `from`, or `nil`. Plain byte search (no allocation).
    func firstRange(of pattern: [UInt8], from: Int = 0) -> Int? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        return withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let last = count - pattern.count
            var i = Swift.max(0, from)
            while i <= last {
                var j = 0
                while j < pattern.count, base[i + j] == pattern[j] { j += 1 }
                if j == pattern.count { return i }
                i += 1
            }
            return nil
        }
    }

    func contains(ascii string: String, from: Int = 0) -> Bool {
        firstRange(of: Array(string.utf8), from: from) != nil
    }
}

// MARK: - Chromium Simple Cache entry recognition

/// Minimal, defensive recognition of a Chromium "Simple Cache" entry — just enough to tell whether an
/// entry is the usage endpoint and to pull the HTTP `Date` header for freshness. We intentionally do
/// NOT parse the full stream/EOF structure (it is undocumented and version-fragile); the body is
/// located by scanning for a decodable zstd frame instead, which is robust to layout changes.
public enum ChromiumSimpleCacheEntry {
    /// The Simple Cache file header magic (little-endian on disk). Used only as a cheap sanity check.
    static let headerMagic: [UInt8] = [0x30, 0x5c, 0x72, 0xa7, 0x1b, 0x6d, 0xfb, 0xfc]

    /// Whether the entry's key is the org usage endpoint: it contains `/api/organizations/` followed
    /// by `/usage`. Scans only the entry's head (keys live near the start), so this is cheap.
    public static func isUsageEndpoint(_ data: Data) -> Bool {
        // Fresh, zero-based copy of the head so all integer indexing below is slice-safe.
        let head = Data(data.prefix(2048))
        guard let orgIdx = head.firstRange(of: Array("/api/organizations/".utf8)) else { return false }
        return head.contains(ascii: "/usage", from: orgIdx)
    }

    /// Best-effort parse of the HTTP `Date:` response header (RFC 1123, GMT) embedded in the entry's
    /// metadata, used for staleness. Returns `nil` when absent/unparseable; callers fall back to the
    /// file's modification time.
    public static func httpDate(in data: Data) -> Date? {
        // Find a "date:" header key (ASCII, case-insensitive) and read the rest of that line.
        // Zero-based copy so `firstRange` offsets and the byte reads below share one index space,
        // regardless of whether `data` is a slice with a non-zero `startIndex`.
        let bytes = Data(data)
        for marker in [Array("\ndate:".utf8), Array("\nDate:".utf8), Array("date:".utf8), Array("Date:".utf8)] {
            guard let idx = bytes.firstRange(of: marker) else { continue }
            let start = idx + marker.count
            // Read the header value up to the first CR/LF (an RFC1123 date is 29 chars; cap at 48).
            let line: String = bytes.withUnsafeBytes { raw -> String in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return "" }
                var out: [UInt8] = []
                var i = start
                while i < raw.count, base[i] != 0x0D, base[i] != 0x0A, out.count < 48 {
                    out.append(base[i]); i += 1
                }
                return String(decoding: out, as: UTF8.self)
            }
            if let date = rfc1123(line.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    private static func rfc1123(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}

// MARK: - Usage payload parsing (whitelist)

/// Pure decode + normalisation of the Claude Desktop `/usage` JSON body into a snapshot. Handles both
/// observed shapes: a `limits[]` array (richer — may carry per-model weekly rows) and top-level
/// `five_hour` / `seven_day` window objects. Decodes ONLY the whitelisted usage fields; the DTO has no
/// property for `spend`/cost/billing or the org UUID, so those can never reach the model.
public enum ClaudeDesktopUsageParser {
    /// A reset time that may arrive as an ISO-8601 string or as epoch seconds; either decodes to a `Date`.
    struct FlexibleDate: Decodable {
        let date: Date?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                date = ClaudeDesktopUsageParser.parseISO(string)
            } else if let seconds = try? container.decode(Double.self) {
                date = Date(timeIntervalSince1970: seconds)
            } else {
                date = nil
            }
        }
    }

    private struct DTO: Decodable {
        struct Limit: Decodable {
            let kind: String?
            let group: String?
            let percent: Double?
            let resets_at: FlexibleDate?
            /// Present in the real payload but NOT a display filter: Claude marks only the single
            /// currently-binding limit `true` and the other (equally real) windows `false`, so
            /// filtering on it would drop the live 5-hour + weekly-all rows. Read but deliberately
            /// ignored. See docs/decisions/0016-claude-usage-limits.md.
            let is_active: Bool?
            /// A per-model weekly row carries its model under `scope.model.display_name`
            /// (e.g. "Fable"); the `group` field is a generic bucket ("weekly"/"session"), never a
            /// model name. Whitelisted to the display name only — no model id, no surface.
            let scope: Scope?
        }
        struct Scope: Decodable {
            struct Model: Decodable {
                let display_name: String?
            }
            let model: Model?
        }
        struct Window: Decodable {
            // The window's used percentage under any of the field names Claude has used.
            let utilization: Double?
            let used_percentage: Double?
            let percent: Double?
            let resets_at: FlexibleDate?

            var percentValue: Double? { utilization ?? used_percentage ?? percent }
        }
        let limits: [Limit]?
        let five_hour: Window?
        let seven_day: Window?
    }

    /// Parse the decoded JSON body into a snapshot, or `nil` when the body is not a usage object or
    /// carries no usable rows. `capturedAt` (the HTTP Date header or file mtime) drives staleness.
    public static func snapshot(fromJSONBody body: Data, capturedAt: Date?) -> ClaudeUsageLimitSnapshot? {
        guard let dto = try? JSONDecoder().decode(DTO.self, from: body) else { return nil }

        var rows: [ClaudeUsageLimit] = []

        // Preferred: the limits[] array. The real payload carries three rows — `session` (the
        // 5-hour window), `weekly_all` (weekly across all models), and `weekly_scoped` (a per-model
        // weekly row whose model is under `scope.model.display_name`). We do NOT filter on
        // `is_active` (Claude flags only the currently-binding row true; the others are equally real)
        // and we take the per-model identity from `scope`, never from the generic `group` bucket.
        if let limits = dto.limits {
            for limit in limits {
                guard let window = windowKind(limit.kind),
                      let percent = limit.percent, percent.isFinite else { continue }
                // Model name comes from `scope.model.display_name`; fall back to `group` for older
                // shapes. Either way `normalizedGroup` collapses generic buckets to nil, so the
                // all-models weekly row can never render as "Weekly · Weekly".
                let model = limit.scope?.model?.display_name ?? limit.group
                let group = window == .sevenDay ? normalizedGroup(model) : nil
                rows.append(ClaudeUsageLimit(
                    kind: window, usedPercent: percent, resetsAt: limit.resets_at?.date, group: group
                ))
            }
        }

        // Fallback: the top-level window objects (only when limits[] produced nothing).
        if rows.isEmpty {
            if let window = dto.five_hour, let percent = window.percentValue, percent.isFinite {
                rows.append(ClaudeUsageLimit(kind: .fiveHour, usedPercent: percent, resetsAt: window.resets_at?.date))
            }
            if let window = dto.seven_day, let percent = window.percentValue, percent.isFinite {
                rows.append(ClaudeUsageLimit(kind: .sevenDay, usedPercent: percent, resetsAt: window.resets_at?.date))
            }
        }

        let deduped = collapse(rows)
        guard !deduped.isEmpty else { return nil }
        return ClaudeUsageLimitSnapshot(
            limits: deduped, capturedAt: capturedAt, sessionID: nil, source: .desktopCache
        )
    }

    /// Decode the raw (zstd-compressed) cache-entry bytes into a snapshot: locate + decompress the
    /// body, then parse it. `capturedAt` is passed through from the caller (Date header / mtime).
    public static func snapshot(fromCacheEntry data: Data, capturedAt: Date?) -> ClaudeUsageLimitSnapshot? {
        guard ChromiumSimpleCacheEntry.isUsageEndpoint(data) else { return nil }
        let headerDate = ChromiumSimpleCacheEntry.httpDate(in: data) ?? capturedAt
        guard let body = Zstd.decompressFirstFrame(scanning: data) else { return nil }
        return snapshot(fromJSONBody: body, capturedAt: headerDate)
    }

    // MARK: Normalisation helpers

    /// Map a raw `kind` string to one of the two windows we model, tolerating naming variants.
    /// Claude's real payload names the 5-hour window `session` and the weekly windows `weekly_all` /
    /// `weekly_scoped`; the older/alt shape uses `five_hour` / `seven_day`. Weekly is matched before
    /// the 5-hour hour-heuristic can't misfire because none of the weekly names contain "hour".
    static func windowKind(_ raw: String?) -> ClaudeUsageLimitKind? {
        guard let value = raw?.lowercased() else { return nil }
        if value.contains("seven") || value.contains("7d") || value.contains("week")
            || value.contains("day") { return .sevenDay }
        if value.contains("session") || value.contains("five") || value.contains("5h")
            || value.contains("5_hour") || value.contains("hour") { return .fiveHour }
        return nil
    }

    /// A per-model weekly group name, or `nil` for the all-models rows. Recognises the common
    /// "everything" sentinels — including Claude's generic `weekly` / `session` / `weekly_all` bucket
    /// names, which must map to nil so the all-models row shows plain "Weekly", never "Weekly · Weekly"
    /// — and lightly prettifies a real model/group id for display.
    static func normalizedGroup(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        let generic: Set<String> = [
            "default", "all", "all_models", "all models", "all model", "overall", "none", "null",
            "total", "weekly", "weekly_all", "weekly_scoped", "session", "seven_day", "five_hour",
        ]
        if generic.contains(lower) { return nil }
        return prettifyGroup(trimmed)
    }

    /// Turn an id like `claude_sonnet_4` / `claude-3-5-sonnet` into a compact display name ("Sonnet").
    /// Conservative: if nothing recognisable is found, return the cleaned raw string.
    static func prettifyGroup(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
        for family in ["opus", "sonnet", "haiku", "fable"] where cleaned.contains(family) {
            return family.capitalized
        }
        // Fallback: Title-case the cleaned string, dropping a leading "claude".
        let words = cleaned.split(separator: " ").map(String.init).filter { $0 != "claude" }
        let titled = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return titled.isEmpty ? raw : titled
    }

    /// Collapse duplicates: at most one 5-hour row (the highest percent wins when several arrive) and
    /// one row per weekly (kind, group) pair. Keeps ordering deterministic downstream via the snapshot.
    private static func collapse(_ rows: [ClaudeUsageLimit]) -> [ClaudeUsageLimit] {
        var byID: [String: ClaudeUsageLimit] = [:]
        for row in rows {
            let key = row.kind == .fiveHour ? "5h" : row.id   // fold any per-group 5-hour into one row
            if let existing = byID[key], existing.usedPercent >= row.usedPercent { continue }
            byID[key] = row
        }
        return Array(byID.values)
    }

    static func parseISO(_ string: String) -> Date? {
        // Try fractional-seconds first, then plain — covers the ISO-8601 variants Claude emits.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

// MARK: - I/O adapter

/// Read-only, throttled scanner of Claude Desktop's cache directory. Conforms to
/// `ClaudeUsageLimitReading` so it drops into the same provider/model plumbing as the statusLine
/// reader. Efficiency for a menu-bar app: it only looks at *small*, *recently modified* entries (the
/// usage entry is a few KB and rewritten often), caps how many it reads, and throttles full rescans —
/// so a tick is cheap even though the cache holds hundreds of large blobs.
public final class ClaudeDesktopUsageCacheReader: ClaudeUsageLimitReading, @unchecked Sendable {
    private let cacheDirectory: URL
    private let now: @Sendable () -> Date
    private let minRescanInterval: TimeInterval
    private let maxEntrySize: Int
    private let maxEntriesScanned: Int

    private let lock = NSLock()
    private var lastScan: Date?
    private var cached: ClaudeUsageLimitSnapshot = .unavailable

    private struct Candidate { let url: URL; let mtime: Date }

    public init(
        cacheDirectory: URL = ClaudeDesktopUsageCacheReader.defaultCacheDirectory,
        now: @escaping @Sendable () -> Date = { Date() },
        minRescanInterval: TimeInterval = 15,
        maxEntrySize: Int = 256 * 1024,
        maxEntriesScanned: Int = 160
    ) {
        self.cacheDirectory = cacheDirectory
        self.now = now
        self.minRescanInterval = minRescanInterval
        self.maxEntrySize = maxEntrySize
        self.maxEntriesScanned = maxEntriesScanned
    }

    /// `~/Library/Application Support/Claude/Cache/Cache_Data`.
    public static var defaultCacheDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Claude/Cache/Cache_Data", isDirectory: true)
    }

    public func readSnapshot() -> ClaudeUsageLimitSnapshot {
        let current = now()
        lock.lock()
        if let last = lastScan, current.timeIntervalSince(last) < minRescanInterval {
            defer { lock.unlock() }
            return cached
        }
        lock.unlock()

        let snapshot = scan(now: current)

        lock.lock()
        lastScan = current
        // Only replace the cached value when we found data; a transient empty (304) scan keeps the
        // last good decode so the model can show it as stale rather than blinking to "unavailable".
        if snapshot.hasData { cached = snapshot }
        let result = cached
        lock.unlock()
        return result
    }

    /// One full scan: small + recently-modified entries first, first decodable usage body wins.
    private func scan(now current: Date) -> ClaudeUsageLimitSnapshot {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return .unavailable }

        // Keep only small regular files (the usage entry is tiny; this drops big media/blob entries
        // cheaply via metadata, never reading their contents), newest first.
        var candidates: [Candidate] = []
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey, .isRegularFileKey
            ]), values.isRegularFile == true,
                let size = values.fileSize, size > 0, size <= maxEntrySize
            else { continue }
            candidates.append(Candidate(url: url, mtime: values.contentModificationDate ?? .distantPast))
        }
        candidates.sort { $0.mtime > $1.mtime }
        let scanList = candidates.prefix(maxEntriesScanned)

        var best: (snapshot: ClaudeUsageLimitSnapshot, captured: Date)?
        for candidate in scanList {
            // Plain copying read (NOT .mappedIfSafe): the entries are tiny (≤ maxEntrySize) and Claude
            // Desktop actively rewrites the newest ones, so a memory-mapped read could SIGBUS if the
            // file is truncated in place mid-scan. Copying the bytes fails closed instead.
            guard let data = try? Data(contentsOf: candidate.url) else { continue }
            guard let snapshot = ClaudeDesktopUsageParser.snapshot(
                fromCacheEntry: data, capturedAt: candidate.mtime
            ) else { continue }
            let captured = snapshot.capturedAt ?? candidate.mtime
            if best == nil || captured > best!.captured {
                best = (snapshot, captured)
            }
        }
        return best?.snapshot ?? .unavailable
    }
}
