import Foundation

// Session Radar — per-session Claude Code state (docs/decisions/0011-session-radar.md).
//
// The existing detection layer (ClaudeActivityState.evaluate / .automationIntent) folds
// every live session into ONE global display state + ONE keep-awake intent. That is exactly
// right for the menu-bar icon and the power loop, but it hides which session is working,
// waiting, or done. Session Radar adds a pure DISPLAY layer over the same VibeMenu-owned
// heartbeat records: one `ClaudeSession` per live session id, derived from the same
// `{schemaVersion, updatedAt, event, sessionID}` files — never transcripts, cwd, or
// contents (docs/PRIVACY.md, AGENTS.md §6).
//
// Two hard design rules keep this honest and safe:
//
//  1. **It reads nothing new.** Only the existing heartbeat records, process presence, and
//     `now`. No project path, no terminal name, no task title, no activity text — those need
//     data we deliberately don't capture, so they are documented-`nil` placeholders, not
//     invented values.
//
//  2. **The per-session state is defined to be exactly consistent with the proven keep-awake
//     decision.** `ClaudeSessionState.holdsSleepPrevention` (working ∨ quietWorking) holds a
//     session iff `event.indicatesWorkInProgress && age ≤ quietHoldCap && processPresent` —
//     the same predicate `ClaudeActivityState.automationIntent` uses. So the aggregate of the
//     radar (`sessionsKeepAwakeIntent`) provably equals the wired automation intent
//     (a unit test asserts this across the same timelines). The radar is a *view* of the
//     power decision, and the two can never silently drift.
//
// This file is pure and I/O-free (value types + a value-type store with a `mutating update`),
// so all of it is unit-tested with synthetic records. The file reading stays in the
// `ClaudeActivityProvider` adapter, which owns one store instance.

// MARK: - Per-session state

/// The state of a single Claude Code session, for the Session Radar list.
///
/// Derived from that session's most recent heartbeat event, its age, and whether a `claude`
/// process is visible. Deliberately richer than the collapsed `ClaudeActivityState` menu
/// label (Active/Idle/Not detected) because the radar's job is to show *which* session is in
/// *which* state.
public enum ClaudeSessionState: String, Equatable, Sendable, CaseIterable {
    /// A fresh active event (prompt submitted, tool starting/finishing, subagent spawned)
    /// within the active window — Claude is visibly working right now.
    case working

    /// Still working, but quietly: a work-in-progress event that has aged past the active
    /// display window yet is within the bounded quiet-hold cap, with the process present and
    /// no finish signal. This is the long-silent tool/subagent/build phase from
    /// docs/decisions/0010 — the Mac stays awake through it. Shown distinctly so the radar is
    /// honest that work is likely still in flight even though no hook has fired for a while.
    case quietWorking

    /// The high-priority state where the user must make an actual approval / Allow–Deny decision.
    /// Derived from Claude Code's documented `PermissionRequest` hook event (docs/decisions/0018),
    /// which fires the moment the approval dialog is presented — before the user responds — and is
    /// recorded as the session's heartbeat `event`. A **normal finished turn is not this** — it is
    /// `.done`. Sorted first and styled for attention; it clears when the next lifecycle event
    /// (`PostToolUse`/`Stop`/…) overwrites the heartbeat after the user responds. Only ever produced
    /// from a real `PermissionRequest` (never fabricated from ordinary events).
    case permissionRequested

    /// The session finished its turn and is idle: a normal completion (`Stop`), an attention
    /// `Notification`, a bare `SessionStart` that hasn't worked yet, or a clean `SessionEnd`.
    /// This is the ordinary "Claude responded and is waiting for the next prompt" case
    /// (docs/decisions/0015) — deliberately **not** high-priority "Waiting", because almost every
    /// session eventually reaches it and those rows would otherwise pile up and crowd out the
    /// sessions that are actually working. Low-priority context: capped, timer-less, shown
    /// briefly, then pruned.
    case done

    /// No signal for a long time and we can't confirm the session is alive — an aged
    /// work-in-progress event past the quiet-hold cap, or a heartbeat with no visible
    /// process that is no longer fresh. Likely abandoned/crashed; de-emphasised, then pruned.
    case stale

    /// Indeterminate (e.g. a malformed/unclassifiable record). Rare; kept explicit rather
    /// than guessing.
    case unknown
}

extension ClaudeSessionState {
    /// Short, human-readable label for a radar row. Model-level naming (pure/testable),
    /// not UI styling. Deliberately terse (docs/decisions/0012): the row leads with the
    /// project/title name, so the state word stays a single glanceable token. A finished turn
    /// reads **"Done"**, never generic "Waiting" — VibeMenu no longer surfaces "finished and
    /// waiting for the next prompt" as high priority (docs/decisions/0015). "Needs approval"
    /// is shown only for a real, verified approval prompt (`permissionRequested`, from the
    /// `PermissionRequest` hook — docs/decisions/0018).
    public var label: String {
        switch self {
        case .working: "Working"
        case .quietWorking: "Quiet"
        case .permissionRequested: "Needs approval"
        case .done: "Done"
        case .stale: "Stale"
        case .unknown: "Unknown"
        }
    }

    /// Framework-free display style the app maps to a SwiftUI colour (mirrors
    /// `ThermalDisplayStyle`), so `VibeMenuCore` stays free of SwiftUI/AppKit.
    public var displayStyle: ClaudeSessionDisplayStyle {
        switch self {
        case .working, .quietWorking: .working
        case .permissionRequested: .attention
        case .done: .done
        case .stale, .unknown: .inactive
        }
    }

    /// Sort key for the radar: **attention-first**, so the session that most needs the user
    /// (or is most active) sorts to the top. Lower sorts first. Ties are broken by recency in
    /// `ClaudeSessionStore`. `.done` sorts **below** working/quiet (docs/decisions/0015) so
    /// finished/idle sessions never push an actively-working session out of the visible list.
    public var sortPriority: Int {
        switch self {
        case .permissionRequested: 0
        case .working: 1
        case .quietWorking: 2
        case .done: 3
        case .stale: 4
        case .unknown: 5
        }
    }

    /// Whether a session in this state is holding automatic sleep prevention. **This is the
    /// radar's mirror of the keep-awake decision** — `working`/`quietWorking` are exactly the
    /// states `ClaudeActivityState.automationIntent` holds for, so the radar aggregate and the
    /// wired power intent stay provably in lockstep (see `sessionsKeepAwakeIntent`).
    public var holdsSleepPrevention: Bool {
        switch self {
        case .working, .quietWorking: true
        default: false
        }
    }

    /// Whether this state genuinely needs the user to act — i.e. a real approval / Allow–Deny
    /// decision (`permissionRequested`). The radar emphasises these rows so "something needs you"
    /// reads at a glance. A normal finished turn (`.done`) is **not** attention-worthy
    /// (docs/decisions/0015): the user typically just moves on to a new session, so flagging every
    /// finished session would be noise. Produced from the real `PermissionRequest` hook event
    /// (docs/decisions/0018).
    public var needsAttention: Bool {
        switch self {
        case .permissionRequested: true
        default: false
        }
    }

    /// Whether a radar row in this state shows the elapsed timer (task Issue 2). A finished/idle
    /// session (`.done`) shows **no** timer — its turn is over, so a running clock is meaningless
    /// and reads as if it were still working. Only live, non-finished states show elapsed time:
    /// `.working` / `.quietWorking` (actively going), and `.permissionRequested` (so a real
    /// approval-blocked row shows how long it has waited — from the request). `.stale` / `.unknown` are
    /// aged or indeterminate and show none.
    public var showsElapsedTimer: Bool {
        switch self {
        case .working, .quietWorking, .permissionRequested: true
        case .done, .stale, .unknown: false
        }
    }
}

/// Framework-free colour intent for a session state; the app maps it to a real SwiftUI
/// `Color` (VibeMenuCore never imports SwiftUI/AppKit).
public enum ClaudeSessionDisplayStyle: String, Equatable, Sendable, CaseIterable {
    case working    // actively / quietly working
    case waiting    // finished a turn, waiting for input
    case attention  // needs the user (a pending Allow/Deny approval)
    case done       // ended
    case inactive   // stale / unknown
}

// MARK: - Session value

/// One Claude Code session in the Session Radar.
///
/// A pure value type. Note what is *not* here: no prompt/response text, no tool input, no
/// `lastPrompt`, no full cwd. `terminal` and `currentActivity` remain documented placeholders —
/// always `nil` in v0.2. Two human-readable identities are carried: `title` — Claude Code's own
/// session title, read narrowly from the transcript's title record when available
/// (docs/decisions/0013-session-title-and-dismiss.md) — and `projectName` — the project *folder
/// name* the hook derived from cwd's final path component
/// (docs/decisions/0012-session-name-from-cwd.md). `displayName` prefers the title, then the
/// folder name, then a generic label.
public struct ClaudeSession: Equatable, Sendable, Identifiable {
    /// The Claude Code session id (opaque; the stable identity for the row and dedup). Kept
    /// off the visible row — the radar shows the project name instead (docs/decisions/0012).
    public let id: String

    /// The derived state for the radar.
    public let state: ClaudeSessionState

    /// The most recent hook event observed for this session (drives `state`; kept for tests
    /// and a possible future detail view).
    public let event: ClaudeHeartbeatEvent

    /// When VibeMenu *first observed* this session (not necessarily when Claude started it —
    /// heartbeat files don't retain a start time). Drives the row's elapsed time. Resets on
    /// app restart and underestimates sessions that predate VibeMenu launch (documented).
    public let startedAt: Date

    /// When the session's newest heartbeat event was written (the file's `updatedAt`).
    public let lastEventAt: Date

    /// The agent name. Always `"Claude"` in v0.2 (Claude Code only); the field exists so the
    /// radar UI is already agent-labelled for a future multi-agent pass.
    public let agent: String

    /// The project **folder name** for this session (schema-2 heartbeats), i.e. the final
    /// path component of the session's cwd — e.g. `"VibeMenu"`. Never a full path or a parent
    /// directory (the hook writes only `basename(cwd)`). `nil` when unavailable (schema-1
    /// heartbeat, or the hook couldn't determine a folder name), in which case `displayName`
    /// falls back to the title (if any) or a generic label. Below the title in the naming
    /// preference (docs/decisions/0012-session-name-from-cwd.md).
    public let projectName: String?

    /// Claude Code's own **human-readable session title** — the same name it shows in its
    /// session list (e.g. `"Session Radar identity and visibility"`), when it can be read
    /// safely. Extracted from the session transcript's `custom-title` (user rename) / `ai-title`
    /// (auto-generated) record and nothing else — never prompt/response/`lastPrompt`/message
    /// content (docs/decisions/0013-session-title-and-dismiss.md, docs/PRIVACY.md). `nil` when
    /// no transcript/title is available yet, so `displayName` falls back to the folder name.
    /// This is the top of the naming preference the radar leads with.
    public let title: String?

    /// **Placeholder — always `nil` in v0.2.** The terminal/app hosting the session. We have
    /// no privacy-safe source for it yet (would need process/AX inspection we deliberately
    /// avoid). Kept so the UI shape and future work are explicit.
    public let terminal: String?

    /// **Placeholder — always `nil` in v0.2.** A short "current activity" line (e.g.
    /// "Writing middleware.ts"). Would require reading tool input from the hook payload, which
    /// the privacy-constrained heartbeat deliberately does not record.
    public let currentActivity: String?

    public init(
        id: String,
        state: ClaudeSessionState,
        event: ClaudeHeartbeatEvent,
        startedAt: Date,
        lastEventAt: Date,
        agent: String = "Claude",
        projectName: String? = nil,
        title: String? = nil,
        terminal: String? = nil,
        currentActivity: String? = nil
    ) {
        self.id = id
        self.state = state
        self.event = event
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.agent = agent
        self.projectName = projectName
        self.title = title
        self.terminal = terminal
        self.currentActivity = currentActivity
    }
}

extension ClaudeSession {
    /// The generic name shown when neither a title nor a project folder name is available
    /// (schema-1 heartbeat with no readable transcript title). The radar appends a stable index
    /// when several such sessions are visible at once (see `SessionRadar.present`).
    public static let genericName = "Claude session"

    /// The human-readable **base** name for a radar row, in fallback order
    /// (docs/decisions/0013-session-title-and-dismiss.md):
    ///   1. `title` — Claude Code's own session title, when safely readable;
    ///   2. `projectName` — the hook's project folder name (docs/decisions/0012);
    ///   3. `genericName` — `"Claude session"`.
    /// The visible row may add a disambiguation index on top of this when two visible rows share
    /// the same base name (`SessionRadar.present`). Never a full path or a session id.
    public var displayName: String {
        title ?? projectName ?? Self.genericName
    }

    /// A copy of this session with its `title` replaced. Used by the provider to attach the
    /// transcript-derived title after the pure store built the (title-free) session, keeping the
    /// store I/O-free.
    public func withTitle(_ title: String?) -> ClaudeSession {
        ClaudeSession(
            id: id, state: state, event: event, startedAt: startedAt, lastEventAt: lastEventAt,
            agent: agent, projectName: projectName, title: title,
            terminal: terminal, currentActivity: currentActivity
        )
    }

    /// Whether this is a **home-folder noise** row: a session whose *only* identity is the user's
    /// home-directory folder name (no Claude title, and its project folder name equals the home
    /// folder — the Claude desktop app launches throwaway sessions in `$HOME`) **and** which is
    /// not worth a radar row. These are the reported "kirill 1 / kirill 2" ghosts: the desktop app
    /// fires `SessionStart` → `SessionEnd` in the home directory with nothing in between, no
    /// transcript, and no title (docs/decisions/0011 task step 3).
    ///
    /// The rule is deliberately narrow so it can never hide a session that matters
    /// (task: "do not hide real active sessions with titles"):
    ///   - a session with a **title** always shows (a real title is never home-folder noise);
    ///   - a session whose project name is *not* the home folder always shows (it's real project
    ///     work — this is the common case);
    ///   - an **actively working** home-dir session shows (task's explicit exception);
    ///   - a `.permissionRequested` home-dir session shows (a real approval still needs the user);
    ///   - an untitled home-dir session that is **done/idle** (a normal finished turn — `Stop`,
    ///     `Notification`, bare `SessionStart`, or `SessionEnd`), **stale**, or **unknown** is a
    ///     throwaway `$HOME` launch and is hidden. Since docs/decisions/0015 folds "finished and
    ///     waiting for the next prompt" into `.done`, an untitled home-dir finish no longer earns
    ///     a row — the user cares about titled / real-project sessions, not scratch launches.
    ///
    /// `homeFolderName` is the current user's home-directory folder name (e.g. `"kirill"`); pass
    /// `nil` to disable home-folder filtering entirely (used by tests that don't exercise it).
    /// Reads only the folder *name*, never a path — nothing sensitive is stored or shown.
    public func isHomeFolderNoise(homeFolderName: String?) -> Bool {
        // A real Claude title always earns a row, even from the home directory.
        guard title == nil else { return false }
        // Only applies when the session's sole identity is the user's home folder name.
        guard let homeFolderName, projectName == homeFolderName else { return false }
        switch state {
        case .working, .quietWorking:
            return false                          // actively working → always show
        case .permissionRequested:
            return false                          // a real approval still needs the user
        case .done, .stale, .unknown:
            return true                           // finished / idle / aged throwaway launch → hide
        }
    }

    /// A short, opaque disambiguator derived from the session id (first 6 characters). No
    /// longer shown on the radar row (superseded by `displayName`; docs/decisions/0012), but
    /// retained for tests and any future detail view. Carries no project name, path, or
    /// content, and is never logged (docs/PRIVACY.md keeps session ids out of diagnostics).
    public var shortID: String {
        String(id.prefix(6))
    }

    /// Elapsed time since VibeMenu first observed the session, at `now` (clamped ≥ 0 for clock
    /// skew). The UI formats it; kept here so it's pure and testable.
    public func elapsed(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    /// A compact elapsed label for the radar row (e.g. `"7s"`, `"1m 45s"`, `"1h 5m"`), computed
    /// at `now`. Pure/testable; the app recomputes it as the menu ticks.
    public func elapsedLabel(now: Date) -> String {
        Self.shortDuration(elapsed(now: now))
    }

    /// The elapsed value the radar row actually **shows**. For a pending approval
    /// (`.permissionRequested`) the timer measures **time since the request** — the
    /// `PermissionRequest` heartbeat's write time (`lastEventAt`) — so the row reads "how long the
    /// user has been waited on", not the total session age (task: *timer starts at the request*).
    /// Every other state measures from `startedAt` (first observed), unchanged. Clamped ≥ 0.
    public func displayElapsed(now: Date) -> TimeInterval {
        switch state {
        case .permissionRequested: return max(0, now.timeIntervalSince(lastEventAt))
        default: return elapsed(now: now)
        }
    }

    /// Compact label for `displayElapsed` — what the app renders in the row's timer column.
    public func displayElapsedLabel(now: Date) -> String {
        Self.shortDuration(displayElapsed(now: now))
    }

    /// Format a duration compactly using the **two** most significant units:
    ///   * under a minute → seconds only (`"7s"`, `"25s"`);
    ///   * under an hour → minutes and seconds, with a zero seconds dropped
    ///     (`"1m 5s"`, `"12m 44s"`, `"5m"`);
    ///   * an hour or more → hours and minutes, with a zero minutes dropped
    ///     (`"1h 5m"`, `"2h"`).
    /// Hours are the top unit (a long-running session past 24h reads e.g. `"25h 3m"`), matching
    /// the radar's compact single-line row. Pure and testable; no locale/`DateComponentsFormatter`
    /// dependency so it stays deterministic in unit tests.
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let minutes = total / 60
            let secs = total % 60
            return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    /// Whether this session is holding automatic sleep prevention (mirrors its state).
    public var holdsSleepPrevention: Bool { state.holdsSleepPrevention }
}

// MARK: - Per-session state derivation (pure)

extension ClaudeSessionState {
    /// Derive a session's radar state from its newest heartbeat event, the event's age, and
    /// whether a `claude` process is visible. Pure and I/O-free.
    ///
    /// The thresholds default to the same constants the detection/automation path uses, so the
    /// radar and the keep-awake decision stay aligned:
    ///   - `activeWindow` (120s) — a fresh active event reads `working`; older reads
    ///     `quietWorking`.
    ///   - `quietHoldCap` (900s) — the upper bound of `quietWorking`; past it a
    ///     work-in-progress session reads `stale` (and the automation would have released).
    ///
    /// Rules (in order):
    ///   1. `SessionEnd` and genuine turn-finish events (`Stop`/`StopFailure`) ⇒ `.done`
    ///      immediately, regardless of age or process presence.
    ///   2. No visible `claude` process ⇒ a heartbeat is not proof of life. Fresh (≤
    ///      `activeWindow`) reads `.done` (finished/idle; process detection can miss a
    ///      node-hosted / just-exited CLI); older reads `.stale`. Never `working` without a
    ///      process — the same cross-check `evaluate`/`automationIntent` apply.
    ///   3. Process present + an **active** event (`isActiveEvent`): `≤ activeWindow` ⇒
    ///      `.working`; `≤ quietHoldCap` ⇒ `.quietWorking`; else `.stale`.
    ///   4. Process present + a **work-in-progress but not active** event (`SubagentStop`,
    ///      unknown/future): `≤ quietHoldCap` ⇒ `.quietWorking`; else `.stale`.
    ///   5. Process present + a **not-working** event (`Stop`, `Notification`, `SessionStart`)
    ///      ⇒ `.done` — a normal finished/idle turn (docs/decisions/0015), **not** high-priority
    ///      "Waiting". A real approval prompt would be `.permissionRequested`, which is not
    ///      derivable yet (VibeMenu doesn't capture the `Notification` subtype).
    ///
    /// Note the deliberate consistency with `automationIntent`: exactly the cases that return
    /// `.working`/`.quietWorking` here are the cases that hold sleep prevention there.
    public static func derive(
        event: ClaudeHeartbeatEvent,
        age: TimeInterval,
        processPresent: Bool,
        activeWindow: TimeInterval = ClaudeActivityState.defaultHeartbeatActiveThreshold,
        quietHoldCap: TimeInterval = ClaudeActivityState.defaultQuietHoldCap
    ) -> ClaudeSessionState {
        let a = max(0, age)   // clamp clock skew (future mtime) to "just now"

        // 1. Explicit session/turn finishes win outright. A genuine Stop must not age into Quiet
        // or wait for process detection to disappear before the row becomes Done.
        if event.isSessionEnd || event.isTurnCompletionEvent { return .done }

        // 2. No visible process: never claim working. Brief grace as done/idle, else stale.
        guard processPresent else {
            return a <= activeWindow ? .done : .stale
        }

        // 2.5 A pending tool-use approval (`PermissionRequest`) with a live process is the
        // high-priority "needs the user" state, regardless of age — a real approval can legitimately
        // wait a long time while the user is away (so it is deliberately *not* aged out to stale;
        // the store's prune horizon still bounds it). It clears when the next lifecycle event
        // overwrites the heartbeat after the user responds (`PostToolUse`/`Stop`/…). It never holds
        // sleep prevention — the user, not Claude, is the blocker (`holdsSleepPrevention` is false).
        if event == .permissionRequested { return .permissionRequested }

        // 3. Visibly active event.
        if event.isActiveEvent {
            if a <= activeWindow { return .working }
            if a <= quietHoldCap { return .quietWorking }
            return .stale
        }

        // 4. Work-in-progress but not a display-active event (SubagentStop / unknown).
        if event.indicatesWorkInProgress {
            return a <= quietHoldCap ? .quietWorking : .stale
        }

        // 5. Not working: Notification / SessionStart ⇒ a normal finished/idle turn.
        // Deliberately `.done`, not high-priority "Waiting": almost every session eventually
        // finishes and waits for the next prompt, and treating that as attention-worthy makes
        // those rows pile up and crowd out the sessions that are actually working
        // (docs/decisions/0015). A verified approval prompt would be `.permissionRequested`.
        return .done
    }
}

// MARK: - Aggregate keep-awake (radar view of the wired power decision)

/// The keep-awake intent implied by a set of radar sessions: `.hold` iff **any** session is
/// holding sleep prevention (working or quietWorking), else `.release`.
///
/// This is the radar's aggregate view of the power decision. By construction it equals
/// `ClaudeActivityState.automationIntent(...)` computed from the same heartbeats + process
/// signal + `now` — a unit test pins that equivalence across the automation timelines. The
/// app continues to feed IOKit from `automationIntent` (the proven path); this function exists
/// so the aggregate is testable and so a future unification has a validated target.
public func sessionsKeepAwakeIntent(_ sessions: [ClaudeSession]) -> ClaudeAutomationIntent {
    sessions.contains(where: { $0.holdsSleepPrevention }) ? .hold : .release
}

// MARK: - Session store (stateful, pure value type)

/// Maintains the Session Radar's list across detection ticks.
///
/// Responsibilities (docs/decisions/0011-session-radar.md, task §2):
///   - Consume the deduped, per-session heartbeat records each tick.
///   - Derive each live session's `ClaudeSessionState`.
///   - Track `startedAt` (first-observed wall clock) across ticks so a row can show elapsed
///     time; heartbeat files don't retain a start time, so this is the honest best effort.
///   - **Prune** sessions whose newest event is older than `pruneHorizon` (default 30 min) so
///     the accumulating on-disk heartbeat files — the hook never deletes them — don't clutter
///     the radar with long-dead sessions. Pruned ids are dropped from the first-seen map too,
///     so it can't grow unbounded.
///   - Sort **attention-first** (`state.sortPriority`), ties broken by most-recent event.
///
/// A pure value type with a `mutating update`: feed it synthetic records + a `now` and inspect
/// `sessions` — no filesystem or process table required. The `ClaudeActivityProvider` owns one
/// instance and calls `update` under its lock each tick.
public struct ClaudeSessionStore: Equatable, Sendable {
    /// How long after a session's newest event we keep showing it before pruning it from the
    /// radar. Generous enough to keep a just-finished / waiting session visible for a while,
    /// bounded so the ever-growing pile of old heartbeat files never accumulates in the list.
    public static let defaultPruneHorizon: TimeInterval = 30 * 60

    /// First-observed wall-clock time per live session id, preserved across ticks so elapsed
    /// time is stable. Pruned to the currently-shown set every update.
    private var firstSeen: [String: Date]

    /// The current radar sessions, sorted attention-first. Republished by the provider.
    public private(set) var sessions: [ClaudeSession]

    /// The prune horizon in effect (injectable for tests).
    private let pruneHorizon: TimeInterval
    private let activeWindow: TimeInterval
    private let quietHoldCap: TimeInterval

    public init(
        pruneHorizon: TimeInterval = ClaudeSessionStore.defaultPruneHorizon,
        activeWindow: TimeInterval = ClaudeActivityState.defaultHeartbeatActiveThreshold,
        quietHoldCap: TimeInterval = ClaudeActivityState.defaultQuietHoldCap
    ) {
        self.firstSeen = [:]
        self.sessions = []
        self.pruneHorizon = pruneHorizon
        self.activeWindow = activeWindow
        self.quietHoldCap = quietHoldCap
    }

    /// The aggregate keep-awake intent implied by the current sessions (see
    /// `sessionsKeepAwakeIntent`). For display/validation; the app's power loop still uses the
    /// wired `automationIntent`.
    public var keepAwakeIntent: ClaudeAutomationIntent {
        sessionsKeepAwakeIntent(sessions)
    }

    /// Fold this tick's heartbeat records into the radar. `processPresent` is the global
    /// `claude`-process flag (we can't attribute a PID to a specific session without reading
    /// its command line, which we deliberately don't — documented). `now` is injected for
    /// deterministic tests.
    public mutating func update(
        records: [ClaudeHeartbeatRecord],
        processPresent: Bool,
        now: Date
    ) {
        // Dedupe to the newest record per session (reuses the detection path's helper).
        let latest = ClaudeActivityState.latestRecordPerSession(records)
        let previousByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        var nextFirstSeen: [String: Date] = [:]
        var next: [ClaudeSession] = []

        for record in latest {
            let age = now.timeIntervalSince(record.updatedAt)
            // Prune long-dead sessions: their heartbeat file lingers on disk forever, but we
            // don't surface a session we haven't heard from in `pruneHorizon`.
            if age > pruneHorizon { continue }

            let state = ClaudeSessionState.derive(
                event: record.event,
                age: age,
                processPresent: processPresent,
                activeWindow: activeWindow,
                quietHoldCap: quietHoldCap
            )

            // Preserve the visible turn start across ordinary refreshes. A newer PermissionRequest
            // after a completed/stale/unknown turn starts a new turn at the request; a request during
            // existing work keeps the original start. PermissionRequest → work is the same turn
            // resuming after approval, so it also keeps the request-established (or original) start.
            // A newer work event after a completed/stale/unknown state starts a fresh turn. Identical
            // or older snapshots never reset anything.
            let started: Date
            if let previous = previousByID[record.sessionID] {
                let previousStart = firstSeen[record.sessionID] ?? previous.startedAt
                // Match Attention's safe Claude generation identity: a same-second event change is
                // a new heartbeat generation, while a repeated event/timestamp is only a refresh.
                let isNewer = record.updatedAt > previous.lastEventAt
                    || (record.updatedAt == previous.lastEventAt && record.event != previous.event)

                if isNewer, record.event == .permissionRequested {
                    switch previous.state {
                    case .done, .stale, .unknown:
                        started = record.updatedAt
                    case .working, .quietWorking, .permissionRequested:
                        started = previousStart
                    }
                } else if isNewer, record.event.indicatesWorkInProgress,
                          !previous.state.holdsSleepPrevention,
                          previous.state != .permissionRequested {
                    started = record.updatedAt
                } else {
                    started = previousStart
                }
            } else if record.event == .permissionRequested {
                // If the app first sees an approval row, its eventual resumed turn should still be
                // request-relative rather than starting at an arbitrary polling time.
                started = record.updatedAt
            } else {
                started = now
            }
            nextFirstSeen[record.sessionID] = started

            next.append(ClaudeSession(
                id: record.sessionID,
                state: state,
                event: record.event,
                startedAt: started,
                lastEventAt: record.updatedAt,
                projectName: record.project   // schema-2 folder name; nil for older files
            ))
        }

        // Attention-first, ties broken by most-recent activity (freshest first), then by id
        // for a fully deterministic order.
        next.sort { lhs, rhs in
            if lhs.state.sortPriority != rhs.state.sortPriority {
                return lhs.state.sortPriority < rhs.state.sortPriority
            }
            if lhs.lastEventAt != rhs.lastEventAt {
                return lhs.lastEventAt > rhs.lastEventAt
            }
            return lhs.id < rhs.id
        }

        firstSeen = nextFirstSeen   // drop first-seen entries for pruned/vanished sessions
        sessions = next
    }
}

// MARK: - Radar presentation (pure visibility + naming)

/// One presented radar row: a session paired with the exact name to render for it. `name` is
/// `session.displayName` plus a disambiguation index when two visible rows share a base name
/// (e.g. two `VibeMenu` sessions become `VibeMenu 1` / `VibeMenu 2`).
public struct RadarRow: Equatable, Sendable, Identifiable {
    public let session: ClaudeSession
    public let name: String
    public var id: String { session.id }

    public init(session: ClaudeSession, name: String) {
        self.session = session
        self.name = name
    }
}

/// Pure presentation rules for the Session Radar (docs/decisions/0012-session-name-from-cwd.md,
/// task step 2). Turns the store's full attention-first session list into the bounded, deduped
/// set of rows the menu actually shows — no SwiftUI, no I/O, fully unit-tested.
///
/// The store already sorts **attention-first** (`ClaudeSessionState.sortPriority`, ties by
/// recency), so this layer only *filters* and *caps* that order; it never re-prioritises. That
/// keeps one source of truth for priority and makes these rules a thin, testable projection.
public enum SessionRadar {
    /// Never show more than this many rows, so the popover stays compact even with many live
    /// sessions. Overflow is summarised in `Presentation.hiddenCount`. Kept deliberately tight
    /// (4): a 5th eligible session is the first to spill into the expandable "more recent
    /// sessions" control rather than the primary list.
    public static let maxVisibleRows = 4

    /// Upper bound on how many `done` rows the primary list may hold. Since docs/decisions/0015
    /// folded "finished / idle / waiting for the next prompt" into `.done`, `.done` is now the
    /// *normal* resting state most sessions reach — not a rare terminal one — so the primary list
    /// must be able to fill all the way up to `maxVisibleRows` with done rows (task Issue 1: "if 4
    /// eligible sessions exist, show 4"). Tying this to `maxVisibleRows` does exactly that: done
    /// can occupy every visible slot but never more, and active sessions still sort ahead of done
    /// (so a working row is never pushed out by a finished one — that's the sort order, not this
    /// cap). Kept as an explicit tunable so a future product decision can re-tighten it without
    /// touching `present`. Done beyond this bound is elided into `hiddenCount` / overflow.
    public static let maxDoneRows = maxVisibleRows

    /// When the user expands the overflow control, reveal at most this many hidden rows, so the
    /// expanded popover stays a quick peek and never a full history dashboard. Any eligible-but-
    /// hidden sessions beyond this are summarised by `Presentation.olderHiddenCount`.
    public static let maxOverflowRows = 10

    /// Hide `done` sessions whose last event is older than this — a finish more than a few
    /// minutes ago is stale context. Measured from `lastEventAt`.
    public static let doneVisibilityHorizon: TimeInterval = 5 * 60

    /// Hide `stale` sessions whose last event is older than this — a session we haven't heard
    /// from in a couple of minutes and can't confirm alive isn't worth a row. From `lastEventAt`.
    public static let staleVisibilityHorizon: TimeInterval = 2 * 60

    /// The current user's home-directory **folder name** (e.g. `"kirill"`), used to recognise the
    /// Claude desktop app's throwaway home-directory sessions so they can be filtered as noise
    /// (`ClaudeSession.isHomeFolderNoise`). Reads only the last path component — never the path —
    /// so nothing sensitive is stored or displayed. `nil` if it can't be determined (in which case
    /// no home-folder filtering happens and behaviour is unchanged).
    public static var currentHomeFolderName: String? {
        let name = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// The presented radar: the rows to draw (already named + capped) and how many further
    /// recent sessions were elided (drives the "+N more recent sessions" control).
    ///
    /// `overflowRows` are those elided-but-eligible sessions the expandable control reveals — the
    /// same attention-first order, same `RadarRow` layout as `rows`, capped at `maxOverflowRows`.
    /// `hiddenCount` is the total elided count (drives the collapsed label and always equals what
    /// it did before this control existed); `olderHiddenCount` is the remainder past the overflow
    /// cap (drives the "+N older sessions hidden" note shown when expanded).
    public struct Presentation: Equatable, Sendable {
        public let rows: [RadarRow]
        public let hiddenCount: Int
        public let overflowRows: [RadarRow]
        public let olderHiddenCount: Int

        public init(
            rows: [RadarRow], hiddenCount: Int,
            overflowRows: [RadarRow] = [], olderHiddenCount: Int = 0
        ) {
            self.rows = rows
            self.hiddenCount = hiddenCount
            self.overflowRows = overflowRows
            self.olderHiddenCount = olderHiddenCount
        }
    }

    /// Apply the visibility rules and name disambiguation to a store's sessions at `now`.
    ///
    /// Order of operations (all on the store's existing attention-first order):
    ///   1. **Eligibility** — drop **home-folder noise** (the desktop app's throwaway
    ///      home-directory launches — see `ClaudeSession.isHomeFolderNoise`), `unknown` (never in
    ///      the normal UI), `done` older than `doneVisibilityHorizon`, and `stale` older than
    ///      `staleVisibilityHorizon`.
    ///   2. **Done cap** — keep at most `maxDoneRows` done rows (the freshest, since eligible
    ///      is recency-ordered within a state); further done rows are elided.
    ///   3. **Row cap** — keep at most `maxVisibleRows` rows total.
    ///   4. **Naming** — give each visible row `session.displayName`, appending a stable index
    ///      when several visible rows share a base name.
    ///
    /// `homeFolderName` is the current user's home-directory folder name (e.g. `"kirill"`), used
    /// to recognise and drop those launcher ghosts; pass `nil` to disable home-folder filtering
    /// (tests that don't exercise it, or a caller that opts out) — everything else is unchanged.
    /// The app passes `SessionRadar.currentHomeFolderName`.
    ///
    /// `hiddenCount` counts the eligible-but-not-shown sessions (done beyond the cap, plus
    /// overflow past `maxVisibleRows`) — i.e. recent sessions the user might care about, not
    /// the long tail of already-dropped old/unknown/home-noise ones.
    public static func present(
        _ sessions: [ClaudeSession],
        now: Date,
        homeFolderName: String? = nil
    ) -> Presentation {
        func lastEventAge(_ s: ClaudeSession) -> TimeInterval {
            max(0, now.timeIntervalSince(s.lastEventAt))
        }

        // 1. Eligibility.
        let eligible = sessions.filter { s in
            // Drop the desktop app's throwaway home-directory launches ("kirill" ghosts) before
            // anything else — they are never worth a row and must not count toward `hiddenCount`.
            if s.isHomeFolderNoise(homeFolderName: homeFolderName) { return false }
            switch s.state {
            case .unknown:
                return false
            case .done:
                return lastEventAge(s) <= doneVisibilityHorizon
            case .stale:
                return lastEventAge(s) <= staleVisibilityHorizon
            case .working, .quietWorking, .permissionRequested:
                return true
            }
        }

        // 2. Done cap (eligible is already freshest-first within the done group).
        var doneShown = 0
        var candidates: [ClaudeSession] = []
        for s in eligible {
            if s.state == .done {
                if doneShown >= maxDoneRows { continue }
                doneShown += 1
            }
            candidates.append(s)
        }

        // 3. Row cap.
        let visible = Array(candidates.prefix(maxVisibleRows))
        let hiddenCount = max(0, eligible.count - visible.count)

        // 4. Overflow — the eligible sessions the compact list elided, in the same attention-first
        // order, for the expandable "more recent sessions" control. Capped at `maxOverflowRows` so
        // the expanded view stays a bounded peek; anything past that is `olderHiddenCount`.
        let visibleIDs = Set(visible.map(\.id))
        let overflow = eligible.filter { !visibleIDs.contains($0.id) }
        let overflowShown = Array(overflow.prefix(maxOverflowRows))
        let olderHiddenCount = max(0, hiddenCount - overflowShown.count)

        // 5. Naming + disambiguation (primary and overflow rows named independently).
        return Presentation(
            rows: disambiguate(visible),
            hiddenCount: hiddenCount,
            overflowRows: disambiguate(overflowShown),
            olderHiddenCount: olderHiddenCount
        )
    }

    /// Pair each session with its display name, appending a 1-based index only when two or more
    /// of the *visible* rows share the same base name. Indices are assigned by `startedAt`
    /// ascending (then id) so a given session keeps the same number across ticks as long as the
    /// colliding set is stable. Rows are returned in the input order (attention-first).
    static func disambiguate(_ sessions: [ClaudeSession]) -> [RadarRow] {
        let groups = Dictionary(grouping: sessions, by: { $0.displayName })
        var indexByID: [String: Int] = [:]
        for (_, group) in groups where group.count > 1 {
            let ordered = group.sorted {
                $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.id < $1.id
            }
            for (offset, session) in ordered.enumerated() {
                indexByID[session.id] = offset + 1
            }
        }
        return sessions.map { session in
            if let index = indexByID[session.id] {
                return RadarRow(session: session, name: "\(session.displayName) \(index)")
            }
            return RadarRow(session: session, name: session.displayName)
        }
    }
}
