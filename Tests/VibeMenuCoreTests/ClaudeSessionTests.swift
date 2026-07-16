import Foundation
import Testing
@testable import VibeMenuCore

// Session Radar tests (docs/decisions/0011-session-radar.md). Everything here is pure and
// synthetic — no live `claude` process, no `~/.claude`, no filesystem. Three concerns:
//   * per-session state derivation (`ClaudeSessionState.derive`) over (event, age, process);
//   * the stateful `ClaudeSessionStore` (startedAt tracking, pruning, sorting);
//   * the invariant that the radar's aggregate keep-awake (`sessionsKeepAwakeIntent`) is
//     **identical** to the wired `ClaudeActivityState.automationIntent` — so the display and
//     the power decision can never drift.

// MARK: - Per-session state derivation

@Suite("ClaudeSessionState.derive")
struct ClaudeSessionDeriveTests {
    private func derive(
        _ event: ClaudeHeartbeatEvent, age: TimeInterval, process: Bool
    ) -> ClaudeSessionState {
        ClaudeSessionState.derive(event: event, age: age, processPresent: process)
    }

    /// `SessionEnd` is a clean finish and reads `.done` regardless of process presence.
    @Test func sessionEndIsDone() {
        #expect(derive(.sessionEnd, age: 1, process: true) == .done)
        #expect(derive(.sessionEnd, age: 1, process: false) == .done)
        #expect(derive(.sessionEnd, age: 5000, process: true) == .done)
    }

    /// Fresh active events with a live process read `.working` (within the 120s window).
    @Test func freshActiveIsWorking() {
        for e in [ClaudeHeartbeatEvent.userPromptSubmit, .preToolUse, .postToolUse, .subagentStart] {
            #expect(derive(e, age: 2, process: true) == .working, "\(e)")
        }
        #expect(derive(.preToolUse, age: 120, process: true) == .working)   // boundary ≤ window
    }

    /// An active event aged past the display window but within the quiet-hold cap, process
    /// present, reads `.quietWorking` — the long silent tool/subagent phase (still holding).
    @Test func agedActiveWithinCapIsQuietWorking() {
        #expect(derive(.preToolUse, age: 121, process: true) == .quietWorking)
        #expect(derive(.preToolUse, age: 300, process: true) == .quietWorking)
        #expect(derive(.preToolUse, age: 900, process: true) == .quietWorking)  // boundary ≤ cap
    }

    /// An active event past the quiet-hold cap (process present) reads `.stale` — no longer
    /// holding, consistent with the automation releasing at the cap.
    @Test func activePastCapIsStale() {
        #expect(derive(.preToolUse, age: 901, process: true) == .stale)
        #expect(derive(.userPromptSubmit, age: 5000, process: true) == .stale)
    }

    /// Work-in-progress but not display-active events (`SubagentStop`, unknown/future) read
    /// `.quietWorking` while fresh-enough (they still hold), then `.stale` past the cap.
    @Test func subagentStopAndUnknownAreQuietWorkingThenStale() {
        #expect(derive(.subagentStop, age: 2, process: true) == .quietWorking)
        #expect(derive(.subagentStop, age: 900, process: true) == .quietWorking)
        #expect(derive(.subagentStop, age: 901, process: true) == .stale)
        #expect(derive(.unknown, age: 2, process: true) == .quietWorking)
        #expect(derive(.unknown, age: 901, process: true) == .stale)
    }

    /// Not-working events with a live process read `.done` — a normal finished/idle turn, not
    /// high-priority "Waiting" (docs/decisions/0015). This is the core Issue-3 reclassification:
    /// `Stop`/`Notification`/`SessionStart` no longer produce an attention-worthy state.
    @Test func notWorkingEventsAreDone() {
        #expect(derive(.stop, age: 2, process: true) == .done)
        #expect(derive(.notification, age: 2, process: true) == .done)
        #expect(derive(.sessionStart, age: 2, process: true) == .done)
        // Age doesn't matter while the process is alive — a finished turn stays `.done`.
        #expect(derive(.stop, age: 5000, process: true) == .done)
    }

    /// No visible process: a heartbeat isn't proof of life. Fresh ⇒ `.done` (finished/idle;
    /// process detection can miss a node-hosted / just-exited CLI); older ⇒ `.stale`. Never a
    /// high-priority state without a process.
    @Test func noProcessIsDoneThenStale() {
        #expect(derive(.preToolUse, age: 2, process: false) == .done)
        #expect(derive(.stop, age: 2, process: false) == .done)
        #expect(derive(.preToolUse, age: 121, process: false) == .stale)
        #expect(derive(.subagentStop, age: 500, process: false) == .stale)
        // …but an explicit SessionEnd is still `.done` even with no process.
        #expect(derive(.sessionEnd, age: 500, process: false) == .done)
    }

    /// Clock skew (a future timestamp ⇒ negative age) is clamped to "just now".
    @Test func futureTimestampClampsToWorking() {
        #expect(derive(.preToolUse, age: -60, process: true) == .working)
    }

    /// `.permissionRequested` is derived **only** from the real `PermissionRequest` hook event, and
    /// only while a `claude` process is visible (a pending approval whose process is gone can't be
    /// confirmed, so it degrades to done/stale — never a fabricated approval). No *other* event, for
    /// any age or process state, ever produces it. This is the tightened form of the old
    /// "never fabricated" guarantee now that a genuine signal exists (`PermissionRequest`).
    @Test func permissionRequestedDerivedOnlyFromPermissionRequestEvent() {
        let ages: [TimeInterval] = [-10, 0, 1, 60, 120, 121, 500, 900, 901, 1800, 5000]
        for event in ClaudeHeartbeatEvent.allCases {
            for age in ages {
                for process in [true, false] {
                    let state = ClaudeSessionState.derive(event: event, age: age, processPresent: process)
                    if event == .permissionRequested && process {
                        #expect(state == .permissionRequested, "PermissionRequest process=true age=\(age)")
                    } else {
                        #expect(state != .permissionRequested, "\(event) age=\(age) process=\(process)")
                    }
                }
            }
        }
    }

    /// A `PermissionRequest` with a live process derives the high-priority `.permissionRequested`
    /// ("Needs approval") state at **any** age — a real approval can legitimately wait a long time
    /// while the user is away, so it is never aged out to stale (the store's prune horizon still
    /// bounds it). With no visible process it degrades to done (fresh) / stale (old).
    @Test func permissionRequestEventDerivesNeedsApproval() {
        for age in [TimeInterval(-5), 0, 1, 120, 901, 5000] {
            #expect(derive(.permissionRequested, age: age, process: true) == .permissionRequested,
                    "age=\(age)")
        }
        #expect(derive(.permissionRequested, age: 1, process: false) == .done)
        #expect(derive(.permissionRequested, age: 5000, process: false) == .stale)
    }

    /// **Ordinary hook events never derive a `needsAttention` state.** Only the real
    /// `PermissionRequest` event (with a live process) produces the one attention state
    /// (`.permissionRequested`); every *other* event, for any age/process, yields a non-attention
    /// state — VibeMenu never fabricates a "Needs approval" row from a normal finished/idle turn
    /// (docs/decisions/0015).
    @Test func ordinaryEventsNeverProduceAnAttentionState() {
        let ages: [TimeInterval] = [-10, 0, 1, 60, 120, 121, 500, 900, 901, 1800, 5000]
        for event in ClaudeHeartbeatEvent.allCases where event != .permissionRequested {
            for age in ages {
                for process in [true, false] {
                    let state = ClaudeSessionState.derive(
                        event: event, age: age, processPresent: process
                    )
                    #expect(!state.needsAttention, "\(event) age=\(age) process=\(process) → \(state)")
                }
            }
        }
    }

    /// `Stop` (normal completion) and `SessionEnd` map to `.done` — never a high-priority state —
    /// for every age with a live process (task Issue 3: Stop/SessionEnd are not "Waiting").
    @Test func stopAndSessionEndMapToDoneNotAttention() {
        for age in [TimeInterval(1), 60, 121, 900, 901, 5000] {
            #expect(derive(.stop, age: age, process: true) == .done, "stop age=\(age)")
            #expect(derive(.sessionEnd, age: age, process: true) == .done, "sessionEnd age=\(age)")
        }
    }
}

// MARK: - State helpers

@Suite("ClaudeSessionState helpers")
struct ClaudeSessionStateHelperTests {
    @Test func holdsSleepPreventionOnlyForWorkingStates() {
        #expect(ClaudeSessionState.working.holdsSleepPrevention)
        #expect(ClaudeSessionState.quietWorking.holdsSleepPrevention)
        for s in [ClaudeSessionState.permissionRequested, .done, .stale, .unknown] {
            #expect(!s.holdsSleepPrevention, "\(s)")
        }
    }

    /// Only a real approval prompt needs attention now — a normal finished turn (`.done`) does
    /// not (docs/decisions/0015).
    @Test func needsAttentionOnlyForApproval() {
        #expect(ClaudeSessionState.permissionRequested.needsAttention)
        for s in [ClaudeSessionState.working, .quietWorking, .done, .stale, .unknown] {
            #expect(!s.needsAttention, "\(s)")
        }
    }

    /// Attention-first ordering: needs-approval → working → quietWorking → done → stale →
    /// unknown. `.done` sorts below the working states so finished sessions never outrank active
    /// ones (docs/decisions/0015).
    @Test func sortPriorityIsAttentionFirst() {
        let ordered = ClaudeSessionState.allCases.sorted { $0.sortPriority < $1.sortPriority }
        #expect(ordered == [.permissionRequested, .working, .quietWorking,
                            .done, .stale, .unknown])
    }

    /// Needs-approval sorts strictly above working (the high-priority signal wins if/when a real
    /// approval event exists) and working sorts strictly above done.
    @Test func approvalSortsAboveWorkingAboveDone() {
        #expect(ClaudeSessionState.permissionRequested.sortPriority < ClaudeSessionState.working.sortPriority)
        #expect(ClaudeSessionState.working.sortPriority < ClaudeSessionState.done.sortPriority)
        #expect(ClaudeSessionState.quietWorking.sortPriority < ClaudeSessionState.done.sortPriority)
    }

    @Test func everyStateHasANonEmptyLabel() {
        for s in ClaudeSessionState.allCases { #expect(!s.label.isEmpty, "\(s)") }
    }

    /// The reserved high-priority state is labelled "Needs approval" (not generic "Waiting");
    /// a finished turn is "Done" (task Issue 3 UI copy).
    @Test func approvalAndDoneLabels() {
        #expect(ClaudeSessionState.permissionRequested.label == "Needs approval")
        #expect(ClaudeSessionState.done.label == "Done")
    }

    @Test func displayStyleMapping() {
        #expect(ClaudeSessionState.working.displayStyle == .working)
        #expect(ClaudeSessionState.quietWorking.displayStyle == .working)
        #expect(ClaudeSessionState.permissionRequested.displayStyle == .attention)
        #expect(ClaudeSessionState.done.displayStyle == .done)
        #expect(ClaudeSessionState.stale.displayStyle == .inactive)
        #expect(ClaudeSessionState.unknown.displayStyle == .inactive)
    }

    /// Timer visibility (task Issue 2): live/working/approval rows show the elapsed timer; a
    /// finished `.done` row (and stale/unknown) shows none.
    @Test func showsElapsedTimerOnlyForLiveStates() {
        #expect(ClaudeSessionState.working.showsElapsedTimer)
        #expect(ClaudeSessionState.quietWorking.showsElapsedTimer)
        #expect(ClaudeSessionState.permissionRequested.showsElapsedTimer)
        for s in [ClaudeSessionState.done, .stale, .unknown] {
            #expect(!s.showsElapsedTimer, "\(s)")
        }
    }
}

// MARK: - Session value helpers

@Suite("ClaudeSession helpers")
struct ClaudeSessionValueTests {
    private let now = Date(timeIntervalSince1970: 4_000_000)

    private func session(id: String, startedAt: Date) -> ClaudeSession {
        ClaudeSession(id: id, state: .working, event: .preToolUse, startedAt: startedAt, lastEventAt: startedAt)
    }

    @Test func shortIDIsFirstSixCharacters() {
        #expect(session(id: "abcdef123456", startedAt: now).shortID == "abcdef")
        #expect(session(id: "ab", startedAt: now).shortID == "ab")   // shorter than 6 ⇒ whole id
        #expect(session(id: "", startedAt: now).shortID == "")
    }

    @Test func agentDefaultsToClaude() {
        #expect(session(id: "x", startedAt: now).agent == "Claude")
    }

    @Test func placeholdersAreNil() {
        let s = session(id: "x", startedAt: now)
        #expect(s.projectName == nil)
        #expect(s.title == nil)
        #expect(s.terminal == nil)
        #expect(s.currentActivity == nil)
    }

    /// `displayName` prefers the title, then the project folder name, then the generic fallback —
    /// never a path or a session id (docs/decisions/0013-session-title-and-dismiss.md, 0012).
    @Test func displayNamePrefersTitleThenProjectThenGeneric() {
        let named = ClaudeSession(id: "x", state: .working, event: .preToolUse,
                                  startedAt: now, lastEventAt: now, projectName: "VibeMenu")
        #expect(named.displayName == "VibeMenu")
        #expect(session(id: "x", startedAt: now).displayName == "Claude session")
        #expect(ClaudeSession.genericName == "Claude session")

        // Title wins over the folder name when present.
        let titled = named.withTitle("Session Radar identity")
        #expect(titled.displayName == "Session Radar identity")
        #expect(titled.projectName == "VibeMenu")   // folder name still carried underneath

        // Title alone (no folder name) is still used.
        let titleOnly = session(id: "x", startedAt: now).withTitle("Greeting")
        #expect(titleOnly.displayName == "Greeting")

        // Clearing the title falls back to the folder name.
        #expect(titled.withTitle(nil).displayName == "VibeMenu")
    }

    @Test func elapsedIsClampedAtZero() {
        let s = session(id: "x", startedAt: now)
        #expect(s.elapsed(now: now) == 0)
        #expect(s.elapsed(now: now.addingTimeInterval(-30)) == 0)  // clock skew ⇒ 0, not negative
        #expect(s.elapsed(now: now.addingTimeInterval(90)) == 90)
    }

    /// Two-unit compact format (task Issue 2): seconds only under a minute; minutes+seconds under
    /// an hour (zero seconds dropped); hours+minutes at/above an hour (zero minutes dropped).
    @Test func shortDurationFormatting() {
        // Seconds only.
        #expect(ClaudeSession.shortDuration(0) == "0s")
        #expect(ClaudeSession.shortDuration(7) == "7s")
        #expect(ClaudeSession.shortDuration(25) == "25s")
        #expect(ClaudeSession.shortDuration(59) == "59s")

        // Minutes and seconds, dropping a zero seconds.
        #expect(ClaudeSession.shortDuration(60) == "1m")          // 1m 0s → "1m"
        #expect(ClaudeSession.shortDuration(65) == "1m 5s")
        #expect(ClaudeSession.shortDuration(90) == "1m 30s")
        #expect(ClaudeSession.shortDuration(300) == "5m")         // exact minute → no "0s"
        #expect(ClaudeSession.shortDuration(764) == "12m 44s")
        #expect(ClaudeSession.shortDuration(3599) == "59m 59s")

        // Hours and minutes, dropping a zero minutes.
        #expect(ClaudeSession.shortDuration(3600) == "1h")        // 1h 0m → "1h"
        #expect(ClaudeSession.shortDuration(3900) == "1h 5m")     // 1h 5m
        #expect(ClaudeSession.shortDuration(7200) == "2h")        // 2h 0m → "2h"
        #expect(ClaudeSession.shortDuration(3600 * 23) == "23h")
        #expect(ClaudeSession.shortDuration(3600 * 24) == "24h")  // hours is the top unit

        #expect(ClaudeSession.shortDuration(-5) == "0s")          // negative clamps
    }

    @Test func elapsedLabelUsesShortDuration() {
        let s = session(id: "x", startedAt: now)
        #expect(s.elapsedLabel(now: now.addingTimeInterval(3)) == "3s")
        #expect(s.elapsedLabel(now: now.addingTimeInterval(65)) == "1m 5s")
        #expect(s.elapsedLabel(now: now.addingTimeInterval(3900)) == "1h 5m")
    }

    /// The radar row's timer for a pending approval starts at the **request** (`lastEventAt`), not
    /// the session's first-seen `startedAt` (task: *timer starts at the request*). A session can be
    /// minutes old when the approval fires, but the row must read the *wait* time. Every other state
    /// keeps measuring from `startedAt`.
    @Test func displayElapsedForApprovalMeasuresFromRequest() {
        let started = now
        let requestAt = started.addingTimeInterval(300)          // approval requested 5m into session
        let at = requestAt.addingTimeInterval(42)                // 42s after the request
        let approval = ClaudeSession(id: "s", state: .permissionRequested, event: .permissionRequested,
                                     startedAt: started, lastEventAt: requestAt)
        #expect(approval.displayElapsedLabel(now: at) == "42s")   // request-relative, not "5m 42s"
        #expect(approval.displayElapsed(now: at) == 42)

        // A non-approval state still measures from startedAt (unchanged behaviour).
        let working = ClaudeSession(id: "s", state: .working, event: .preToolUse,
                                    startedAt: started, lastEventAt: requestAt)
        #expect(working.displayElapsedLabel(now: at) == working.elapsedLabel(now: at))
    }
}

// MARK: - Session store

@Suite("ClaudeSessionStore")
struct ClaudeSessionStoreTests {
    private let t0 = Date(timeIntervalSince1970: 4_000_000)

    private func record(
        _ event: ClaudeHeartbeatEvent, at: Date, session: String = "s"
    ) -> ClaudeHeartbeatRecord {
        ClaudeHeartbeatRecord(sessionID: session, event: event, updatedAt: at)
    }

    @Test func defaultPruneHorizonIsThirtyMinutes() {
        #expect(ClaudeSessionStore.defaultPruneHorizon == 30 * 60)
    }

    @Test func derivesOnePerSession() {
        var store = ClaudeSessionStore()
        store.update(
            records: [record(.preToolUse, at: t0, session: "a"),
                      record(.stop, at: t0, session: "b")],
            processPresent: true,
            now: t0
        )
        #expect(store.sessions.count == 2)
        #expect(store.sessions.first(where: { $0.id == "a" })?.state == .working)
        #expect(store.sessions.first(where: { $0.id == "b" })?.state == .done)   // Stop ⇒ done
    }

    /// The newest record per session wins (an older active event can't override a newer Stop).
    @Test func dedupesToNewestRecordPerSession() {
        var store = ClaudeSessionStore()
        store.update(
            records: [record(.preToolUse, at: t0.addingTimeInterval(-30), session: "s"),
                      record(.stop, at: t0, session: "s")],
            processPresent: true,
            now: t0
        )
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].state == .done)   // newest is Stop ⇒ done (docs/decisions/0015)
        #expect(store.sessions[0].event == .stop)
    }

    /// `startedAt` is set on first sight and preserved across ticks, so elapsed grows.
    @Test func startedAtIsPreservedAcrossTicks() {
        var store = ClaudeSessionStore()
        store.update(records: [record(.preToolUse, at: t0)], processPresent: true, now: t0)
        #expect(store.sessions[0].startedAt == t0)

        let t1 = t0.addingTimeInterval(60)
        store.update(records: [record(.preToolUse, at: t1)], processPresent: true, now: t1)
        #expect(store.sessions[0].startedAt == t0)               // preserved, not reset to t1
        #expect(store.sessions[0].elapsed(now: t1) == 60)
        #expect(store.sessions[0].elapsedLabel(now: t1) == "1m")
    }

    /// A session first seen later starts its clock then (not retroactively).
    @Test func newSessionStartsAtFirstSight() {
        var store = ClaudeSessionStore()
        store.update(records: [record(.preToolUse, at: t0, session: "a")], processPresent: true, now: t0)
        let t1 = t0.addingTimeInterval(120)
        store.update(
            records: [record(.preToolUse, at: t1, session: "a"),
                      record(.preToolUse, at: t1, session: "b")],
            processPresent: true, now: t1
        )
        #expect(store.sessions.first(where: { $0.id == "a" })?.startedAt == t0)
        #expect(store.sessions.first(where: { $0.id == "b" })?.startedAt == t1)
    }

    /// A session whose newest event is older than the prune horizon drops off the radar (the
    /// heartbeat file lingers on disk forever; the radar must not).
    @Test func prunesSessionsOlderThanHorizon() {
        var store = ClaudeSessionStore()
        store.update(records: [record(.stop, at: t0)], processPresent: true, now: t0)
        #expect(store.sessions.count == 1)

        // 31 minutes later with no new event for that session ⇒ pruned.
        let late = t0.addingTimeInterval(31 * 60)
        store.update(records: [record(.stop, at: t0)], processPresent: true, now: late)
        #expect(store.sessions.isEmpty)
    }

    /// Rows sort attention-first, ties broken by most-recent event (freshest first). With the
    /// docs/decisions/0015 reclassification a finished turn (`Stop`) is `.done`, so a working
    /// session sorts **above** it; the two finished sessions then order by recency.
    @Test func sortsAttentionFirstThenRecency() {
        var store = ClaudeSessionStore()
        store.update(
            records: [
                record(.stop, at: t0.addingTimeInterval(-5), session: "done-old"),
                record(.preToolUse, at: t0, session: "work"),
                record(.stop, at: t0, session: "done-new")
            ],
            processPresent: true,
            now: t0
        )
        // working (1) before done (3); within done, freshest first. A finished session never
        // outranks the actively-working one.
        #expect(store.sessions.map(\.id) == ["work", "done-new", "done-old"])
    }

    /// docs/decisions/0015 / task Issue 3 (overflow ordering): a pile of finished (`Stop` ⇒ done)
    /// sessions must not push actively-working sessions out of the visible list. The store sorts
    /// working above done and `present` caps done at 2, so every working row stays visible while
    /// the surplus finished rows are the ones that overflow.
    @Test func finishedSessionsDoNotPushOutActiveRows() {
        var store = ClaudeSessionStore()
        var records: [ClaudeHeartbeatRecord] = []
        for i in 0..<3 { records.append(record(.preToolUse, at: t0, session: "work\(i)")) }
        for i in 0..<6 { records.append(record(.stop, at: t0, session: "done\(i)")) }
        store.update(records: records, processPresent: true, now: t0)

        let p = SessionRadar.present(store.sessions, now: t0)
        let visibleWorking = p.rows.filter { $0.session.state == .working }
        let visibleDone = p.rows.filter { $0.session.state == .done }
        #expect(visibleWorking.count == 3)                        // every working session shown
        #expect(visibleDone.count <= SessionRadar.maxDoneRows)    // finished rows capped, not crowding
        // The elided rows are all finished ones — no working session is hidden.
        #expect(p.overflowRows.allSatisfy { $0.session.state == .done })
    }

    @Test func keepAwakeIntentHoldsWhenAnySessionWorks() {
        var store = ClaudeSessionStore()
        store.update(records: [record(.preToolUse, at: t0)], processPresent: true, now: t0)
        #expect(store.keepAwakeIntent == .hold)

        store.update(records: [record(.stop, at: t0)], processPresent: true, now: t0)
        #expect(store.keepAwakeIntent == .release)

        // Mixed: one finished (done), one working ⇒ hold (any working session wins).
        store.update(
            records: [record(.stop, at: t0, session: "a"),
                      record(.preToolUse, at: t0, session: "b")],
            processPresent: true, now: t0
        )
        #expect(store.keepAwakeIntent == .hold)
    }

    @Test func emptyRecordsProduceNoSessions() {
        var store = ClaudeSessionStore()
        store.update(records: [], processPresent: true, now: t0)
        #expect(store.sessions.isEmpty)
        #expect(store.keepAwakeIntent == .release)
    }

    /// The schema-2 project folder name flows from the heartbeat record onto the session, and a
    /// record without one (schema-1) leaves `projectName` nil (docs/decisions/0012).
    @Test func projectNameFlowsFromRecord() {
        var store = ClaudeSessionStore()
        store.update(
            records: [
                ClaudeHeartbeatRecord(sessionID: "a", event: .preToolUse, updatedAt: t0, project: "VibeMenu"),
                ClaudeHeartbeatRecord(sessionID: "b", event: .preToolUse, updatedAt: t0, project: nil)
            ],
            processPresent: true, now: t0
        )
        #expect(store.sessions.first(where: { $0.id == "a" })?.projectName == "VibeMenu")
        #expect(store.sessions.first(where: { $0.id == "a" })?.displayName == "VibeMenu")
        #expect(store.sessions.first(where: { $0.id == "b" })?.projectName == nil)
        #expect(store.sessions.first(where: { $0.id == "b" })?.displayName == "Claude session")
    }
}

// MARK: - Radar presentation (visibility rules + naming)

@Suite("SessionRadar.present")
struct SessionRadarPresentTests {
    private let now = Date(timeIntervalSince1970: 5_000_000)

    /// Build a session directly (bypassing the store) so each test controls state, age, name.
    private func session(
        _ id: String, _ state: ClaudeSessionState, ageSec: TimeInterval = 1,
        project: String? = nil, startedAt: Date? = nil,
        event: ClaudeHeartbeatEvent = .preToolUse, title: String? = nil
    ) -> ClaudeSession {
        let last = now.addingTimeInterval(-ageSec)
        return ClaudeSession(
            id: id, state: state, event: event,
            startedAt: startedAt ?? last, lastEventAt: last, projectName: project, title: title
        )
    }

    @Test func constantsMatchTheSpec() {
        #expect(SessionRadar.maxVisibleRows == 4)
        #expect(SessionRadar.maxDoneRows == 4)
        #expect(SessionRadar.maxDoneRows == SessionRadar.maxVisibleRows)   // done may fill the list
        #expect(SessionRadar.doneVisibilityHorizon == 5 * 60)
        #expect(SessionRadar.staleVisibilityHorizon == 2 * 60)
    }

    /// At most 4 primary rows; the rest counted as hidden.
    @Test func capsAtFourRows() {
        let sessions = (0..<8).map { session("w\($0)", .working, project: "p\($0)") }
        let p = SessionRadar.present(sessions, now: now)
        #expect(p.rows.count == 4)
        #expect(p.hiddenCount == 4)
    }

    /// The 4-row primary cap means the **5th** eligible session is the first to spill into overflow:
    /// it is not shown in the primary list but is revealed by the expandable "more recent sessions"
    /// control (task: max primary visible = 4, extras go to overflow).
    @Test func fifthEligibleSessionGoesToOverflow() {
        let sessions = (0..<5).map { session("w\($0)", .working, project: "p\($0)") }
        let p = SessionRadar.present(sessions, now: now)
        #expect(p.rows.count == 4)                                  // primary capped at 4
        #expect(p.rows.map(\.session.id) == ["w0", "w1", "w2", "w3"])
        #expect(p.hiddenCount == 1)                                 // exactly the 5th session
        #expect(p.overflowRows.map(\.session.id) == ["w4"])        // and it lands in overflow
        #expect(p.olderHiddenCount == 0)
    }

    /// Issue 1 fix: after docs/decisions/0015 folded "finished / idle / waiting for the next
    /// prompt" into `.done`, `.done` is the *normal* resting state, so the primary list must fill
    /// all the way to `maxVisibleRows` with done rows — not be sub-capped at 2. Four done sessions
    /// all show, with nothing hidden. (This is the regression that made only ~2 sessions appear.)
    @Test func doneFillsPrimaryUpToVisibleCap() {
        let sessions = (0..<4).map { session("d\($0)", .done, ageSec: 10, project: "p\($0)") }
        let p = SessionRadar.present(sessions, now: now)
        #expect(p.rows.count == 4)
        #expect(p.hiddenCount == 0)
    }

    /// Done beyond the visible cap overflows exactly like working sessions do: six done → four
    /// primary rows, the surplus two elided into the expandable control.
    @Test func doneBeyondVisibleCapOverflows() {
        let sessions = (0..<6).map { session("d\($0)", .done, ageSec: 10, project: "p\($0)") }
        let p = SessionRadar.present(sessions, now: now)
        #expect(p.rows.count == 4)
        #expect(p.hiddenCount == 2)
    }

    /// Done older than 5 minutes is dropped entirely (not even counted as hidden-recent).
    @Test func hidesOldDone() {
        let fresh = session("fresh", .done, ageSec: 60, project: "A")
        let old = session("old", .done, ageSec: 5 * 60 + 1, project: "B")
        let p = SessionRadar.present([fresh, old], now: now)
        #expect(p.rows.map(\.session.id) == ["fresh"])
        #expect(p.hiddenCount == 0)
    }

    /// Stale older than 2 minutes is dropped; unknown is never shown; fresh stale may show.
    @Test func hidesOldStaleAndAllUnknown() {
        let freshStale = session("s-fresh", .stale, ageSec: 60, project: "A")
        let oldStale = session("s-old", .stale, ageSec: 2 * 60 + 1, project: "B")
        let unknown = session("u", .unknown, ageSec: 1, project: "C")
        let p = SessionRadar.present([freshStale, oldStale, unknown], now: now)
        #expect(p.rows.map(\.session.id) == ["s-fresh"])
        #expect(p.hiddenCount == 0)
    }

    /// Two visible rows sharing a base name get stable 1-based indices (by startedAt); a unique
    /// name is shown bare.
    @Test func disambiguatesCollidingNames() {
        let older = session("a", .working, project: "VibeMenu", startedAt: now.addingTimeInterval(-300))
        let newer = session("b", .working, project: "VibeMenu", startedAt: now.addingTimeInterval(-100))
        let solo = session("c", .working, project: "backend-api")
        let p = SessionRadar.present([newer, older, solo], now: now)
        let byID = Dictionary(uniqueKeysWithValues: p.rows.map { ($0.session.id, $0.name) })
        #expect(byID["a"] == "VibeMenu 1")   // older ⇒ index 1
        #expect(byID["b"] == "VibeMenu 2")   // newer ⇒ index 2
        #expect(byID["c"] == "backend-api")  // unique ⇒ no index
    }

    /// Sessions without a project name collide on the generic label and are also indexed.
    @Test func disambiguatesGenericNames() {
        let a = session("a", .working, startedAt: now.addingTimeInterval(-300))
        let b = session("b", .working, startedAt: now.addingTimeInterval(-100))
        let p = SessionRadar.present([a, b], now: now)
        let names = p.rows.map(\.name).sorted()
        #expect(names == ["Claude session 1", "Claude session 2"])
    }

    /// Input order (attention-first, as the store produces) is preserved in the rows — `present`
    /// only filters and caps, it never re-sorts.
    @Test func preservesInputOrder() {
        let working = session("work", .working, project: "B")
        let doneA = session("done-a", .done, ageSec: 10, project: "A")
        let doneB = session("done-b", .done, ageSec: 20, project: "C")
        let p = SessionRadar.present([working, doneA, doneB], now: now)
        #expect(p.rows.map(\.session.id) == ["work", "done-a", "done-b"])
    }

    @Test func emptyInputIsEmptyPresentation() {
        let p = SessionRadar.present([], now: now)
        #expect(p.rows.isEmpty)
        #expect(p.hiddenCount == 0)
    }

    // MARK: - Home-folder noise filtering (the "kirill 1 / kirill 2" ghost fix)

    private let home = "kirill"

    /// A done, untitled session whose only identity is the home-folder name is the reported
    /// launcher ghost — dropped entirely (not even counted as hidden-recent). A real project
    /// session in the same list still shows.
    @Test func hidesHomeFolderDoneGhost() {
        let ghost = session("g", .done, ageSec: 20, project: home, event: .sessionEnd)
        let real = session("r", .working, project: "VibeMenu")
        let p = SessionRadar.present([real, ghost], now: now, homeFolderName: home)
        #expect(p.rows.map(\.session.id) == ["r"])
        #expect(p.hiddenCount == 0)   // the ghost is noise, not a "more recent session"
    }

    /// A session that has only *started* in the home directory (bare SessionStart, now `.done`,
    /// no prompt yet) is a generic startup ghost — hidden.
    @Test func hidesHomeFolderBareStartGhost() {
        let ghost = session("s", .done, project: home, event: .sessionStart)
        let p = SessionRadar.present([ghost], now: now, homeFolderName: home)
        #expect(p.rows.isEmpty)
    }

    /// A finished, untitled home-directory session (a normal `Stop`, now `.done`) is a throwaway
    /// `$HOME` launch, not high-priority "waiting" — it is hidden (docs/decisions/0015). Only a
    /// title, a real project, or active work earns a home-folder row. This is the inverse of the
    /// pre-0015 behaviour, and the direct fix for finished home-dir rows piling up.
    @Test func hidesHomeFolderFinishedUntitledSession() {
        let finished = session("w", .done, ageSec: 10, project: home, event: .stop)
        let p = SessionRadar.present([finished], now: now, homeFolderName: home)
        #expect(p.rows.isEmpty)
    }

    /// An actively-working home-directory session is shown (the task's explicit exception:
    /// "do not hide real active sessions").
    @Test func showsActivelyWorkingHomeFolderSession() {
        let working = session("k", .working, project: home, event: .preToolUse)
        let p = SessionRadar.present([working], now: now, homeFolderName: home)
        #expect(p.rows.map(\.session.id) == ["k"])
    }

    /// A real Claude **title** always earns a row, even for a done session in the home folder —
    /// a title is never home-folder noise (title beats the folder fallback).
    @Test func titleBeatsHomeFolderFilter() {
        let titled = session("t", .done, ageSec: 20, project: home, event: .sessionEnd, title: "GMT time query")
        let p = SessionRadar.present([titled], now: now, homeFolderName: home)
        #expect(p.rows.map(\.name) == ["GMT time query"])
    }

    /// A `stale` untitled home-folder session (aged, unconfirmed) is also treated as noise.
    @Test func hidesStaleHomeFolderSession() {
        let stale = session("st", .stale, ageSec: 30, project: home, event: .sessionStart)
        let p = SessionRadar.present([stale], now: now, homeFolderName: home)
        #expect(p.rows.isEmpty)
    }

    /// With no home-folder name provided the filter is disabled — behaviour is unchanged, so a
    /// "kirill" done session still shows (backward compatibility for callers that opt out).
    @Test func homeFilterDisabledWhenNameIsNil() {
        let ghost = session("g", .done, ageSec: 20, project: home, event: .sessionEnd)
        let p = SessionRadar.present([ghost], now: now)   // homeFolderName defaults to nil
        #expect(p.rows.map(\.session.id) == ["g"])
    }

    /// A non-home project done session is unaffected by the home filter (only the home folder
    /// name triggers it) — real project work is never dropped by this rule.
    @Test func nonHomeProjectDoneSessionUnaffected() {
        let real = session("v", .done, ageSec: 20, project: "VibeMenu", event: .sessionEnd)
        let p = SessionRadar.present([real], now: now, homeFolderName: home)
        #expect(p.rows.map(\.session.id) == ["v"])
    }

    /// Several home-folder ghosts plus real sessions: only the real ones show, and the ghosts do
    /// not inflate `hiddenCount` (they are noise, not elided recent sessions).
    @Test func multipleGhostsDoNotCountAsHidden() {
        let ghosts = (0..<4).map { session("g\($0)", .done, ageSec: 20, project: home, event: .sessionEnd) }
        let real1 = session("a", .done, ageSec: 10, project: "VibeMenu", title: "Greeting")
        let real2 = session("b", .working, project: "VibeMenu")
        let p = SessionRadar.present(ghosts + [real1, real2], now: now, homeFolderName: home)
        #expect(Set(p.rows.map(\.session.id)) == ["a", "b"])
        #expect(p.hiddenCount == 0)
    }

    // MARK: - Expandable overflow (the "more recent sessions ▸" control)

    @Test func overflowCapConstantMatchesSpec() {
        #expect(SessionRadar.maxOverflowRows == 10)
    }

    /// With no elided sessions there is nothing to expand.
    @Test func noOverflowWhenNothingHidden() {
        let sessions = (0..<3).map { session("w\($0)", .working, project: "p\($0)") }
        let p = SessionRadar.present(sessions, now: now)
        #expect(p.rows.count == 3)
        #expect(p.hiddenCount == 0)
        #expect(p.overflowRows.isEmpty)
        #expect(p.olderHiddenCount == 0)
    }

    /// Primary rows stay capped at 4; the elided sessions become the (bounded) overflow rows, and
    /// primary + overflow are disjoint and together account for every eligible session.
    @Test func overflowRevealsHiddenBelowPrimary() {
        let sessions = (0..<8).map { session("w\($0)", .working, project: "p\($0)") }
        let p = SessionRadar.present(sessions, now: now)
        #expect(p.rows.count == 4)
        #expect(p.hiddenCount == 4)
        #expect(p.overflowRows.count == 4)
        #expect(p.olderHiddenCount == 0)
        let primaryIDs = Set(p.rows.map(\.session.id))
        let overflowIDs = Set(p.overflowRows.map(\.session.id))
        #expect(primaryIDs.isDisjoint(with: overflowIDs))
        #expect(primaryIDs.union(overflowIDs).count == 8)   // all eligible are shown across both
    }

    /// The expanded list is itself capped at `maxOverflowRows`; anything past that is reported as
    /// `olderHiddenCount` and never rendered as a row.
    @Test func overflowRowsCappedAtTenWithOlderRemainder() {
        // 4 primary + 13 more eligible = 17 working sessions; 13 hidden, 10 revealed, 3 older.
        let sessions = (0..<17).map { session("w\($0)", .working, project: "p\($0)") }
        let p = SessionRadar.present(sessions, now: now)
        #expect(p.rows.count == 4)
        #expect(p.hiddenCount == 13)
        #expect(p.overflowRows.count == SessionRadar.maxOverflowRows)   // 10
        #expect(p.olderHiddenCount == 3)                               // 13 - 10
    }

    /// Overflow draws only from eligible sessions: unknown, expired done/stale, and home-folder
    /// ghosts never leak into the expanded rows (nor inflate the older-hidden count).
    @Test func overflowExcludesIneligibleSessions() {
        let working = (0..<6).map { session("w\($0)", .working, project: "p\($0)") }  // 4 shown, 2 overflow
        let unknown = session("u", .unknown, project: "U")
        let oldDone = session("od", .done, ageSec: 5 * 60 + 1, project: "OD")
        let oldStale = session("os", .stale, ageSec: 2 * 60 + 1, project: "OS")
        let ghost = session("g", .done, ageSec: 20, project: home, event: .sessionEnd)
        let p = SessionRadar.present(
            working + [unknown, oldDone, oldStale, ghost], now: now, homeFolderName: home
        )
        #expect(p.rows.count == 4)
        #expect(p.overflowRows.map(\.session.id) == ["w4", "w5"])   // only the eligible overflow sessions
        #expect(p.hiddenCount == 2)
        #expect(p.olderHiddenCount == 0)
    }

    /// Done sessions elided by the visible cap (but still fresh/eligible) are what the overflow
    /// reveals — the expand control surfaces exactly the "+N more recent sessions" the collapsed
    /// label counts.
    @Test func overflowIncludesDoneBeyondTheVisibleCap() {
        let done = (0..<6).map { session("d\($0)", .done, ageSec: 10, project: "p\($0)") }
        let p = SessionRadar.present(done, now: now)
        #expect(p.rows.count == 4)                            // fills the primary list
        #expect(p.hiddenCount == 2)
        #expect(p.overflowRows.count == 2)                    // the two elided fresh-done sessions
        #expect(p.olderHiddenCount == 0)
    }
}

// MARK: - Aggregate keep-awake equivalence (the drift guard)

/// The radar's aggregate keep-awake intent must equal the wired `automationIntent` on the
/// same inputs, so the display and the power decision never diverge. This is the core
/// correctness invariant of the Session Radar design (docs/decisions/0011): the per-session
/// states are defined precisely so that `any(session.holdsSleepPrevention)` reproduces the
/// proven automation decision.
@Suite("sessionsKeepAwakeIntent == automationIntent")
struct SessionAggregateEquivalenceTests {
    private let now = Date(timeIntervalSince1970: 4_500_000)

    private func rec(
        _ event: ClaudeHeartbeatEvent, age: TimeInterval, session: String = "s1"
    ) -> ClaudeHeartbeatRecord {
        ClaudeHeartbeatRecord(sessionID: session, event: event, updatedAt: now.addingTimeInterval(-age))
    }

    /// Assert the radar aggregate matches the wired automation intent for one input.
    private func check(_ records: [ClaudeHeartbeatRecord], process: Bool, _ label: String) {
        var store = ClaudeSessionStore()
        store.update(records: records, processPresent: process, now: now)
        let radar = sessionsKeepAwakeIntent(store.sessions)
        let wired = ClaudeActivityState.automationIntent(
            heartbeats: records,
            signals: ClaudeActivitySignals(processPresent: process, mostRecentSessionActivity: nil),
            now: now
        )
        #expect(radar == wired, "\(label): radar=\(radar) wired=\(wired)")
    }

    @Test func matchesAcrossSingleSessionTimelines() {
        check([rec(.userPromptSubmit, age: 1)], process: true, "fresh active")
        check([rec(.preToolUse, age: 300)], process: true, "aged active within cap")
        check([rec(.preToolUse, age: 900)], process: true, "active at cap boundary")
        check([rec(.preToolUse, age: 901)], process: true, "active just past cap")
        check([rec(.preToolUse, age: 1800)], process: true, "active at prune boundary")
        check([rec(.preToolUse, age: 1801)], process: true, "active past prune")
        check([rec(.stop, age: 1)], process: true, "stop")
        check([rec(.notification, age: 1)], process: true, "notification")
        check([rec(.sessionStart, age: 1)], process: true, "session start")
        check([rec(.sessionEnd, age: 1)], process: true, "session end")
        check([rec(.subagentStop, age: 2)], process: true, "fresh subagent stop")
        check([rec(.subagentStop, age: 901)], process: true, "aged subagent stop")
        check([rec(.unknown, age: 2)], process: true, "fresh unknown")
        check([rec(.unknown, age: 901)], process: true, "aged unknown")
        check([rec(.preToolUse, age: 1)], process: false, "fresh active, no process")
        check([rec(.preToolUse, age: 300)], process: false, "aged active, no process")
        check([rec(.stop, age: 1)], process: false, "stop, no process")
    }

    @Test func matchesAcrossMultiSessionTimelines() {
        check([rec(.stop, age: 1, session: "a"), rec(.preToolUse, age: 1, session: "b")],
              process: true, "one done one working ⇒ hold")
        check([rec(.stop, age: 1, session: "a"), rec(.notification, age: 1, session: "b")],
              process: true, "two done ⇒ release")
        check([rec(.sessionEnd, age: 1, session: "a"), rec(.subagentStop, age: 2, session: "b")],
              process: true, "ended + working subagent ⇒ hold")
        check([rec(.preToolUse, age: 30, session: "a"), rec(.stop, age: 1, session: "a")],
              process: true, "dedup newest stop ⇒ release")
        check([rec(.preToolUse, age: 300, session: "a"), rec(.stop, age: 1, session: "b")],
              process: true, "quiet-working + finished ⇒ hold")
        check([rec(.preToolUse, age: 1, session: "a"), rec(.preToolUse, age: 1, session: "b")],
              process: false, "two active, no process ⇒ release")
    }
}
