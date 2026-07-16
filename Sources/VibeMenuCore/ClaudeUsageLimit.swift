import Foundation

// Claude usage limits — the real, server-side 5-hour + weekly utilisation Claude Code
// reports (docs/decisions/0016-claude-usage-limits.md). This is the pure, I/O-free,
// SwiftUI-free model + deterministic formatting; the file reading and the opt-in capture
// live in thin adapters (ClaudeUsageLimitReader / the statusLine shim), mirroring how the
// heartbeat record (ClaudeHeartbeat.swift) splits its pure decode from the provider.
//
// ### Where the numbers come from (and why they are real, not estimated)
//
// Claude Code hands a `rate_limits` object to any configured `statusLine` command on stdin
// (added in Claude Code v2.1.80): `rate_limits.five_hour.{used_percentage, resets_at}` and
// `rate_limits.seven_day.{used_percentage, resets_at}`. `used_percentage` is the SAME
// server-side utilisation the in-app `/usage` view shows (0–100), and `resets_at` is a Unix
// epoch-seconds reset time. VibeMenu's opt-in statusLine shim captures ONLY those fields into
// a VibeMenu-owned file; this model parses that file. No token-count estimation, no network,
// no cookies, no API keys, no reading of Claude's transcripts (docs/PRIVACY.md, AGENTS.md §6).
//
// ### Honest limitations (surfaced in the UI, never hidden)
//
// `rate_limits` is populated only for Claude.ai Pro/Max subscribers, only after the first API
// response of an interactive session, and each window can be independently absent; it is also
// version-fragile. So the snapshot models `.fresh` / `.stale` / `.unavailable` explicitly and
// the UI shows a stale/"as of" or unavailable message rather than ever presenting old data as
// live. The statusLine payload carries the 5-hour and overall weekly windows — not the
// per-model weekly breakdown — so VibeMenu shows those two rows and omits per-model unless a
// future source provides it (see the ADR's "Future: Codex / per-model" note).

// MARK: - Kind

/// Which usage window a limit row describes. Deliberately small and stable — the two windows
/// the statusLine payload reliably carries. `sortOrder` gives the radar-style deterministic
/// ordering (5-hour first, then weekly), and `label` is the exact row label shown in the menu.
///
/// Extensible: a future source (the Desktop `/usage` cache, or Codex) could add per-model
/// weekly kinds; the UI and parser already iterate the array, so adding a case is additive.
public enum ClaudeUsageLimitKind: String, Codable, Equatable, Sendable, CaseIterable {
    /// The rolling 5-hour session window.
    case fiveHour
    /// The rolling weekly ("7-day") window across all models.
    case sevenDay

    /// The exact left-hand label shown in the menu row. The weekly *all-models* row is just
    /// "Weekly" — a model suffix is appended (→ "Weekly · Fable") only for a real per-model row,
    /// so the all-models row never reads as the duplicate "Weekly · Weekly".
    public var label: String {
        switch self {
        case .fiveHour: "5-hour limit"
        case .sevenDay: "Weekly"
        }
    }

    /// Deterministic display order (ascending). Keeps rows stable regardless of the order the
    /// windows arrive in the file.
    public var sortOrder: Int {
        switch self {
        case .fiveHour: 0
        case .sevenDay: 1
        }
    }
}

// MARK: - Severity

/// Subtle severity used only for a restrained colour accent on the progress bar / percent —
/// never for alarm. Thresholds are intentionally conservative so most rows read as neutral.
public enum ClaudeUsageLimitSeverity: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical
}

// MARK: - Limit

/// One usage-limit row: a window, its used percentage (0…100), and when it resets.
///
/// `usedPercent` is clamped to 0…100 at init so a malformed/overflowing value can never
/// produce a bar wider than full or a negative fraction. `resetsAt` is optional because a
/// window can arrive with a percentage but no reset time.
public struct ClaudeUsageLimit: Equatable, Sendable, Codable, Identifiable {
    public let kind: ClaudeUsageLimitKind
    /// Server-side utilisation, 0…100 (clamped).
    public let usedPercent: Double
    /// Absolute reset time for this window, or `nil` when the source omitted it.
    public let resetsAt: Date?
    /// For a per-model weekly row, the model/group name (e.g. "Sonnet"); `nil` for the all-models
    /// rows and the 5-hour row. Only the Desktop cache source populates this; the statusLine source
    /// carries the two all-models windows only, so it always leaves this `nil`.
    public let group: String?

    public init(
        kind: ClaudeUsageLimitKind,
        usedPercent: Double,
        resetsAt: Date?,
        group: String? = nil
    ) {
        self.kind = kind
        self.usedPercent = Self.clampPercent(usedPercent)
        self.resetsAt = resetsAt
        let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.group = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Stable identity for SwiftUI `ForEach` — unique across the (kind, group) pairs a snapshot can
    /// hold, so multiple weekly rows (all-models + per-model) never collide on `kind` alone.
    public var id: String { "\(kind.rawValue)#\(group ?? "")" }

    /// Stable, **normalized** identifier used to persist the per-row *visibility* preference across
    /// relaunches (see `ClaudeUsageLimitVisibility`). Unlike `id` — a SwiftUI `ForEach` key that
    /// embeds the raw group verbatim — this collapses case/whitespace and treats a generic weekly
    /// bucket as the all-models row, so "Fable", "fable" and "  Fable " all map to one id. That keeps
    /// a hide/show choice pinned to the row even when a source re-emits the model name with different
    /// casing, and matches the three ids the task calls for:
    ///   * `fiveHour`                    — the 5-hour row (always all-models; any group is ignored),
    ///   * `sevenDay`                    — the weekly all-models row,
    ///   * `sevenDay#<normalized group>` — a model-specific weekly row.
    public var visibilityID: String {
        switch kind {
        case .fiveHour:
            return "fiveHour"
        case .sevenDay:
            guard let group, !Self.isRedundantWeeklyGroup(group) else { return "sevenDay" }
            return "sevenDay#\(Self.normalizedVisibilityGroup(group))"
        }
    }

    /// Normalize a model/group name for a stable visibility id: lowercase, trim, and collapse any
    /// internal whitespace run to a single space. Deterministic and locale-independent.
    static func normalizedVisibilityGroup(_ group: String) -> String {
        group.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The exact left-hand row label. The 5-hour and all-models rows use the window's fixed label
    /// ("5-hour limit" / "Weekly"); a per-model weekly row reads "Weekly · <model>". A group that is
    /// just a generic bucket ("Weekly", "all models", …) is treated as no group, so the label can
    /// never duplicate itself into "Weekly · Weekly" even if a source leaves a generic group set.
    public var displayLabel: String {
        if kind == .sevenDay, let group, !Self.isRedundantWeeklyGroup(group) {
            return "Weekly · \(group)"
        }
        return kind.label
    }

    /// Generic weekly buckets that must never become a "Weekly · …" suffix (they would duplicate the
    /// base "Weekly" label). A real model name ("Fable", "Opus", "Sonnet") is kept. Defensive second
    /// line after the Desktop parser's `normalizedGroup`, and it also cleans up any already-persisted
    /// snapshot that stored a generic group before this fix.
    static func isRedundantWeeklyGroup(_ group: String) -> Bool {
        [
            "weekly", "weekly_all", "weekly_scoped", "all", "all models", "all model", "all_models",
            "overall", "total", "session",
        ].contains(group.lowercased())
    }

    /// Deterministic composite ordering: 5-hour first, then Weekly all-models, then per-model weekly
    /// rows alphabetically. Kept as a comparable string so `sorted(by:)` stays simple and stable.
    public var sortKey: String {
        switch kind {
        case .fiveHour: return "0"
        case .sevenDay: return group == nil ? "1" : "2\(group!.lowercased())"
        }
    }

    /// Clamp to 0…100, mapping NaN/inf to 0 so downstream formatting/geometry is always sane.
    static func clampPercent(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        return min(100, max(0, raw))
    }

    /// Fraction 0…1 for the progress bar width.
    public var fraction: Double { usedPercent / 100 }

    /// Right-aligned percent text, e.g. `14%`. Rounded to a whole number to match the app UI.
    public var percentText: String { "\(Int(usedPercent.rounded()))%" }

    /// Conservative severity for a restrained colour accent (≥90 critical, ≥75 warning).
    public var severity: ClaudeUsageLimitSeverity {
        switch usedPercent {
        case ..<75: .normal
        case ..<90: .warning
        default: .critical
        }
    }

    /// Deterministic reset text matching the app style:
    ///   * within `relativeWindow` (default 24 h) → relative, e.g. `Resets in 2 hr 40 min`;
    ///   * further out → absolute weekday + time, e.g. `Resets Sun 1:00 PM`;
    ///   * already elapsed / < 1 min away → `Resets soon`;
    ///   * no known reset time → `Reset time unknown`.
    ///
    /// `now`/`calendar` are injectable so the formatting is fully unit-testable (a fixed
    /// calendar + POSIX locale yields stable strings independent of the test machine).
    public func resetText(
        now: Date,
        calendar: Calendar = .current,
        relativeWindow: TimeInterval = 24 * 60 * 60
    ) -> String {
        guard let resetsAt else { return "Reset time unknown" }
        let interval = resetsAt.timeIntervalSince(now)
        if interval < 60 { return "Resets soon" }
        if interval < relativeWindow {
            let totalMinutes = Int(interval / 60)
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours > 0 && minutes > 0 { return "Resets in \(hours) hr \(minutes) min" }
            if hours > 0 { return "Resets in \(hours) hr" }
            return "Resets in \(minutes) min"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE h:mm a"
        return "Resets \(formatter.string(from: resetsAt))"
    }
}

// MARK: - Source

/// Where a snapshot came from. Kept as an explicit enum so the UI/settings can honestly name
/// the source and so a future provider (Codex) is additive.
public enum ClaudeUsageLimitSource: String, Codable, Equatable, Sendable {
    /// The opt-in Claude Code statusLine shim (CLI-native `rate_limits`).
    case statusLine
    /// The Claude **Desktop** app's local HTTP cache for the usage endpoint (zstd-decoded locally).
    /// Experimental / best-effort: unofficial format, LRU-evictable, may vanish if Claude changes it.
    case desktopCache
    /// No usable source produced data (missing file, feature off, corrupt file).
    case unavailable

    /// Short, honest label for Settings ("detected source: …").
    public var displayName: String {
        switch self {
        case .statusLine: "Claude Code (status line)"
        case .desktopCache: "Claude Desktop (local cache)"
        case .unavailable: "None"
        }
    }
}

/// Which source(s) the user wants VibeMenu to read, chosen in Settings. `auto` prefers the richer /
/// fresher of the two; the explicit modes pin a single source. Persisted as a raw string.
public enum ClaudeUsageLimitSourceMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// Prefer a fresh Desktop-cache snapshot (richer: per-model rows); otherwise the statusLine snapshot.
    case auto
    /// Only the Claude Desktop local cache.
    case desktopCache
    /// Only the Claude Code status-line capture.
    case claudeCode

    public var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .desktopCache: "Claude Desktop"
        case .claudeCode: "Claude Code"
        }
    }
}

// MARK: - Settings header summary

/// Pure, deterministic text for the *collapsed* "Claude usage limits" settings header, so the
/// summary the user sees when the section is folded is unit-testable without any SwiftUI or file I/O.
///
/// Produces `Off` when the feature is disabled, otherwise `On` joined with the (optional) source
/// name and freshness by ` · ` — e.g. `On · Claude Desktop · live` or `On · Waiting for data`.
public enum ClaudeUsageLimitsSummary {
    public static func collapsedHeader(
        enabled: Bool,
        sourceName: String?,
        freshness: String?
    ) -> String {
        guard enabled else { return "Off" }
        var parts = ["On"]
        if let sourceName, !sourceName.isEmpty { parts.append(sourceName) }
        if let freshness, !freshness.isEmpty { parts.append(freshness) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Status

/// The freshness of a snapshot at a given moment. Load-bearing for honesty: the UI shows
/// `.stale` as an "as of Xm ago" note and `.unavailable` as an explanatory message — it never
/// renders `.stale`/`.unavailable` data as if it were live.
public enum ClaudeUsageLimitStatus: Equatable, Sendable {
    /// Fresh data captured within the staleness window.
    case fresh
    /// Data older than the staleness window; `age` is how long ago it was captured.
    case stale(age: TimeInterval)
    /// No usable limit rows at all.
    case unavailable
}

// MARK: - Snapshot

/// A parsed set of usage-limit rows plus the metadata needed to judge freshness. Pure value
/// type: `Codable`/`Equatable` for testing and for a future on-disk cache, with no SwiftUI or
/// I/O. `limits` is always sorted by `kind.sortOrder` so row order is deterministic.
public struct ClaudeUsageLimitSnapshot: Equatable, Sendable, Codable {
    public let limits: [ClaudeUsageLimit]
    /// When the statusLine shim captured this snapshot, or `nil` when unknown/unavailable.
    public let capturedAt: Date?
    /// The Claude session id the capture came from (opaque; never shown). `nil` when absent.
    public let sessionID: String?
    public let source: ClaudeUsageLimitSource

    public init(
        limits: [ClaudeUsageLimit],
        capturedAt: Date?,
        sessionID: String?,
        source: ClaudeUsageLimitSource
    ) {
        self.limits = limits.sorted { $0.sortKey < $1.sortKey }
        self.capturedAt = capturedAt
        self.sessionID = sessionID
        self.source = source
    }

    /// The canonical "nothing to show" snapshot.
    public static let unavailable = ClaudeUsageLimitSnapshot(
        limits: [], capturedAt: nil, sessionID: nil, source: .unavailable
    )

    /// Default staleness threshold. statusLine refreshes each assistant message during an
    /// interactive session; once the session ends it stops updating. 10 minutes flags a
    /// clearly-idle capture as stale while tolerating brief gaps between renders. (The reset
    /// *countdown* stays correct regardless, since it is computed from the absolute `resetsAt`.)
    public static let defaultStaleThreshold: TimeInterval = 10 * 60

    /// Whether there is at least one row to display.
    public var hasData: Bool { !limits.isEmpty }

    /// Freshness at `now`. `.unavailable` when there are no rows; `.stale` when the capture is
    /// older than `staleThreshold`; otherwise `.fresh`. A `nil` `capturedAt` with rows is
    /// treated as fresh (we have data but no timestamp to age it against).
    public func status(
        now: Date,
        staleThreshold: TimeInterval = defaultStaleThreshold
    ) -> ClaudeUsageLimitStatus {
        guard hasData else { return .unavailable }
        guard let capturedAt else { return .fresh }
        let age = now.timeIntervalSince(capturedAt)
        return age > staleThreshold ? .stale(age: age) : .fresh
    }

    /// A compact "as of Xm ago" / "as of Xh ago" note for a stale capture, or `nil` when fresh
    /// or unavailable. Used by the UI to be honest about age without hiding the data.
    public func ageNote(now: Date, staleThreshold: TimeInterval = defaultStaleThreshold) -> String? {
        guard case let .stale(age) = status(now: now, staleThreshold: staleThreshold) else { return nil }
        let minutes = Int(age / 60)
        if minutes < 60 { return "as of \(max(1, minutes))m ago" }
        let hours = minutes / 60
        if hours < 24 { return "as of \(hours)h ago" }
        return "as of \(hours / 24)d ago"
    }
}
