import Foundation

// Codex Desktop usage limits — the real, server-side utilisation windows Codex reports
// (docs/decisions/0017-codex-session-support.md). Pure, I/O-free, SwiftUI-free model + deterministic
// formatting; the rollout reading lives in the thin `CodexUsageLimitReader` adapter, mirroring how
// `ClaudeUsageLimit` splits its pure model from `ClaudeUsageLimitReader`.
//
// ### Where the numbers come from (and why they are real, not estimated)
//
// Codex Desktop appends a `token_count` event to its rollout files
// (`~/.codex/sessions/**/rollout-*.jsonl`) on every assistant turn. Each carries a structured
// `rate_limits` object holding one or more **windows** — child objects keyed `primary`, `secondary`,
// … each with:
//   * `used_percent`   (0…100 — the SAME server-side utilisation Codex's own usage view shows),
//   * `window_minutes` (the window's rolling duration in minutes — e.g. 300 = 5-hour, 10080 = weekly),
//   * `resets_at`      (Unix epoch seconds).
// VibeMenu's parser extracts ONLY those numeric fields, for whatever windows are present. It never
// reads prompts, responses, reasoning, tool I/O, `info` token counts, `plan_type`/account, `credits`,
// or auth (docs/PRIVACY.md, AGENTS.md §6). No token estimation, no network, no cookies, no API keys.
//
// ### Schema-driven, not position-driven (evidence, not assumption)
//
// The window set is **not fixed** and `primary`/`secondary` are **not stable in meaning**: real local
// data shows readings with two windows, one window, or none, and a single-window reading where the
// lone `primary` window is the *weekly* one (`window_minutes` 10080). So VibeMenu derives each row's
// identity and label from its own `window_minutes` (never from the slot position), shows exactly the
// windows the latest authoritative reading exposes, and drops a window's row automatically when Codex
// stops exposing it — it never revives a window from an older reading.
//
// ### Honest limitations (surfaced in the UI, never hidden)
//
// `rate_limits` is written only during an active Codex Desktop session and the rollout format is
// undocumented / Codex-controlled, so it is version-fragile. The snapshot therefore models
// `.fresh` / `.stale` / `.unavailable` explicitly and the UI shows a stale/"as of" or unavailable
// message rather than presenting old data as live. The feature is opt-in and default-off, and its copy
// states the local-only source, the turn-bound freshness, and the shared allowance outright.

// MARK: - Severity

/// Subtle severity for a restrained colour accent only — never for alarm. Same conservative
/// thresholds as the Claude section, kept as its own type so Codex and Claude stay decoupled.
public enum CodexUsageLimitSeverity: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical
}

// MARK: - Limit

/// One Codex usage-limit row: a window (identified by its duration), its used percentage (0…100), and
/// when it resets.
///
/// Identity, label, and order all derive from `windowMinutes` — the reliable per-window duration Codex
/// supplies — never from the `primary`/`secondary` slot the window happened to occupy (which the data
/// shows is not stable). `usedPercent` is clamped to 0…100 at init so a malformed value can never
/// produce a bar wider than full or a negative fraction. `resetsAt` is optional because a window can
/// arrive without a reset, and `windowMinutes` is optional because — defensively — a window could carry
/// a percentage without a duration (then the row uses a neutral label).
public struct CodexUsageLimit: Equatable, Sendable, Codable, Identifiable {
    /// The window's rolling duration in minutes, as Codex reported it (`rate_limits.<slot>.window_minutes`).
    /// The reliable discriminator that gives the row its identity, label, and order. `nil` only in the
    /// defensive case of a window with a percentage but no duration.
    public let windowMinutes: Int?
    /// The `rate_limits` slot this window came from (`"primary"`, `"secondary"`, …). A structural key
    /// only — never a duration claim, never displayed, never content. Used solely as a stable identity
    /// / ordering fallback when `windowMinutes` is absent, and as a deterministic tie-break.
    public let slot: String
    /// Server-side utilisation, 0…100 (clamped).
    public let usedPercent: Double
    /// Absolute reset time for this window, or `nil` when the source omitted it.
    public let resetsAt: Date?

    public init(windowMinutes: Int?, usedPercent: Double, resetsAt: Date?, slot: String = "") {
        // Normalize a non-positive duration to "absent" so label / sortKey / visibilityID all agree it
        // has no provable duration (neutral label, sorts last, slot-based id) — a window can't flip its
        // identity between a missing field and a `window_minutes: 0`.
        self.windowMinutes = (windowMinutes.map { $0 > 0 } == true) ? windowMinutes : nil
        self.slot = slot
        self.usedPercent = Self.clampPercent(usedPercent)
        self.resetsAt = resetsAt
    }

    /// Stable **row** identity for SwiftUI `ForEach`. Deliberately *separate* from `visibilityID`: a
    /// snapshot can hold two distinct windows with the same duration (different slots), which would
    /// collide on the duration-derived `visibilityID` alone and break `Identifiable`. So the row id
    /// qualifies the visibility id with the slot (the `rate_limits` object's keys are unique), keeping
    /// each row uniquely identified while `visibilityID` stays duration-stable for hide preferences. A
    /// slot-less window (only constructed directly in tests) keeps the bare `visibilityID`.
    public var id: String { slot.isEmpty ? visibilityID : "\(visibilityID)#\(slot)" }

    /// Stable id used to persist the per-row **visibility** preference across relaunches
    /// (see `CodexUsageLimitVisibility`). Derived from the duration so a hide/show choice survives across
    /// sessions and slots: the two known durations keep the legacy ids (`fiveHour` / `weekly`) so
    /// existing choices survive; any other duration is `win-<m>`; a duration-less window falls back to
    /// its slot. Distinct from Claude's ids, and from the per-row `id`, by construction.
    public var visibilityID: String {
        guard let windowMinutes else { return slot.isEmpty ? "unknown" : "slot-\(slot)" }
        switch windowMinutes {
        case 300: return "fiveHour"
        case 10080: return "weekly"
        default: return "win-\(windowMinutes)"
        }
    }

    /// The exact left-hand row label, derived from the window's own duration — never from its slot.
    public var displayLabel: String { Self.label(windowMinutes: windowMinutes) }

    /// A truthful label for a window duration. The two durations Codex currently emits keep their
    /// familiar names; any other exact duration is named from `window_minutes`; a window with no
    /// provable duration gets a neutral label rather than a fabricated one.
    ///   * 300     → `5-hour limit`
    ///   * 10080   → `Weekly`
    ///   * k·1440  → `Daily` (k = 1) / `<k>-day limit`
    ///   * k·60    → `<k>-hour limit`
    ///   * other   → `<m>-minute limit`
    ///   * nil/≤0  → `Usage limit`  (neutral — duration not provable)
    public static func label(windowMinutes: Int?) -> String {
        guard let m = windowMinutes, m > 0 else { return "Usage limit" }
        switch m {
        case 300: return "5-hour limit"
        case 10080: return "Weekly"
        default:
            if m % 1440 == 0 {
                let days = m / 1440
                return days == 1 ? "Daily" : "\(days)-day limit"
            }
            if m % 60 == 0 { return "\(m / 60)-hour limit" }
            return "\(m)-minute limit"
        }
    }

    /// Deterministic ordering key: shorter windows first (5-hour before Weekly). A duration-less window
    /// sorts last; the snapshot breaks remaining ties by `slot` then `id`.
    public var sortKey: Int { windowMinutes ?? Int.max }

    /// Fraction 0…1 for the progress bar width.
    public var fraction: Double { usedPercent / 100 }

    /// Right-aligned percent text, e.g. `16%`. Rounded to a whole number to match the app UI.
    public var percentText: String { "\(Int(usedPercent.rounded()))%" }

    /// Conservative severity for a restrained colour accent (≥90 critical, ≥75 warning).
    public var severity: CodexUsageLimitSeverity {
        switch usedPercent {
        case ..<75: .normal
        case ..<90: .warning
        default: .critical
        }
    }

    /// Clamp to 0…100, mapping NaN/inf to 0 so downstream formatting/geometry is always sane.
    static func clampPercent(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        return min(100, max(0, raw))
    }

    /// Deterministic reset text matching the app style (identical rules to the Claude row so the two
    /// sections read the same):
    ///   * within `relativeWindow` (default 24 h) → relative, e.g. `Resets in 2 hr 40 min`;
    ///   * further out → absolute weekday + time, e.g. `Resets Sun 1:00 PM`;
    ///   * already elapsed / < 1 min away → `Resets soon`;
    ///   * no known reset time → `Reset time unknown`.
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

/// Where a Codex snapshot came from. Kept explicit so the UI/settings can name the source honestly.
public enum CodexUsageLimitSource: String, Codable, Equatable, Sendable {
    /// The Codex Desktop rollout `token_count.rate_limits` object (read locally).
    case rollout
    /// No usable source produced data (no recent Codex Desktop session, or the field is gone).
    case unavailable

    /// Short, honest label for Settings ("detected source: …").
    public var displayName: String {
        switch self {
        case .rollout: "Codex Desktop (session files)"
        case .unavailable: "None"
        }
    }
}

// MARK: - Status

/// The freshness of a snapshot at a given moment. Load-bearing for honesty: the UI shows `.stale`
/// as an "as of Xm ago" note and `.unavailable` as an explanatory message — it never renders
/// `.stale`/`.unavailable` data as if it were live.
public enum CodexUsageLimitStatus: Equatable, Sendable {
    case fresh
    case stale(age: TimeInterval)
    case unavailable
}

// MARK: - Snapshot

/// A parsed set of Codex usage-limit rows plus the metadata needed to judge freshness. Pure value
/// type; `limits` is always sorted (shortest window first, ties by slot then id) so row order is
/// deterministic regardless of the dictionary order the windows arrived in.
public struct CodexUsageLimitSnapshot: Equatable, Sendable, Codable {
    public let limits: [CodexUsageLimit]
    /// When Codex wrote the `token_count` event this reading came from, or `nil` when unknown.
    public let capturedAt: Date?
    public let source: CodexUsageLimitSource

    public init(limits: [CodexUsageLimit], capturedAt: Date?, source: CodexUsageLimitSource) {
        self.limits = limits.sorted(by: Self.rowOrder)
        self.capturedAt = capturedAt
        self.source = source
    }

    /// Deterministic row order: shortest window first, then by slot, then by id.
    static func rowOrder(_ lhs: CodexUsageLimit, _ rhs: CodexUsageLimit) -> Bool {
        if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
        if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
        return lhs.id < rhs.id
    }

    /// The canonical "nothing to show" snapshot.
    public static let unavailable = CodexUsageLimitSnapshot(
        limits: [], capturedAt: nil, source: .unavailable
    )

    /// Default staleness threshold. Codex writes a `token_count` (with fresh `rate_limits`) on each
    /// assistant turn; between/after sessions it stops. A Codex turn can run for several minutes, so
    /// 15 minutes flags a clearly-idle capture as stale while tolerating a long single turn. (The
    /// reset *countdown* stays correct regardless — it is computed from the absolute `resetsAt`.)
    public static let defaultStaleThreshold: TimeInterval = 15 * 60

    /// Whether there is at least one row to display.
    public var hasData: Bool { !limits.isEmpty }

    /// Freshness at `now`. `.unavailable` when there are no rows; `.stale` when the capture is older
    /// than `staleThreshold`; otherwise `.fresh`. A `nil` `capturedAt` with rows is treated as fresh.
    public func status(
        now: Date,
        staleThreshold: TimeInterval = defaultStaleThreshold
    ) -> CodexUsageLimitStatus {
        guard hasData else { return .unavailable }
        guard let capturedAt else { return .fresh }
        let age = now.timeIntervalSince(capturedAt)
        return age > staleThreshold ? .stale(age: age) : .fresh
    }

    /// A compact "as of Xm ago" / "as of Xh ago" note for a stale capture, or `nil` when fresh or
    /// unavailable. Lets the UI be honest about age without hiding the data.
    public func ageNote(now: Date, staleThreshold: TimeInterval = defaultStaleThreshold) -> String? {
        guard case let .stale(age) = status(now: now, staleThreshold: staleThreshold) else { return nil }
        let minutes = Int(age / 60)
        if minutes < 60 { return "as of \(max(1, minutes))m ago" }
        let hours = minutes / 60
        if hours < 24 { return "as of \(hours)h ago" }
        return "as of \(hours / 24)d ago"
    }
}

// MARK: - Menu copy

/// Pure, deterministic copy for the Codex-usage menu section's **empty state**, kept here (not inline
/// in the view) so the wording is unit-testable and stays truthful about where the numbers come from.
///
/// Why the wording matters: the only approved source is a `token_count.rate_limits` event the
/// **OpenAI desktop app itself writes** into its local rollout files, and only a reading from the last
/// `CodexUsageLimitReader.defaultRecencyHorizon` is read. When nothing has written one in that window
/// there is nothing local to show, and VibeMenu cannot go and ask OpenAI for the current allowance —
/// that would need an authenticated account request, which the no-network/no-credentials invariant
/// forbids (AGENTS.md §8, docs/PRIVACY.md). So the empty state must not imply that merely launching
/// the app, or opening its usage screen, will refresh the numbers: only a real **Work or Codex turn**
/// produces a new local reading (docs/decisions/0017, Amendment 6).
public enum CodexUsageLimitsMenuCopy {
    /// The menu section header. Named for the **app** the numbers come from (the unified ChatGPT
    /// desktop app, covering both its Work and Codex modes) rather than for one of its modes. Kept
    /// here, beside the rest of the copy, so it is unit-tested with everything else it must agree
    /// with. No "Experimental" classification: the caveats live in the copy below, which states the
    /// local-only source, the turn-bound freshness, and the shared allowance outright.
    public static let sectionTitle = "ChatGPT limits"

    /// The Settings group title for the same provider.
    public static let settingsGroupTitle = "ChatGPT"

    /// The Settings toggle that enables session tracking for that app. The storage key behind it is
    /// unchanged (`showCodexSessions`), so an existing user keeps their choice across the rename.
    public static let settingsTrackSessionsTitle = "Track ChatGPT sessions"

    /// The one-line empty state shown in place of rows. Deliberately says *recent* (the reading is
    /// aged out, not necessarily absent) and names the local, turn-written source.
    public static let emptyState =
        "No recent OpenAI usage data — written locally only during a Work or Codex turn"

    /// Tooltip for the empty state. Derives the freshness window from the reader's own horizon so the
    /// copy can never drift from the behaviour, and states the no-network limitation plainly.
    public static var emptyStateHelp: String {
        let hours = Int(CodexUsageLimitReader.defaultRecencyHorizon / 3600)
        return "VibeMenu reads these limits only from the OpenAI desktop app's own local session "
            + "files — whichever limit windows it reports there — and only from a reading written in "
            + "the last \(hours) h. \(sharedAllowanceNote) VibeMenu never contacts OpenAI (no "
            + "network, cookies, API keys, or account data), so it cannot refresh your allowance on "
            + "its own."
    }

    /// The Settings/disclosure sentence about what these numbers cover and when they change. Work and
    /// Codex report the **same** server-side allowance, so VibeMenu shows one shared set of rows; a
    /// new reading appears only as a by-product of a real turn — opening the app or its usage screen
    /// writes nothing locally, so the rows can legitimately stay put after a visit there.
    public static let sharedAllowanceNote =
        "Work and Codex share one OpenAI allowance, so these rows cover both. A new reading is "
        + "written only when Work or Codex actually runs a turn — opening the app or its usage "
        + "screen does not refresh it."

    /// The source name shown in Settings. Names both modes of the one local source, never a raw
    /// originator string.
    public static let settingsSourceName = "ChatGPT (Work + Codex)"
}

// MARK: - Settings header summary

/// Pure, deterministic text for the *collapsed* Codex-usage settings header, so the folded summary
/// is unit-testable without any SwiftUI or file I/O. `Off` when disabled, else `On` joined with the
/// (optional) freshness by ` · ` — e.g. `On · live` or `On · Waiting for data`.
public enum CodexUsageLimitsSummary {
    public static func collapsedHeader(enabled: Bool, freshness: String?) -> String {
        guard enabled else { return "Off" }
        var parts = ["On"]
        if let freshness, !freshness.isEmpty { parts.append(freshness) }
        return parts.joined(separator: " · ")
    }
}
