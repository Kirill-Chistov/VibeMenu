import Foundation

// Manual dismiss / hide for Session Radar rows (docs/decisions/0013-session-title-and-dismiss.md).
//
// A user can remove a session from VibeMenu's list (swipe the row, or its context-menu "Hide"
// item). This is a **VibeMenu-only view control**: it hides the row here and nothing else. It
// does not delete any Claude data, does not stop or kill the Claude session, and touches no
// files — it only filters what the radar draws.
//
// Chosen behaviour: **Option 2 — hide until the session emits a new event** (the task's
// recommended option). Dismissing records the session's current `lastEventAt`; the row stays
// hidden as long as that is still its newest event. The instant a *newer* heartbeat arrives
// (the hook only writes on real activity — a prompt, a tool call, a stop/notification), the
// session un-dismisses and reappears in its new state. So dismissing a *finished* session
// clears it for good (nothing new will be written until it's pruned), while dismissing a live
// session simply defers it until its next action. This is strictly more useful than Option 1
// (hide-until-restart) at no extra complexity, and needs no persistence: state is in-memory,
// so a restart also clears every dismissal (satisfying "hidden at least until app restart").
//
// Pure value type so the filtering + un-dismiss logic is unit-tested with synthetic sessions;
// the `ClaudeActivityModel` owns one instance and drives it from the main actor.

/// Tracks which Session Radar rows the user has manually hidden, and when.
///
/// The stored value per session id is the `lastEventAt` observed at dismissal — the watermark a
/// newer event must cross to bring the row back. See the file note for the behaviour rationale.
public struct DismissedSessionRegistry: Equatable, Sendable {
    /// session id → the `lastEventAt` at the moment it was dismissed (the un-hide watermark).
    private var dismissedAt: [String: Date]

    public init() {
        self.dismissedAt = [:]
    }

    /// Whether the registry currently holds any dismissal (for tests / diagnostics).
    public var isEmpty: Bool { dismissedAt.isEmpty }

    /// Mark a session hidden. Records its current `lastEventAt` as the watermark; a later event
    /// newer than this un-hides it (see `reconcile`). Dismissing again refreshes the watermark
    /// to the latest event, so a row the user re-hides after it reappeared stays hidden until
    /// its *next* event.
    public mutating func dismiss(_ session: ClaudeSession) {
        dismissedAt[session.id] = session.lastEventAt
    }

    /// Whether this session would currently be hidden: dismissed, and with no event newer than
    /// the dismissal watermark. Pure query (does not mutate); `reconcile` is what prunes.
    public func isHidden(_ session: ClaudeSession) -> Bool {
        guard let watermark = dismissedAt[session.id] else { return false }
        return session.lastEventAt <= watermark
    }

    /// Filter a fresh radar list to the rows that should be visible, and update the registry:
    ///   * a dismissed session with a **newer** event un-dismisses (its watermark is dropped)
    ///     and is included;
    ///   * a dismissed session with **no** newer event stays hidden (watermark kept);
    ///   * a dismissal for a session **no longer present** (pruned from the radar) is dropped,
    ///     so the map can't grow unbounded.
    /// Returns the visible sessions in the same order they came in (attention-first preserved).
    public mutating func reconcile(with sessions: [ClaudeSession]) -> [ClaudeSession] {
        var kept: [ClaudeSession] = []
        var nextDismissed: [String: Date] = [:]
        for session in sessions {
            guard let watermark = dismissedAt[session.id] else {
                kept.append(session)   // never dismissed → visible
                continue
            }
            if session.lastEventAt > watermark {
                kept.append(session)   // new activity since dismissal → un-hide, drop watermark
            } else {
                nextDismissed[session.id] = watermark   // still hidden → keep watermark
            }
        }
        dismissedAt = nextDismissed
        return kept
    }
}
