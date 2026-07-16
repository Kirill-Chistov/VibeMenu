import Foundation

// Codex Desktop session detection — the pure per-session state for the shared session rows
// (docs/decisions/0017-codex-session-support.md).
//
// This is a **fresh, privacy-constrained rewrite** from the v0.2 baseline; it deliberately
// does NOT reuse the earlier, unreliable Codex attempt. VibeMenu derives a Codex session's
// state from ONLY safe, allowlisted metadata in Codex Desktop's own rollout files
// (`~/.codex/sessions/**/rollout-*.jsonl`), parsed by `CodexRolloutParser`:
//
//   * the session id (opaque; row identity + dedup — never shown);
//   * the `originator` string, used ONLY to keep "Codex Desktop" sessions and drop the shared
//     Codex **CLI** ones (`~/.codex` is shared between the Desktop app and the CLI);
//   * the project **folder name** — the *basename* of `cwd`, never a path;
//   * per-line ISO timestamps (activity recency);
//   * a `task_complete` event marker (a reliable "done" signal).
//
// What it never reads or surfaces (docs/PRIVACY.md, AGENTS.md §6/§8): prompts, responses,
// reasoning, tool input/output, command text, full paths, repo URLs (`git.*`), account ids,
// tokens, API keys, or auth files. The value types below structurally cannot hold any of that.
//
// ## Shared keep-awake input, kept outside this value model
//
// This file deliberately has no power side effects. `CodexSessionActivity.automationIntent` maps
// these derived states into the shared keep-awake model: only `.active` holds, and every other state
// releases. Titles, row visibility, and other presentation metadata never affect that decision.
//
// This file is pure and I/O-free (value types + a pure `derive`), so it is unit-tested with
// synthetic summaries. The file reading lives in the `CodexSessionReader` adapter.

// MARK: - Per-session state

/// The state of a single Codex Desktop session in the shared session list.
///
/// Derived from that session's newest rollout activity timestamp and whether its latest turn
/// ended with a `task_complete` marker. Deliberately conservative: with no per-session heartbeat
/// from Codex, VibeMenu cannot tell "actively working" from "silent mid-tool" during a quiet
/// stretch, so it only claims `.active` on *very recent* activity and otherwise ages down to
/// `.idle`/`.stale` — it never fabricates a "working" state (task Part 3: "no fake working",
/// "avoid false active states").
public enum CodexSessionState: String, Equatable, Sendable, CaseIterable {
    /// Very recent rollout activity (≤ `activeWindow`) with the latest turn **not** finished —
    /// Codex is working right now. The only state that reads as live.
    case active

    /// Recent activity (≤ `idleWindow`) but not fresh enough to call active — a session used a
    /// little while ago that may still be open.
    case idle

    /// The latest turn ended with a reliable `task_complete` marker within `doneWindow` — Codex
    /// finished and is waiting for the next prompt. A normal finished turn, never "needs you".
    case done

    /// No recent activity (older than `idleWindow`, or a completion older than `doneWindow`) —
    /// likely finished long ago or abandoned. De-emphasised, then pruned by the reader.
    case stale

    /// Indeterminate (e.g. a summary with no usable timestamp). Rare; kept explicit rather than
    /// guessing an activity state.
    case unknown
}

extension CodexSessionState {
    /// Default windows, mirroring the conservative spirit of the Claude radar but tuned for a
    /// source with **no heartbeat**. `activeWindow` is short so a session only reads "Active" on
    /// genuinely fresh activity; `idleWindow` keeps a recently-used session visible as Idle; a
    /// completion stays "Done" for `doneWindow` then falls to Stale.
    public static let defaultActiveWindow: TimeInterval = 60
    public static let defaultIdleWindow: TimeInterval = 15 * 60
    public static let defaultDoneWindow: TimeInterval = 15 * 60

    /// Short, human-readable label for a session row (pure/testable, not UI styling). A finished
    /// turn reads **"Done"**, never a high-priority "Waiting" — Codex gives VibeMenu no reliable
    /// approval/attention signal, so nothing here is ever styled as "needs you".
    public var label: String {
        switch self {
        case .active: "Active"
        case .idle: "Idle"
        case .done: "Done"
        case .stale: "Stale"
        case .unknown: "Unknown"
        }
    }

    /// Framework-free colour intent the app maps to a SwiftUI colour (VibeMenuCore imports no
    /// SwiftUI/AppKit). Kept separate from Claude's style enum so the two providers stay
    /// independent (task Part 2/3: separate Codex types from Claude).
    public var displayStyle: CodexSessionDisplayStyle {
        switch self {
        case .active: .working
        case .idle: .idle
        case .done: .done
        case .stale, .unknown: .inactive
        }
    }

    /// Sort key for the session list: most-active first. Lower sorts first; ties broken by
    /// recency in the reader. `.done` sorts below `.idle` so a finished session never pushes a
    /// still-open one out of the compact list.
    public var sortPriority: Int {
        switch self {
        case .active: 0
        case .idle: 1
        case .done: 2
        case .stale: 3
        case .unknown: 4
        }
    }

    /// Whether a row in this state shows the elapsed timer. Only `.active` does — a finished/idle
    /// session showing a running clock would read as if it were still working. Matches the Claude
    /// radar's rule that `.done`/stale rows are timer-less.
    public var showsElapsedTimer: Bool {
        self == .active
    }
}

/// Framework-free colour intent for a Codex session state; the app maps it to a real SwiftUI
/// `Color`. Mirrors `ClaudeSessionDisplayStyle` but kept as its own type so Codex and Claude
/// display code never entangle.
public enum CodexSessionDisplayStyle: String, Equatable, Sendable, CaseIterable {
    case working    // active
    case idle       // recently used
    case done       // finished a turn
    case inactive   // stale / unknown
}

// MARK: - Session value

/// One Codex Desktop session in the shared session list.
///
/// A pure value type carrying only allowlisted metadata. Note what is **not** here: no prompt or
/// response text, no reasoning, no tool input/output, no command text, no full `cwd` path, no repo
/// URL, no account id. The only human-readable identity is `folderName` — the *basename* of the
/// session's working directory (e.g. `"VibeMenu"`), never a path. The opaque `id` is used for row
/// identity/dedup and is never displayed (docs/PRIVACY.md).
public struct CodexSession: Equatable, Sendable, Identifiable {
    /// The Codex session id (opaque; stable row identity + dedup). Never shown.
    public let id: String

    /// The derived display state.
    public let state: CodexSessionState

    /// The project **folder name** — the final path component of the session's `cwd`, e.g.
    /// `"VibeMenu"`. Never a full path or a parent directory. `nil` when unavailable, in which
    /// case `displayName` falls back to a generic label.
    public let folderName: String?

    /// A safe, sanitised session **title** from Codex Desktop's `session_index.jsonl` (`thread_name`),
    /// when one is available and passes `CodexTitleSanitizer` (see `CodexSessionTitle.swift`). `nil`
    /// when absent or unsafe, in which case `displayName` falls back to `folderName`. Never a path,
    /// URL, prompt, or session id — only a short curated title.
    public let title: String?

    /// When Codex started the session — the real `session_meta.timestamp` from the rollout (not a
    /// first-observed time, so it survives an app restart). Drives the active row's elapsed timer.
    public let startedAt: Date

    /// When the session's newest rollout line was written (its last activity). Drives the state
    /// derivation and recency sorting.
    public let lastActivity: Date

    /// The agent name — always `"Codex"`. Drives the row's agent pill so Claude and Codex rows are
    /// clearly labelled in the shared list.
    public let agent: String

    public init(
        id: String,
        state: CodexSessionState,
        folderName: String?,
        startedAt: Date,
        lastActivity: Date,
        title: String? = nil,
        agent: String = "Codex"
    ) {
        self.id = id
        self.state = state
        self.folderName = folderName
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.title = title
        self.agent = agent
    }
}

extension CodexSession {
    /// The generic name shown when no folder name is available.
    public static let genericName = "Codex session"

    /// The human-readable base name for a row, in fallback order: the safe Codex thread **title**,
    /// else the project **folder name**, else a generic label. Never a full path, URL, prompt, or
    /// session id. A disambiguation index may be appended by the presenter when two visible rows
    /// share a base name.
    public var displayName: String {
        title ?? folderName ?? Self.genericName
    }

    /// A short, opaque disambiguator derived from the session id (first 6 chars). Not shown;
    /// retained for tests/diagnostics parity with `ClaudeSession`. Never logged.
    public var shortID: String {
        String(id.prefix(6))
    }

    /// Session duration at `now` (clamped ≥ 0 for clock skew) — real wall-clock since Codex
    /// started the session (`startedAt`), so an active row shows how long the session has run.
    public func elapsed(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    /// A compact elapsed label for an active row (e.g. `"7s"`, `"1m 45s"`, `"1h 5m"`). Reuses the
    /// Claude radar's pure duration formatter so both providers format time identically.
    public func elapsedLabel(now: Date) -> String {
        ClaudeSession.shortDuration(elapsed(now: now))
    }
}

// MARK: - Pure state derivation

extension CodexSessionState {
    /// Derive a Codex session's state from its newest-activity age and whether its latest turn
    /// ended with a `task_complete` marker. Pure and I/O-free.
    ///
    /// Rules (task Part 3 heuristic):
    ///   1. **Ended with completion** ⇒ `.done` while fresh (≤ `doneWindow`), else `.stale`.
    ///      "Done" is claimed **only** on the reliable completion marker — never guessed.
    ///   2. **Not completed** (mid-turn / a new prompt just submitted): `≤ activeWindow` ⇒
    ///      `.active`; `≤ idleWindow` ⇒ `.idle`; else `.stale`. `.active` requires *very recent*
    ///      activity so a long silent stretch never reads as a fake "working".
    public static func derive(
        age: TimeInterval,
        endedWithCompletion: Bool,
        activeWindow: TimeInterval = CodexSessionState.defaultActiveWindow,
        idleWindow: TimeInterval = CodexSessionState.defaultIdleWindow,
        doneWindow: TimeInterval = CodexSessionState.defaultDoneWindow
    ) -> CodexSessionState {
        let a = max(0, age)   // clamp clock skew (future timestamp) to "just now"

        if endedWithCompletion {
            return a <= doneWindow ? .done : .stale
        }
        if a <= activeWindow { return .active }
        if a <= idleWindow { return .idle }
        return .stale
    }
}

// MARK: - Presentation (pure caps + name disambiguation)

/// One presented Codex row: a session paired with the exact name to render. `name` is
/// `session.displayName` plus a disambiguation index when two visible rows share a base name
/// (e.g. two `VibeMenu` Codex sessions become `VibeMenu 1` / `VibeMenu 2`).
public struct CodexRow: Equatable, Sendable, Identifiable {
    public let session: CodexSession
    public let name: String
    public var id: String { session.id }

    public init(session: CodexSession, name: String) {
        self.session = session
        self.name = name
    }
}

/// Pure presentation for the Codex portion of the AI Agent session list: cap to a caller-provided
/// budget and disambiguate names. The reader already sorts most-active-first, so this only *caps*
/// and *names* — it never re-prioritises. Fully unit-tested (no SwiftUI, no I/O).
///
/// The `limit` is supplied by the menu so Claude and Codex share one compact budget (Claude rows
/// take slots first; Codex fills the remainder — task Part 4: "up to 4 total visible sessions
/// across providers").
public enum CodexSessionRadar {
    /// Default cap when the caller doesn't pass a budget (Codex shown on its own).
    public static let maxVisibleRows = 4

    public struct Presentation: Equatable, Sendable {
        public let rows: [CodexRow]
        /// Eligible sessions the cap elided (drives a "+N more Codex sessions" note).
        public let hiddenCount: Int

        public init(rows: [CodexRow], hiddenCount: Int) {
            self.rows = rows
            self.hiddenCount = hiddenCount
        }
    }

    /// Cap `sessions` to `limit` (already most-active-first) and name each row, appending a stable
    /// index when several visible rows share a base name.
    public static func present(_ sessions: [CodexSession], limit: Int = maxVisibleRows) -> Presentation {
        let capped = max(0, limit)
        let visible = Array(sessions.prefix(capped))
        let hidden = max(0, sessions.count - visible.count)
        return Presentation(rows: disambiguate(visible), hiddenCount: hidden)
    }

    /// Pair each session with its display name, appending a 1-based index only when two or more of
    /// the visible rows share a base name. Indices are assigned by `startedAt` ascending (then id)
    /// so a session keeps its number across ticks while the colliding set is stable. Mirrors
    /// `SessionRadar.disambiguate` for Claude.
    static func disambiguate(_ sessions: [CodexSession]) -> [CodexRow] {
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
                return CodexRow(session: session, name: "\(session.displayName) \(index)")
            }
            return CodexRow(session: session, name: session.displayName)
        }
    }
}
