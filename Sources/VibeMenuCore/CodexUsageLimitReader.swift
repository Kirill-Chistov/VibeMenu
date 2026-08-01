import Foundation

// Reading Codex Desktop usage limits from the rollout files (docs/decisions/0017-codex-session-support.md).
//
// Codex writes a `token_count` event on every assistant turn, carrying a structured `rate_limits`
// object with one or more **windows** (`primary`, `secondary`, …). This adapter finds the **newest**
// such reading from a recent Codex Desktop rollout and turns it into a `CodexUsageLimitSnapshot` that
// holds exactly the windows that newest reading exposed — no more, no fewer.
//
// ### Schema-driven, no resurrection
//
// The window set is not assumed. A window is any `rate_limits` child object carrying a numeric
// `used_percent`; its `window_minutes` labels it and its `resets_at` times it. This keeps only real
// windows (the sibling `credits` object has no `used_percent`, so it is ignored), copes with one, two,
// or more windows, and never assumes `primary`/`secondary` mean a fixed duration. The reading takes
// its windows **verbatim from the single newest authoritative `token_count`** — it never merges/carries
// a window forward from an earlier event, so a window Codex stopped exposing disappears instead of
// lingering.
//
// Authoritativeness follows the product requirement. A `token_count` whose `rate_limits` is a valid
// JSON **object** is authoritative *even when it yields zero windows* (empty `{}`, or only non-window
// siblings like `credits`): it truthfully reports the current window set — possibly none — so it
// clears previously-shown rows and, if it is the newest reading across rollouts, wins over an older
// rollout that still had windows. Only a **missing** `rate_limits`, a non-object `rate_limits`, or a
// malformed line is ignored (it can neither add nor clear rows); a rollout with no valid `rate_limits`
// object at all yields no reading.
//
// ### The privacy boundary (two layers)
//
//  1. **Numeric allowlist (the actual boundary).** From a `token_count` line we read ONLY each
//     window's `used_percent`, `window_minutes`, and `resets_at` as numbers (plus the window's slot
//     *key*, a structural label like `"primary"` — never content), and from `session_meta` ONLY
//     `originator` (Desktop gate) and whether `source` is a subagent. Nothing else — not `info`/token
//     counts, not `plan_type`/`limit_id`/account, not `credits`, not any message body — is touched or
//     stored. The output types structurally cannot hold content. This holds even for a line that is
//     JSON-decoded but isn't a `token_count`/`session_meta` we care about: nothing is extracted.
//  2. **Substring pre-check (fast-path / defense-in-depth).** A line is JSON-decoded only if it
//     contains `rate_limits` or `originator`, so the vast majority of prompt / response / tool lines
//     are skipped un-parsed. (A conversation line whose *text* happens to contain the literal
//     "rate_limits" is still decoded, but layer 1 extracts nothing from it — so this is an
//     optimisation, not the safety guarantee.)
//
// Fail-closed: a missing directory or no recent authoritative Codex Desktop reading yields
// `.unavailable` rather than fabricated numbers. A newer rollout that lacks `rate_limits` is
// ignored — it does not erase an older authoritative reading. Display-only — never keeps the Mac
// awake.

/// The safe, allowlisted rate-limit reading from one rollout file: the windows the newest authoritative
/// `token_count` exposed (possibly none), plus the metadata needed to gate (originator/subagent) and age
/// it (capturedAt). A returned reading is always authoritative — its mere existence means a valid
/// `rate_limits` object was seen; its `windows` being empty means Codex currently exposes no windows.
/// Contains only numbers + structural slot keys + the originator string — no content, path, account, auth.
public struct CodexRateLimitReading: Equatable, Sendable {
    /// Every window from the newest authoritative `token_count`, in arrival order (the snapshot sorts
    /// them). Empty when that reading exposed no qualifying windows.
    public let windows: [CodexUsageLimit]
    /// When Codex wrote the newest `token_count` this reading came from (its line timestamp, else the
    /// file mtime) — drives freshness.
    public let capturedAt: Date
    /// The rollout's `originator` (verbatim), for the Desktop gate.
    public let originator: String
    /// Whether the rollout is an internal subagent run (dropped by the reader).
    public let isSubagent: Bool

    public init(
        windows: [CodexUsageLimit],
        capturedAt: Date,
        originator: String,
        isSubagent: Bool
    ) {
        self.windows = windows
        self.capturedAt = capturedAt
        self.originator = originator
        self.isSubagent = isSubagent
    }

    /// The windows this reading exposes.
    public var limits: [CodexUsageLimit] { windows }

    /// Whether this authoritative reading carries at least one window. `false` is a *valid* state — an
    /// authoritative-empty reading — not "no reading"; the reader still uses it (to clear rows). It is
    /// deliberately no longer a gate on whether the reading counts.
    public var hasLimits: Bool { !windows.isEmpty }

    /// The display snapshot for this reading (source `.rollout`).
    public func snapshot() -> CodexUsageLimitSnapshot {
        CodexUsageLimitSnapshot(limits: windows, capturedAt: capturedAt, source: .rollout)
    }
}

/// Pure parser for a rollout file's rate limits. I/O-free and malformed-safe; unit-tested against
/// synthetic fixtures.
public enum CodexRateLimitRollout {
    /// Parse the **newest authoritative** `token_count.rate_limits` reading (and the originator/subagent
    /// gate) from one rollout file's text, or `nil` when the rollout has no authoritative reading at all
    /// (no `session_meta` originator, or no `token_count` ever carried a valid `rate_limits` object).
    ///
    /// Authoritativeness is per the product requirement:
    ///   * a **missing** `rate_limits`, a non-object `rate_limits`, or a malformed line → **ignored**
    ///     (it can neither add nor clear rows); if a file has only these, this returns `nil`.
    ///   * a **valid `rate_limits` object with zero qualifying windows** (empty `{}`, or only non-window
    ///     siblings like `credits`) → an **authoritative empty** reading: it wins by timestamp like any
    ///     other and its emptiness clears rows. It is NOT skipped.
    ///   * a **valid `rate_limits` object with ≥1 window** → an authoritative reading of exactly those
    ///     windows.
    /// The windows are taken verbatim from the single newest authoritative event — nothing is merged or
    /// carried forward across events, so a window Codex stops emitting simply vanishes.
    ///
    /// `fallbackCaptured` (the file mtime, supplied by the reader) is used only if a `token_count`
    /// line carries no parseable timestamp.
    public static func parseLatest(text: String, fallbackCaptured: Date? = nil) -> CodexRateLimitReading? {
        var originator: String?
        var isSubagent = false
        var sawRateLimits = false
        var newestCaptured: Date?
        var newestWindows: [CodexUsageLimit] = []

        // Local ISO formatters (fractional first, then plain); `ISO8601DateFormatter` isn't Sendable,
        // so a shared static would be a concurrency hazard.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        func parseTimestamp(_ string: String) -> Date? {
            isoFractional.date(from: string) ?? isoPlain.date(from: string)
        }

        var scanned = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            scanned += 1
            if scanned > 200_000 { break }
            // Privacy + speed pre-check: only decode the two line kinds we read. Prompt/response/
            // reasoning/tool lines never contain these markers, so they are skipped un-parsed.
            guard rawLine.contains("rate_limits") || rawLine.contains("originator") else { continue }
            guard let data = rawLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let line = object as? [String: Any],
                  let type = line["type"] as? String,
                  let payload = line["payload"] as? [String: Any] else { continue }

            switch type {
            case "session_meta":
                if originator == nil { originator = payload["originator"] as? String }
                if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                    isSubagent = true
                }
            case "event_msg":
                // A missing / non-object `rate_limits` (or a malformed line, filtered above) is ignored:
                // it never becomes a reading, so it can neither add nor clear rows.
                guard payload["type"] as? String == "token_count",
                      let rateLimits = payload["rate_limits"] as? [String: Any] else { continue }
                // A valid `rate_limits` OBJECT is authoritative even when it yields zero windows (empty
                // `{}` or credits-only): it truthfully reports "Codex exposes these windows right now" —
                // possibly none. So we record it (never `continue` on empty) and let emptiness clear rows.
                sawRateLimits = true
                let captured = (line["timestamp"] as? String).flatMap(parseTimestamp)
                    ?? fallbackCaptured ?? Date(timeIntervalSince1970: 0)
                if let newestCaptured, captured < newestCaptured { continue }
                newestCaptured = captured
                // Take this reading's windows verbatim — REPLACE, never merge. A window absent here is
                // absent, full stop; it is not carried forward from an earlier event.
                newestWindows = parseWindows(rateLimits)
            default:
                break
            }
        }

        guard let originator else { return nil }
        // No valid `rate_limits` object anywhere ⇒ this rollout has no authoritative reading; it must
        // NOT contribute a phantom empty reading (which would wrongly clear rows), so return `nil`.
        guard sawRateLimits, let capturedAt = newestCaptured else { return nil }
        return CodexRateLimitReading(
            windows: newestWindows,
            capturedAt: capturedAt, originator: originator, isSubagent: isSubagent
        )
    }

    /// Extract every usage-limit window from one `rate_limits` object, schema-driven. A window is any
    /// child object carrying a numeric `used_percent`; we read ONLY that (required) plus the numeric
    /// `window_minutes` (for the label) and `resets_at` (both optional), and the child's slot *key*
    /// (a structural label like `"primary"`, never content). Any sibling without a numeric
    /// `used_percent` — e.g. Codex's `credits` object — is not a window and is skipped. Nothing else in
    /// the object is read.
    static func parseWindows(_ rateLimits: [String: Any]) -> [CodexUsageLimit] {
        var windows: [CodexUsageLimit] = []
        for (slot, value) in rateLimits {
            guard let dict = value as? [String: Any], let used = number(dict["used_percent"]) else { continue }
            // Guard the Int conversion: `Int(Double)` traps on NaN/inf or an out-of-Int64 value, and a
            // rollout is Codex-controlled / version-fragile, so a garbage `window_minutes` must fail
            // closed (⇒ nil ⇒ neutral label) rather than crash the reader. A non-positive duration is
            // likewise treated as "no provable duration".
            let windowMinutes: Int? = number(dict["window_minutes"]).flatMap { raw in
                guard raw.isFinite, raw >= 1, raw < Double(Int.max) else { return nil }
                return Int(raw.rounded())
            }
            let resetsAt = number(dict["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            windows.append(CodexUsageLimit(
                windowMinutes: windowMinutes, usedPercent: used, resetsAt: resetsAt, slot: slot
            ))
        }
        return windows
    }

    /// Coerce a JSON number (Int or Double, bridged as `NSNumber`) to `Double`; `nil` for anything
    /// non-numeric. Never coerces a string, so a text value can't sneak in as a percentage.
    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}

// MARK: - File adapter

/// Reads the current Codex usage-limit snapshot. The seam lets the observable model be driven by a
/// fake in tests with no real `~/.codex` directory.
public protocol CodexUsageLimitReading: AnyObject, Sendable {
    /// The latest snapshot, or `.unavailable` when no usable Codex Desktop reading exists.
    func readSnapshot() -> CodexUsageLimitSnapshot
}

/// The real reader over `~/.codex/sessions`: finds the newest Codex Desktop rollout that carries a
/// `rate_limits` reading and returns its snapshot. Any error / no data ⇒ `.unavailable`.
///
/// Concurrency: `@unchecked Sendable` — it holds only immutable configuration; each `readSnapshot`
/// call is a self-contained read with no shared mutable state.
public final class CodexUsageLimitReader: CodexUsageLimitReading, @unchecked Sendable {
    /// `~/.codex/sessions` — shared with the session reader; the originator gate keeps only Desktop.
    public static var defaultSessionsDirectory: URL { CodexSessionReader.defaultSessionsDirectory }

    /// Only rollout files modified within this window are opened. Wider than session detection (60 min)
    /// so a recent-but-idle limits reading survives a gap between sessions as honest, aged
    /// "last-known-good"; still bounded so the walk stays cheap.
    public static let defaultRecencyHorizon: TimeInterval = 24 * 60 * 60

    /// Never open more than this many candidate files per tick.
    public static let maxFilesScanned = 60

    /// Per-file read cap. Larger files fall back to a head+tail read so `session_meta` (head) and the
    /// newest `token_count` (tail) survive while the bulky middle is skipped.
    public static let defaultMaxFileBytes = 4 * 1024 * 1024
    public static let defaultHeadTailBytes = 64 * 1024

    private let directory: URL
    private let recencyHorizon: TimeInterval
    private let maxFileBytes: Int
    private let headTailBytes: Int
    private let fileManager: FileManager

    public init(
        directory: URL? = nil,
        recencyHorizon: TimeInterval = CodexUsageLimitReader.defaultRecencyHorizon,
        maxFileBytes: Int = CodexUsageLimitReader.defaultMaxFileBytes,
        headTailBytes: Int = CodexUsageLimitReader.defaultHeadTailBytes,
        fileManager: FileManager = .default
    ) {
        self.directory = directory ?? Self.defaultSessionsDirectory
        self.recencyHorizon = recencyHorizon
        self.maxFileBytes = maxFileBytes
        self.headTailBytes = headTailBytes
        self.fileManager = fileManager
    }

    public func readSnapshot() -> CodexUsageLimitSnapshot {
        let now = Date()
        let cutoff = now.addingTimeInterval(-recencyHorizon)
        // Candidate files, newest-mtime-first. We want the reading with the newest *capture time*
        // (`capturedAt`), which isn't always the newest-mtime file: a file can be touched by a
        // non-turn event after its last `token_count`. Since a `token_count`'s timestamp is always ≤
        // its file's mtime, once we hold a best capture we can stop as soon as a file's mtime can't
        // beat it — so this normally parses just one or two files.
        let files = CodexSessionReader.recentRolloutFiles(
            in: directory, modifiedAfter: cutoff, limit: Self.maxFilesScanned, fileManager: fileManager
        )
        var best: CodexRateLimitReading?
        for file in files {
            if let best, file.modificationDate <= best.capturedAt { break }
            guard let data = readCapped(file.url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            // `parseLatest` returns nil for a rollout with no authoritative reading (no valid
            // `rate_limits` object), so such files are ignored. An authoritative reading is considered
            // even when it has zero windows: a newer authoritative-empty reading must win over an older
            // reading with limits and clear the rows — so we compare purely by capture time, not on
            // whether the reading has windows.
            guard let reading = CodexRateLimitRollout.parseLatest(
                text: text, fallbackCaptured: file.modificationDate
            ),
                  CodexRolloutParser.isDesktopOriginator(reading.originator),
                  !reading.isSubagent else { continue }
            if best == nil || reading.capturedAt > best!.capturedAt {
                best = reading
            }
        }
        // A non-nil `best` is authoritative; its snapshot (possibly empty) is what to display. Only when
        // no authoritative reading exists at all do we fall back to `.unavailable`.
        return best?.snapshot() ?? .unavailable
    }

    /// Read a rollout file under the byte cap. Small files whole; a larger file as head+tail (joined by
    /// a newline) so `session_meta` (head) and the trailing newest `token_count` (tail) survive.
    func readCapped(_ url: URL) -> Data? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size <= maxFileBytes {
            return try? Data(contentsOf: url)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headTailBytes)) ?? Data()
        if size > headTailBytes {
            try? handle.seek(toOffset: UInt64(size - headTailBytes))
        }
        let tail = (try? handle.readToEnd()) ?? Data()
        var combined = head
        combined.append(0x0A)
        combined.append(tail)
        return combined
    }
}
