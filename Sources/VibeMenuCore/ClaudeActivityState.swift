import Foundation

/// Coarse, metadata-only view of whether VibeMenu sees evidence that Claude Code is
/// **present or recently active** — the "Claude detection L1" model.
///
/// This enum is shared by both detection layers: `evaluate(signals:now:)` below is the
/// pure **L1** decision (process presence + session-file mtime), and the **L2** hook
/// heartbeat (`ClaudeHeartbeat.swift`, now implemented) folds into the same state type,
/// adding the `.waiting` case L1 can't produce and falling back to L1 when no heartbeat
/// exists. The app's keep-awake automation treats only `.active` as an automation request;
/// every other state is non-active and releases automation immediately.
///
/// ## Honesty / limitations (read before trusting this)
///
/// L1 is a *first, best-effort* detection layer, not a reliable agent-state oracle.
/// It is derived from two conservative, privacy-preserving signals only:
///
///   1. **Process presence** — whether a process named `claude` appears to be running
///      (public/local process inspection of the current user's processes).
///   2. **Session-file metadata** — the *existence* and *modification times* (mtime) of
///      files under likely Claude Code local directories (e.g. `~/.claude/projects`,
///      `~/.claude/history.jsonl`). **Metadata only.** VibeMenu never reads file
///      *contents*, never parses JSONL, and never copies transcripts (docs/PRIVACY.md,
///      AGENTS.md §6).
///
/// L1 **will** produce false positives and false negatives. In particular it may *miss*
/// Claude Code when the CLI runs under a differently-named host process (e.g. `node`) —
/// a false `notDetected` — and, on its own, it cannot distinguish "working" from "waiting
/// for user input", so plain L1 deliberately does **not** return a waiting-for-input state.
/// The reliable working/waiting split is supplied by the opt-in **L2 hook heartbeat**
/// (now implemented — see `ClaudeHeartbeat.swift`); a further event-driven refinement
/// (FSEvents append tracking to retire the coarse timer) remains future work
/// (docs/ARCHITECTURE.md "AgentMonitor", docs/decisions/0008).
///
/// ## Scope
///
/// v0.1 detection (L1 + L2) feeds the built-in Claude keep-awake loop through
/// `PowerAssertionModel.updateClaudeActivity(_:)`: `.active` requests automation
/// immediately, while `.waiting`, `.running`, `.idle`, `.notDetected`, and `.unknown`
/// release automation immediately. It remains intentionally separate from `AgentActivityState`
/// (the older agent-agnostic policy input model).
public enum ClaudeActivityState: String, Equatable, Sendable, CaseIterable {
    /// Detection has not run yet, or the signals could not be gathered.
    case unknown

    /// No `claude` process and no recent session-file activity — nothing detected.
    case notDetected

    /// A `claude` process appears to be running, but VibeMenu has no session-file
    /// signal for it (no watched session files observed at all).
    case running

    /// A `claude` process is present *and* watched session files were modified within
    /// the recency window — Claude looks actively used right now.
    case active

    /// Evidence of Claude but no *recent* session-file activity: either a running
    /// process whose session files are stale, or recent files with no currently
    /// visible process.
    case idle

    /// Claude finished replying and is **waiting for user input** — a live session
    /// that is not actively working. This state is only reachable from the **L2 hook
    /// heartbeat** (a `Stop`/`Notification` event, or an active event that has aged out
    /// of the active window): L1 metadata alone cannot tell "working" from "waiting"
    /// (see `ClaudeHeartbeat.swift`), so plain L1 never returns `.waiting`.
    case waiting
}

// MARK: - Display

extension ClaudeActivityState {
    /// Short, human-readable label for the menu-bar "Claude" row. Model-level naming
    /// (not UI styling), kept here so it is pure and testable.
    public var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .notDetected: "Not detected"
        case .running: "Running"
        case .active: "Active"
        case .idle: "Idle"
        case .waiting: "Waiting"
        }
    }

    /// Intentionally simplified menu label. `.active` is the only state shown as Active,
    /// `.notDetected` and pre-observation `.unknown` are shown as Not detected, and every
    /// other non-active/fallback/stale state is shown as Idle.
    public var menuDisplayName: String {
        switch self {
        case .active: "Active"
        case .notDetected, .unknown: "Not detected"
        case .running, .idle, .waiting: "Idle"
        }
    }
}

// MARK: - Signals

/// The raw, **metadata-only** signals the L1 detector evaluates.
///
/// A pure value type so the decision logic can be unit-tested with synthetic inputs —
/// no process table and no filesystem required. Note what is *not* here: no prompt or
/// response text, no transcript bytes, no parsed JSONL. The only session-file
/// information carried is a single modification timestamp (mtime).
public struct ClaudeActivitySignals: Equatable, Sendable {
    /// Whether a process named `claude` appears to be running (own-user, public
    /// process inspection).
    public var processPresent: Bool

    /// The most recent modification time observed across the watched Claude Code
    /// session-metadata paths, or `nil` if none exist / none were observed.
    /// **mtime only — never file contents.**
    public var mostRecentSessionActivity: Date?

    public init(processPresent: Bool, mostRecentSessionActivity: Date?) {
        self.processPresent = processPresent
        self.mostRecentSessionActivity = mostRecentSessionActivity
    }
}

// MARK: - Pure L1 decision

extension ClaudeActivityState {
    /// Default recency window: how fresh session-file activity must be to count as
    /// "active". 10s keeps `active` ⇄ `idle` transitions snappy — long enough to bridge
    /// the short pauses between Claude's file writes *while it is replying*, short enough
    /// that once Claude **finishes replying and waits for input** (no more writes, but the
    /// `claude` process is still alive) the row falls back to `idle` within ~10s + a
    /// refresh tick instead of lingering "active" for the full window. Tunable; kept
    /// simple for L1. (Was 90s → 20s → 10s; tightened for snappier finished-reply
    /// detection. See docs/DEVELOPMENT_LOG.md.)
    ///
    /// Fundamental L1 limitation (do not paper over it): metadata alone cannot tell
    /// "working" from "waiting for input" — both look like a live process, and the last
    /// reply's write keeps the mtime fresh briefly. L1 therefore *ages out* of `active`;
    /// reliable working/waiting state needs an opt-in Claude hook / status-line heartbeat
    /// (L2 — docs/ARCHITECTURE.md "AgentMonitor").
    public static let defaultRecencyThreshold: TimeInterval = 10

    /// Pure, I/O-free L1 decision. Given the two gathered signals and the current time
    /// it returns the display state.
    ///
    /// Decision table (design choices are deliberate and documented — see
    /// docs/DEVELOPMENT_LOG.md):
    ///
    /// | process | session mtime        | result        |
    /// |---------|----------------------|---------------|
    /// | yes     | recent (≤ threshold) | `.active`     |
    /// | yes     | stale (> threshold)  | `.idle`       |
    /// | yes     | none observed        | `.running`    |
    /// | no      | recent (≤ threshold) | `.idle`       |
    /// | no      | stale / none         | `.notDetected`|
    ///
    /// Rationale for the two non-obvious rows:
    /// - **process + no session files ⇒ `.running`**: we can see the process but have
    ///   no activity evidence, so we report presence without over-claiming "active".
    /// - **no process + recent files ⇒ `.idle`** (conservative): process inspection can
    ///   miss a short-lived or differently-named host process, and fresh files mean
    ///   Claude was active moments ago; `.idle` acknowledges that without claiming a
    ///   process is currently running. Stale files with no process are just leftovers
    ///   from past sessions ⇒ `.notDetected` (they must not pin the UI to `.idle`
    ///   forever).
    ///
    /// `.unknown` is never returned here — it is the pre-observation state owned by the
    /// model, kept honest for "detection has not run yet".
    public static func evaluate(
        signals: ClaudeActivitySignals,
        now: Date,
        recencyThreshold: TimeInterval = ClaudeActivityState.defaultRecencyThreshold
    ) -> ClaudeActivityState {
        let hasRecentActivity: Bool
        if let last = signals.mostRecentSessionActivity {
            // A future mtime (clock skew) yields a negative age and is treated as recent.
            hasRecentActivity = now.timeIntervalSince(last) <= recencyThreshold
        } else {
            hasRecentActivity = false
        }

        switch (signals.processPresent, signals.mostRecentSessionActivity, hasRecentActivity) {
        case (true, .some, true):  return .active       // process + fresh files
        case (true, .some, false): return .idle         // process + stale files
        case (true, .none, _):     return .running      // process, no session files seen
        case (false, _, true):     return .idle         // recent files, no visible process
        case (false, _, false):    return .notDetected  // nothing running, nothing recent
        }
    }
}

// MARK: - Privacy-safe diagnostics

/// A compact, **privacy-safe** snapshot of the raw signals behind a detection decision,
/// for diagnosing *why* a state was chosen (e.g. why a finished reply reads `waiting`,
/// or why an `active` heartbeat with no visible process was downgraded).
///
/// It carries only metadata the decision uses — a process Bool; the **L2 heartbeat**
/// aggregate (its state, newest record *age in whole seconds*, and the *count* of live
/// sessions — never a session id, never a path); and the **L1** newest session-file
/// *age in whole seconds* + the active-recency threshold; plus the resulting state. It
/// deliberately contains **no** prompt/response text, no transcript contents, no session
/// ids, and no file or project paths (docs/PRIVACY.md, AGENTS.md §6), so `summary` is safe to
/// emit to `os.Logger`. It is DEBUG-only plumbing; nothing here affects the decision or
/// the Release UI.
public struct ClaudeActivityDiagnostics: Equatable, Sendable {
    /// Whether a `claude` process was observed this refresh.
    public let processPresent: Bool

    /// The **heartbeat-only** aggregate state (`.active` / `.waiting`) from live hook
    /// sessions, or `nil` if there were no fresh, non-ended heartbeat records. This is the
    /// L2 contribution *before* the process cross-check / L1 fallback fold it into `result`.
    public let heartbeatState: ClaudeActivityState?

    /// Age, in whole seconds, of the newest fresh (non-stale, non-ended) heartbeat record,
    /// or `nil` if there were none. Clamped at 0 for clock skew.
    public let heartbeatAgeSeconds: Int?

    /// Number of fresh, non-ended heartbeat sessions considered this refresh. A **count**
    /// only — no session ids are ever carried.
    public let sessionCount: Int

    /// Age, in whole seconds, of the newest watched session-file mtime (the L1 signal), or
    /// `nil` if no session files were observed. A negative value indicates clock skew (a
    /// future mtime), surfaced honestly rather than hidden.
    public let newestAgeSeconds: Int?

    /// The L1 active-recency threshold in effect at evaluation time (whole seconds).
    public let thresholdSeconds: Int

    /// The final state the evaluator chose (heartbeat + process cross-check + L1 fallback).
    public let result: ClaudeActivityState

    public init(
        processPresent: Bool,
        heartbeatState: ClaudeActivityState?,
        heartbeatAgeSeconds: Int?,
        sessionCount: Int,
        newestAgeSeconds: Int?,
        thresholdSeconds: Int,
        result: ClaudeActivityState
    ) {
        self.processPresent = processPresent
        self.heartbeatState = heartbeatState
        self.heartbeatAgeSeconds = heartbeatAgeSeconds
        self.sessionCount = sessionCount
        self.newestAgeSeconds = newestAgeSeconds
        self.thresholdSeconds = thresholdSeconds
        self.result = result
    }

    /// A one-line, path-free, id-free summary, e.g.
    /// `process=true, heartbeat=Active age=1s sessions=1, newestAge=32s, threshold=10s,
    /// result=Active`. Booleans, whole-second ages, a session *count*, and state labels
    /// only — no paths, no session ids, no contents.
    public var summary: String {
        let heartbeat = heartbeatState?.displayName ?? "none"
        let heartbeatAge = heartbeatAgeSeconds.map { "\($0)s" } ?? "none"
        let mtimeAge = newestAgeSeconds.map { "\($0)s" } ?? "none"
        return "process=\(processPresent), "
            + "heartbeat=\(heartbeat) age=\(heartbeatAge) sessions=\(sessionCount), "
            + "newestAge=\(mtimeAge), threshold=\(thresholdSeconds)s, "
            + "result=\(result.displayName)"
    }
}
