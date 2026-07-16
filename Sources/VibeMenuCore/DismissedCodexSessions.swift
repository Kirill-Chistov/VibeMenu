import Foundation

// Manual dismiss / hide for Codex Desktop session rows (docs/decisions/0017-codex-session-support.md,
// Fix 2). Mirrors the Claude `DismissedSessionRegistry` exactly so hiding a Codex row behaves the same
// as hiding a Claude row.
//
// A user can remove a Codex row from VibeMenu's list (swipe the row, or its right-click "Hide" item).
// This is a **VibeMenu-only view control**: it hides the row here and nothing else. It does not delete
// any Codex data, does not stop the Codex session, and touches no files — it only filters what the
// unified AI Agent list draws.
//
// Chosen behaviour — **hide until the session shows newer activity** (the same Option 2 Claude uses):
// dismissing records the session's current `lastActivity`; the row stays hidden as long as that is
// still its newest activity. The instant a *newer* rollout line advances `lastActivity`, the session
// un-dismisses and reappears in its new state. So dismissing a *finished/idle* session clears it for
// good (nothing new will be written until it's pruned by the reader), while dismissing a still-live
// session simply defers it until its next activity — matching Claude precisely. No persistence: state
// is in-memory, so an app restart clears every dismissal.
//
// Crucially the watermark is keyed on the **opaque Codex session id** (`CodexSession.id`, the rollout
// `session_id`), which is stable across title/folder changes — a session that gets a new safe title
// keeps the same id and therefore stays hidden (task rule: "Codex hidden ID remains stable across
// title changes"). It never keys on the title or folder name.
//
// Pure value type so the filtering + un-dismiss logic is unit-tested with synthetic sessions; the
// `CodexSessionModel` owns one instance and drives it from the main actor.

/// Tracks which Codex session rows the user has manually hidden, and the activity watermark each must
/// cross to reappear. See the file note for the behaviour rationale.
public struct DismissedCodexRegistry: Equatable, Sendable {
    /// Codex session id → the `lastActivity` observed at dismissal (the un-hide watermark).
    private var dismissedAt: [String: Date]

    public init() {
        self.dismissedAt = [:]
    }

    /// Whether the registry currently holds any dismissal (for tests / diagnostics).
    public var isEmpty: Bool { dismissedAt.isEmpty }

    /// Mark a session hidden. Records its current `lastActivity` as the watermark; later activity newer
    /// than this un-hides it (see `reconcile`). Dismissing again refreshes the watermark to the latest
    /// activity, so a row the user re-hides after it reappeared stays hidden until its *next* activity.
    public mutating func dismiss(_ session: CodexSession) {
        dismissedAt[session.id] = session.lastActivity
    }

    /// Whether this session would currently be hidden: dismissed, and with no activity newer than the
    /// dismissal watermark. Pure query (does not mutate); `reconcile` is what prunes.
    public func isHidden(_ session: CodexSession) -> Bool {
        guard let watermark = dismissedAt[session.id] else { return false }
        return session.lastActivity <= watermark
    }

    /// Filter a fresh session list to the rows that should be visible, and update the registry:
    ///   * a dismissed session with **newer** activity un-dismisses (its watermark is dropped) and is
    ///     included;
    ///   * a dismissed session with **no** newer activity stays hidden (watermark kept);
    ///   * a dismissal for a session **no longer present** (pruned from the reader) is dropped, so the
    ///     map can't grow unbounded.
    /// Returns the visible sessions in the same order they came in (most-active-first preserved).
    public mutating func reconcile(with sessions: [CodexSession]) -> [CodexSession] {
        var kept: [CodexSession] = []
        var nextDismissed: [String: Date] = [:]
        for session in sessions {
            guard let watermark = dismissedAt[session.id] else {
                kept.append(session)   // never dismissed → visible
                continue
            }
            if session.lastActivity > watermark {
                kept.append(session)   // new activity since dismissal → un-hide, drop watermark
            } else {
                nextDismissed[session.id] = watermark   // still hidden → keep watermark
            }
        }
        dismissedAt = nextDismissed
        return kept
    }
}
