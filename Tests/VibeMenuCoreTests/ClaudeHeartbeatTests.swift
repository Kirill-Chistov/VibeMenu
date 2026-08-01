import Foundation
import Testing
@testable import VibeMenuCore

// L2 hook-heartbeat detection tests (docs/decisions/0008). Two layers are exercised with no
// dependency on a live `claude` process or real `~/.claude`:
//   * the pure aggregate decision `ClaudeActivityState.evaluate(heartbeats:signals:...)`
//     and its `diagnostics(...)` companion, over synthetic records;
//   * the malformed-safe reader `ClaudeActivityProvider.readHeartbeatRecords(in:)` over a
//     temp directory;
//   * the production hook script, run as a subprocess against a temp state dir, to prove
//     it writes only the allowed fields and ignores sensitive payload fields.

// MARK: - Event mapping & classification

@Suite("ClaudeHeartbeatEvent")
struct ClaudeHeartbeatEventTests {
    @Test func mapsRawHookNames() {
        #expect(ClaudeHeartbeatEvent(hookEventName: "SessionStart") == .sessionStart)
        #expect(ClaudeHeartbeatEvent(hookEventName: "UserPromptSubmit") == .userPromptSubmit)
        #expect(ClaudeHeartbeatEvent(hookEventName: "PreToolUse") == .preToolUse)
        #expect(ClaudeHeartbeatEvent(hookEventName: "PostToolUse") == .postToolUse)
        #expect(ClaudeHeartbeatEvent(hookEventName: "SubagentStart") == .subagentStart)
        #expect(ClaudeHeartbeatEvent(hookEventName: "SubagentStop") == .subagentStop)
        #expect(ClaudeHeartbeatEvent(hookEventName: "Notification") == .notification)
        #expect(ClaudeHeartbeatEvent(hookEventName: "PermissionRequest") == .permissionRequested)
        #expect(ClaudeHeartbeatEvent(hookEventName: "Stop") == .stop)
        #expect(ClaudeHeartbeatEvent(hookEventName: "StopFailure") == .stopFailure)
        #expect(ClaudeHeartbeatEvent(hookEventName: "SessionEnd") == .sessionEnd)
    }

    @Test func unrecognisedNameIsUnknown() {
        #expect(ClaudeHeartbeatEvent(hookEventName: "SomeFutureEvent") == .unknown)
        #expect(ClaudeHeartbeatEvent(hookEventName: "") == .unknown)
    }

    @Test func classificationHelpers() {
        for e in [ClaudeHeartbeatEvent.userPromptSubmit, .preToolUse, .postToolUse, .subagentStart] {
            #expect(e.isActiveEvent)
            #expect(!e.isWaitingEvent)
        }
        // `stopFailure` (turn ended on an API error) is a finish, exactly like `stop`.
        for e in [ClaudeHeartbeatEvent.stop, .stopFailure, .notification] {
            #expect(e.isWaitingEvent)
            #expect(!e.isActiveEvent)
        }
        // A pending approval is not "active work" — Claude is blocked on the user.
        #expect(!ClaudeHeartbeatEvent.permissionRequested.isActiveEvent)
        #expect(ClaudeHeartbeatEvent.sessionEnd.isSessionEnd)
        #expect(!ClaudeHeartbeatEvent.stop.isSessionEnd)
        // A StopFailure ends the *turn*, not the *session* — the user can retry, so it is a
        // finish but not a session end (unlike SessionEnd).
        #expect(!ClaudeHeartbeatEvent.stopFailure.isSessionEnd)
    }

    /// The automation "work in progress" classification is deliberately *broader* than
    /// `isActiveEvent` (docs/decisions/0010): subagent lifecycle events *and* unknown/future
    /// events keep sleep prevention held so a silent gap never causes a false release, while
    /// the genuinely-finished / waiting-for-user events do not.
    @Test func indicatesWorkInProgressClassification() {
        for e in [ClaudeHeartbeatEvent.userPromptSubmit, .preToolUse, .postToolUse,
                  .subagentStart, .subagentStop, .unknown] {
            #expect(e.indicatesWorkInProgress, "\(e) should hold")
        }
        // `stopFailure` must NOT hold — the turn already ended (on an API error), so there is no
        // work in flight; it releases the assertion exactly like `stop` (docs/decisions/0019).
        for e in [ClaudeHeartbeatEvent.stop, .stopFailure, .notification, .sessionStart, .permissionRequested] {
            #expect(!e.indicatesWorkInProgress, "\(e) should not hold")
        }
    }

    /// Only the bare session-lifecycle events (`SessionStart`/`SessionEnd`) are "lifecycle only" —
    /// the signal the radar uses to spot the desktop app's throwaway home-directory launches. Every
    /// work event and the finish/attention events did *something* and are not lifecycle-only.
    @Test func isLifecycleOnlyClassification() {
        for e in [ClaudeHeartbeatEvent.sessionStart, .sessionEnd] {
            #expect(e.isLifecycleOnly, "\(e) should be lifecycle-only")
        }
        for e in [ClaudeHeartbeatEvent.userPromptSubmit, .preToolUse, .postToolUse,
                  .subagentStart, .subagentStop, .stop, .stopFailure, .notification,
                  .permissionRequested, .unknown] {
            #expect(!e.isLifecycleOnly, "\(e) should not be lifecycle-only")
        }
    }
}

// MARK: - Pure L2 aggregate decision

@Suite("ClaudeActivityState.evaluate(heartbeats:)")
struct ClaudeHeartbeatEvaluateTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func rec(
        _ event: ClaudeHeartbeatEvent, age: TimeInterval, session: String = "s1"
    ) -> ClaudeHeartbeatRecord {
        ClaudeHeartbeatRecord(sessionID: session, event: event, updatedAt: now.addingTimeInterval(-age))
    }

    private func evaluate(
        _ records: [ClaudeHeartbeatRecord], process: Bool = true, mtime: Date? = nil
    ) -> ClaudeActivityState {
        ClaudeActivityState.evaluate(
            heartbeats: records,
            signals: ClaudeActivitySignals(processPresent: process, mostRecentSessionActivity: mtime),
            now: now
        )
    }

    /// 1. A recent `UserPromptSubmit` heartbeat (process present) ⇒ `.active`.
    @Test func userPromptSubmitIsActive() {
        #expect(evaluate([rec(.userPromptSubmit, age: 2)]) == .active)
    }

    /// 2. A recent `PreToolUse` heartbeat ⇒ `.active`.
    @Test func preToolUseIsActive() {
        #expect(evaluate([rec(.preToolUse, age: 2)]) == .active)
    }

    /// 3. A recent `PostToolUse` heartbeat ⇒ `.active`.
    @Test func postToolUseIsActive() {
        #expect(evaluate([rec(.postToolUse, age: 2)]) == .active)
    }

    /// 4. A recent `Stop` heartbeat ⇒ `.waiting` (Claude finished, awaiting input).
    @Test func stopIsWaiting() {
        #expect(evaluate([rec(.stop, age: 2)]) == .waiting)
    }

    /// 4b. A recent `StopFailure` heartbeat ⇒ `.waiting` — the turn ended on an API error, so
    ///     Claude is stopped and the user is the one to act (same display verdict as `Stop`, and
    ///     never `.active`).
    @Test func stopFailureIsWaiting() {
        let state = evaluate([rec(.stopFailure, age: 2)])
        #expect(state == .waiting)
        #expect(state != .active)
    }

    /// 5. A recent `Notification` heartbeat ⇒ `.waiting`.
    @Test func notificationIsWaiting() {
        #expect(evaluate([rec(.notification, age: 2)]) == .waiting)
    }

    /// `SessionStart` / unknown events are "live but not working" ⇒ `.waiting`.
    @Test func sessionStartAndUnknownAreWaiting() {
        #expect(evaluate([rec(.sessionStart, age: 2)]) == .waiting)
        #expect(evaluate([rec(.unknown, age: 2)]) == .waiting)
    }

    /// 6. `SessionEnd` is excluded for that session. A lone `SessionEnd` with no process
    ///    and no session files ⇒ L1 fallback ⇒ `.notDetected`.
    @Test func sessionEndAloneFallsBackToNotDetected() {
        #expect(evaluate([rec(.sessionEnd, age: 2)], process: false, mtime: nil) == .notDetected)
    }

    /// 6b. A `SessionEnd` for one session does not suppress an active *other* session.
    @Test func sessionEndDoesNotHideOtherActiveSession() {
        let records = [rec(.sessionEnd, age: 2, session: "ended"),
                       rec(.preToolUse, age: 2, session: "live")]
        #expect(evaluate(records) == .active)
    }

    /// 7. Multiple sessions: any active session wins over a waiting one.
    @Test func anyActiveSessionWins() {
        let records = [rec(.stop, age: 2, session: "s1"),
                       rec(.preToolUse, age: 2, session: "s2")]
        #expect(evaluate(records) == .active)
    }

    /// 8. Multiple sessions: with no active session, a waiting session wins (over nothing).
    @Test func waitingWinsWhenNoActive() {
        let records = [rec(.stop, age: 2, session: "s1"),
                       rec(.notification, age: 2, session: "s2")]
        #expect(evaluate(records) == .waiting)
    }

    /// 9. A stale active heartbeat must not keep `.active` forever. Past the stale window
    ///    the record is dropped entirely ⇒ L1 fallback (process present, no files) ⇒
    ///    `.running`, definitely not `.active`.
    @Test func staleActiveDoesNotStayActive() {
        let dropped = evaluate([rec(.preToolUse, age: 700)])   // > 600s stale window
        #expect(dropped != .active)
        #expect(dropped == .running)

        // Between the active window (120s) and the stale window: downgraded to `.waiting`.
        let aged = evaluate([rec(.preToolUse, age: 200)])
        #expect(aged != .active)
        #expect(aged == .waiting)
    }

    /// 10. No heartbeat records ⇒ fall back to L1 process/mtime logic exactly.
    @Test func noHeartbeatFallsBackToL1() {
        #expect(evaluate([], process: true, mtime: now.addingTimeInterval(-3)) == .active)  // L1 active
        #expect(evaluate([], process: true, mtime: nil) == .running)                        // L1 running
        #expect(evaluate([], process: false, mtime: nil) == .notDetected)                   // L1 notDetected
        #expect(evaluate([], process: false, mtime: now.addingTimeInterval(-3)) == .idle)   // L1 idle
    }

    /// 11. An active heartbeat with **no visible process** must not report `.active`. A
    ///     fresh one is reported as `.waiting`; an aged one falls back to L1 (no process,
    ///     no files ⇒ `.notDetected`) rather than lingering.
    @Test func activeHeartbeatWithNoProcessDoesNotStayActive() {
        let fresh = evaluate([rec(.preToolUse, age: 2)], process: false)
        #expect(fresh != .active)
        #expect(fresh == .waiting)

        let aged = evaluate([rec(.preToolUse, age: 200)], process: false)  // past active window
        #expect(aged != .active)
        #expect(aged == .notDetected)
    }

    /// Dedup: the newest record per session wins, so an older active event cannot override
    /// a newer `Stop` from the same session.
    @Test func newestRecordPerSessionWins() {
        let records = [rec(.preToolUse, age: 30, session: "s1"),
                       rec(.stop, age: 2, session: "s1")]
        #expect(evaluate(records) == .waiting)
    }
}

// MARK: - Pure keep-awake automation decision (v0.1.1, docs/decisions/0010)

/// The core of the v0.1.1 automation-reliability fix: `automationIntent` must **hold**
/// through a long silent tool/subagent phase (up to the bounded cap) and **release**
/// promptly on a genuine finish — without collapsing "aged active heartbeat" and "finished"
/// into one bucket. Pure and re-run each tick, so the cap is enforced by re-evaluation.
@Suite("ClaudeActivityState.automationIntent")
struct ClaudeAutomationIntentTests {
    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func rec(
        _ event: ClaudeHeartbeatEvent, age: TimeInterval, session: String = "s1"
    ) -> ClaudeHeartbeatRecord {
        ClaudeHeartbeatRecord(sessionID: session, event: event, updatedAt: now.addingTimeInterval(-age))
    }

    private func intent(
        _ records: [ClaudeHeartbeatRecord], process: Bool = true
    ) -> ClaudeAutomationIntent {
        ClaudeActivityState.automationIntent(
            heartbeats: records,
            signals: ClaudeActivitySignals(processPresent: process, mostRecentSessionActivity: nil),
            now: now
        )
    }

    /// The cap is pinned so a change to it is a deliberate, visible edit (15 minutes).
    @Test func defaultQuietHoldCapIsFifteenMinutes() {
        #expect(ClaudeActivityState.defaultQuietHoldCap == 15 * 60)
    }

    /// L1 signals with `~/.claude` metadata of a given age (`nil` = no session files seen).
    private func l1(process: Bool = true, metadataAge: TimeInterval?) -> ClaudeActivitySignals {
        ClaudeActivitySignals(
            processPresent: process,
            mostRecentSessionActivity: metadataAge.map { now.addingTimeInterval(-$0) }
        )
    }

    /// Convenience: automation intent over heartbeat records *and* L1 signals.
    private func intent(
        _ records: [ClaudeHeartbeatRecord], process: Bool = true, metadataAge: TimeInterval?
    ) -> ClaudeAutomationIntent {
        ClaudeActivityState.automationIntent(
            heartbeats: records, signals: l1(process: process, metadataAge: metadataAge), now: now
        )
    }

    /// **L1 fallback (0010 amendment, 2026-07-26).** With no *recent* heartbeat record — the hook was
    /// never installed, or its script was moved/deleted so every invocation fails silently —
    /// automatic keep-awake degrades to coarse L1 instead of releasing outright: a visible `claude`
    /// process plus `~/.claude` metadata inside the existing L1 recency window holds.
    @Test func noHeartbeatsWithFreshL1MetadataHolds() {
        #expect(intent([], metadataAge: 1) == .hold)
        // …and it is exactly the L1 display's own `.active` rule, not a second duration.
        #expect(ClaudeActivityState.evaluate(
            heartbeats: [], signals: l1(metadataAge: 1), now: now
        ) == .active)
    }

    /// **The correction (2026-07-27).** The fallback trigger is *staleness*, not an empty file list:
    /// leftover heartbeat files from an uninstalled or broken hook must stop suppressing it once they
    /// age past the stale window. Before this, one forgotten file disabled the fallback forever.
    @Test func staleLeftoverWorkFilesDoNotSuppressTheFallback() {
        // A work event past the quiet-hold cap no longer holds on its own…
        #expect(intent([rec(.preToolUse, age: 901)], metadataAge: nil) == .release)
        // …and, being stale, it also stops gating the fallback: fresh L1 now holds.
        #expect(intent([rec(.preToolUse, age: 901)], metadataAge: 1) == .hold)
        #expect(intent([rec(.preToolUse, age: 3600)], metadataAge: 1) == .hold)
        #expect(intent([rec(.unknown, age: 3600)], metadataAge: 1) == .hold)
    }

    /// The same for leftover *finish* files — the shape a hook that stopped firing actually leaves
    /// behind (its last write was usually a `Stop`/`SessionEnd`). Past the stale window they are no
    /// longer an authoritative signal about anything.
    @Test func staleLeftoverFinishFilesDoNotSuppressTheFallback() {
        #expect(ClaudeActivityState.defaultHeartbeatStaleThreshold == 600)
        for finished: ClaudeHeartbeatEvent in [.stop, .stopFailure, .sessionEnd, .notification,
                                               .permissionRequested, .sessionStart] {
            #expect(intent([rec(finished, age: 601)], metadataAge: 1) == .hold,
                    "stale \(finished) must not suppress the L1 fallback")
            #expect(intent([rec(finished, age: 601)], metadataAge: 30) == .release,
                    "stale \(finished) + stale L1 ⇒ release")
        }
    }

    /// The fallback gets **no** quiet-hold extension: L1 cannot tell silent work from a finished turn
    /// (docs/decisions/0008), so a hold lapses as soon as the metadata leaves the 10s L1 window —
    /// well inside the 15-minute heartbeat cap, which stays hook-only. (Continuous L1 activity still
    /// holds continuously: each tick re-reads the metadata, so the window rolls forward.)
    @Test func noHeartbeatsWithStaleL1MetadataReleases() {
        #expect(ClaudeActivityState.defaultRecencyThreshold == 10)
        #expect(intent([], metadataAge: 10) == .hold)     // exactly at the window: still held
        #expect(intent([], metadataAge: 11) == .release)  // just past it: released
        #expect(intent([], metadataAge: 120) == .release) // no quiet-work grace…
        #expect(intent([], metadataAge: 600) == .release) // …and no cap-length hold.
        // A live process with no session files at all is `.running`, never a hold.
        #expect(intent([], metadataAge: nil) == .release)
    }

    /// The process cross-check still comes first, on every path: fresh metadata (with or without
    /// heartbeat records, fresh or stale) never holds without a visible `claude` process.
    @Test func processAbsentAlwaysReleases() {
        #expect(intent([], process: false, metadataAge: 1) == .release)
        #expect(intent([], process: false, metadataAge: nil) == .release)
        #expect(intent([rec(.preToolUse, age: 1)], process: false, metadataAge: 1) == .release)
        #expect(intent([rec(.preToolUse, age: 3600)], process: false, metadataAge: 1) == .release)
        #expect(intent([rec(.stop, age: 601)], process: false, metadataAge: 1) == .release)
    }

    /// Heartbeat semantics keep deciding alone whenever a **recent** record exists: an explicit
    /// `Stop` releases promptly even though the finished turn's own transcript write leaves L1
    /// metadata fresh. Without this, fresh L1 would resurrect every finished turn.
    @Test func freshFinishEventsStayAuthoritativeOverFreshL1() {
        for finished: ClaudeHeartbeatEvent in [.stop, .stopFailure, .sessionEnd, .notification,
                                               .permissionRequested, .sessionStart] {
            #expect(intent([rec(finished, age: 1)], metadataAge: 1) == .release,
                    "fresh \(finished) must release even with fresh L1 metadata")
            // Still authoritative right up to the stale boundary.
            #expect(intent([rec(finished, age: 600)], metadataAge: 1) == .release,
                    "\(finished) at the stale boundary is still authoritative")
        }
    }

    /// …and conversely, a heartbeat work event keeps its full bounded quiet-hold regardless of how
    /// stale L1 metadata is — the fallback neither shortens nor extends the 15-minute cap. The
    /// 600–900s band matters most: past the display-stale window, still inside the cap, so it must
    /// hold at step 3 and never reach the staleness question.
    @Test func heartbeatWorkEventKeepsBoundedQuietHoldRegardlessOfL1() {
        func withStaleL1(age: TimeInterval) -> ClaudeAutomationIntent {
            intent([rec(.preToolUse, age: age)], metadataAge: 3600)
        }
        #expect(withStaleL1(age: 300) == .hold)   // quiet work, far past the L1 window
        #expect(withStaleL1(age: 601) == .hold)   // past the 600s stale window…
        #expect(withStaleL1(age: 899) == .hold)   // …still inside the 900s cap ⇒ holds
        #expect(withStaleL1(age: 900) == .hold)   // at the cap
        #expect(withStaleL1(age: 901) == .release)  // past the cap, with stale L1 ⇒ release
    }

    /// Multi-session: a single **fresh** finish event keeps the whole decision heartbeat-authoritative
    /// — stale siblings must not open the fallback while the hook is demonstrably still firing.
    @Test func oneFreshFinishEventSuppressesTheFallbackAcrossSessions() {
        let records = [rec(.preToolUse, age: 3600, session: "abandoned"),
                       rec(.stop, age: 5, session: "finished")]
        #expect(intent(records, metadataAge: 1) == .release)
        // With *every* session stale, the fallback opens again.
        let allStale = [rec(.preToolUse, age: 3600, session: "abandoned"),
                        rec(.stop, age: 3600, session: "finished")]
        #expect(intent(allStale, metadataAge: 1) == .hold)
    }

    /// Multi-session: one work event inside the quiet cap still holds globally, whatever the other
    /// sessions or L1 say (rule 5 — a finished session never forces a global release).
    @Test func oneWorkEventInsideTheCapStillHoldsAcrossSessions() {
        let records = [rec(.stop, age: 1, session: "finished"),
                       rec(.preToolUse, age: 700, session: "working")]
        #expect(intent(records, metadataAge: 1) == .hold)
        #expect(intent(records, metadataAge: 3600) == .hold)
        #expect(intent(records, metadataAge: nil) == .hold)
    }

    /// The L1 boundary is exact and inclusive at 10s — the one duration the fallback reuses.
    @Test func exactL1RecencyBoundary() {
        #expect(intent([], metadataAge: 9.999) == .hold)
        #expect(intent([], metadataAge: 10) == .hold)
        #expect(intent([], metadataAge: 10.001) == .release)
        // Same boundary when only stale leftovers exist.
        #expect(intent([rec(.stop, age: 3600)], metadataAge: 10) == .hold)
        #expect(intent([rec(.stop, age: 3600)], metadataAge: 10.001) == .release)
    }

    /// The Session Radar stays **heartbeat-only**: the L1 fallback may hold power, but it must never
    /// invent a row, because coarse L1 state carries no session id, title, or project
    /// (docs/decisions/0011). This is the one deliberate divergence from `sessionsKeepAwakeIntent`.
    @Test func l1FallbackHoldsPowerButNeverCreatesARadarRow() {
        #expect(intent([], metadataAge: 1) == .hold)

        var store = ClaudeSessionStore()
        store.update(records: [], processPresent: true, now: now)
        #expect(store.sessions.isEmpty)
        #expect(store.keepAwakeIntent == .release)

        // Same during a fallback hold caused by *stale leftovers*: the records are past the radar's
        // own prune horizon, so no row survives and nothing is fabricated to replace them.
        let leftovers = [rec(.stop, age: 3600, session: "old")]
        #expect(intent(leftovers, metadataAge: 1) == .hold)
        var leftoverStore = ClaudeSessionStore()
        leftoverStore.update(records: leftovers, processPresent: true, now: now)
        #expect(leftoverStore.sessions.isEmpty)
        #expect(leftoverStore.keepAwakeIntent == .release)
    }

    /// 1. An active event immediately holds the assertion.
    @Test func activeEventImmediatelyHolds() {
        #expect(intent([rec(.userPromptSubmit, age: 1)]) == .hold)
        #expect(intent([rec(.preToolUse, age: 1)]) == .hold)
        #expect(intent([rec(.postToolUse, age: 1)]) == .hold)
    }

    /// 2. An active event that has aged **past the 120s display window** but is still within
    ///    the cap, with the process present and no finish signal, keeps holding — the exact
    ///    silent-gap case v0.1.1 fixes (the display would read Idle here).
    @Test func agedActiveWithinCapStillHolds() {
        // 300s: well past the 120s display-active window, well within the 900s cap.
        #expect(intent([rec(.preToolUse, age: 300)]) == .hold)
        // And the display would indeed have fallen back to Waiting/Idle at this age:
        let display = ClaudeActivityState.evaluate(
            heartbeats: [rec(.preToolUse, age: 300)],
            signals: ClaudeActivitySignals(processPresent: true, mostRecentSessionActivity: nil),
            now: now
        )
        #expect(display == .waiting)          // display says "Idle-ish"…
        #expect(intent([rec(.preToolUse, age: 300)]) == .hold)   // …but automation still holds.
    }

    /// 3. Past the 15-minute cap with no new active event, automation releases (hung/stale
    ///    session cannot keep the Mac awake forever). Boundary: exactly at the cap holds.
    @Test func quietHoldReleasesAfterCap() {
        #expect(intent([rec(.preToolUse, age: 15 * 60)]) == .hold)        // exactly at cap ⇒ hold
        #expect(intent([rec(.preToolUse, age: 15 * 60 + 1)]) == .release) // just past cap ⇒ release
    }

    /// 4. A new active event during a quiet hold refreshes the cap (cancels the pending
    ///    release): the newest record per session wins, so its fresh age is what the cap is
    ///    measured against — an about-to-expire session is pulled back to holding.
    @Test func activeEventDuringQuietHoldRefreshesCap() {
        // Older active event alone is about to expire but still holds…
        #expect(intent([rec(.preToolUse, age: 15 * 60 - 1)]) == .hold)
        // …and a newer active event for the same session resets the clock (newest wins),
        // so even alongside an over-cap older record the session keeps holding.
        let refreshed = [rec(.preToolUse, age: 15 * 60 + 120, session: "s1"),
                         rec(.postToolUse, age: 2, session: "s1")]
        #expect(intent(refreshed) == .hold)
    }

    /// 5. `Stop` releases immediately (Claude finished the turn, awaiting input).
    @Test func stopReleasesImmediately() {
        #expect(intent([rec(.stop, age: 1)]) == .release)
    }

    /// 5b. `StopFailure` releases immediately — the turn ended (on an API error), so exactly like
    ///     `Stop` there is no work in flight to hold for. The keep-awake half of the
    ///     docs/decisions/0019 fix: an errored-out session must stop pinning the Mac awake, at any
    ///     age (age is irrelevant once the turn has ended — the bug was it holding until the cap).
    @Test func stopFailureReleasesImmediately() {
        #expect(intent([rec(.stopFailure, age: 1)]) == .release)
        #expect(intent([rec(.stopFailure, age: 300)]) == .release)
    }

    /// 5c. But a `StopFailure` never forces a *global* release: a still-working sibling session
    ///     keeps holding (parity with `Stop`; task rule 5 — any one working session wins).
    @Test func stopFailureDoesNotForceGlobalRelease() {
        let mixed = [rec(.stopFailure, age: 2, session: "errored"),
                     rec(.preToolUse, age: 2, session: "working")]
        #expect(intent(mixed) == .hold)
    }

    /// 6. `SessionEnd` releases immediately (session excluded; no other holding session).
    @Test func sessionEndReleasesImmediately() {
        #expect(intent([rec(.sessionEnd, age: 1)]) == .release)
    }

    /// 7. Process gone releases immediately even with a fresh active heartbeat (a heartbeat
    ///    is never proof of a live process — the cross-check that stops a crashed session
    ///    from pinning sleep prevention).
    @Test func processGoneReleasesImmediately() {
        #expect(intent([rec(.preToolUse, age: 1)], process: false) == .release)
        #expect(intent([rec(.postToolUse, age: 300)], process: false) == .release)
    }

    /// 8. `SubagentStart` counts as activity ⇒ holds.
    @Test func subagentStartHolds() {
        #expect(intent([rec(.subagentStart, age: 2)]) == .hold)
        #expect(intent([rec(.subagentStart, age: 300)]) == .hold)   // quiet hold within cap
    }

    /// 9. `SubagentStop` must **not** globally release — a subagent finished but the parent
    ///    turn keeps running, so it holds (within the cap) rather than dropping sleep
    ///    prevention.
    @Test func subagentStopDoesNotGloballyRelease() {
        #expect(intent([rec(.subagentStop, age: 2)]) == .hold)
        #expect(intent([rec(.subagentStop, age: 300)]) == .hold)
        // Even when a *sibling* session reports Stop, the still-working subagent holds.
        let mixed = [rec(.stop, age: 2, session: "finished"),
                     rec(.subagentStop, age: 2, session: "working")]
        #expect(intent(mixed) == .hold)
    }

    /// 10. Any one holding session wins: a finished (Stop) session never forces a global
    ///     release while another session is actively working.
    @Test func anyHoldingSessionWins() {
        let records = [rec(.stop, age: 1, session: "s1"),
                       rec(.preToolUse, age: 1, session: "s2")]
        #expect(intent(records) == .hold)
    }

    /// 11. `Notification` is classified conservatively as **waiting for the user**, not work
    ///     (task rule 6): a permission/idle/attention prompt lets the Mac sleep (SPEC §5.1);
    ///     manual keep-awake still covers "hold while I'm away". Documented in ADR-0010/FAQ.
    @Test func notificationReleases() {
        #expect(intent([rec(.notification, age: 1)]) == .release)
    }

    /// 12. An **unknown / future** event holds within the cap so an unrecognised (e.g.
    ///     future subagent) event can never cause a false release (task rule 5), while the
    ///     cap still bounds it.
    @Test func unknownEventHoldsWithinCapThenReleases() {
        #expect(intent([rec(.unknown, age: 2)]) == .hold)
        #expect(intent([rec(.unknown, age: 15 * 60 + 1)]) == .release)
    }

    /// 13. `SessionStart` (started, no prompt yet) is not work ⇒ release.
    @Test func sessionStartReleases() {
        #expect(intent([rec(.sessionStart, age: 1)]) == .release)
    }

    /// 14. No heartbeats + no process ⇒ release. No heartbeats + process present but **no L1
    ///     activity metadata at all** ⇒ release: bare process presence never auto-holds, and the
    ///     0010-amendment L1 fallback needs fresh `~/.claude` metadata too (see the fallback tests
    ///     at the top of this suite, which supply it). Same for the stale-leftover path — a record
    ///     list that is merely *old* releases here for want of L1 metadata, not for want of files.
    @Test func noHeartbeatsReleases() {
        #expect(intent([], process: false) == .release)
        #expect(intent([], process: true) == .release)
    }

    /// 15. A future timestamp (clock skew) counts as fresh, not expired ⇒ holds.
    @Test func futureTimestampHolds() {
        #expect(intent([rec(.preToolUse, age: -60)]) == .hold)
    }

    /// 16. The L2 **display** "stale" window (600s) must **not** shorten the automation
    ///     hold: an active heartbeat aged 700s (past the display-stale window, still within
    ///     the 900s cap) keeps holding — the cap, not the stale window, is the automation
    ///     bound. This guards against reintroducing a 10-minute effective cap.
    @Test func displayStaleWindowDoesNotShortenTheHold() {
        #expect(intent([rec(.preToolUse, age: 700)]) == .hold)     // past 600s stale, within 900s cap
        // For comparison, the display would already have dropped this record as stale:
        let display = ClaudeActivityState.evaluate(
            heartbeats: [rec(.preToolUse, age: 700)],
            signals: ClaudeActivitySignals(processPresent: true, mostRecentSessionActivity: nil),
            now: now
        )
        #expect(display == .running)    // heartbeat ignored (stale) ⇒ L1 (process, no files)
    }
}

// MARK: - Decoder & reader (malformed-safe)

@Suite("ClaudeHeartbeat decode & read")
struct ClaudeHeartbeatDecodeTests {
    /// 14a. A well-formed heartbeat file decodes; the raw hook name maps to the event.
    @Test func decodesWellFormedRecord() throws {
        let json = #"{"schemaVersion":1,"updatedAt":1783033591,"event":"PreToolUse","sessionID":"abc"}"#
        let record = try #require(ClaudeHeartbeatRecord.decode(from: Data(json.utf8)))
        #expect(record.sessionID == "abc")
        #expect(record.event == .preToolUse)
        #expect(record.updatedAt == Date(timeIntervalSince1970: 1783033591))
        #expect(record.project == nil)   // schema-1 file has no project field
    }

    /// 14a″. A `StopFailure` heartbeat file decodes to the **recognized** `.stopFailure` event
    /// (not `.unknown`) — the finish signal for a turn that ended on an API error
    /// (docs/decisions/0019). Guards the raw-name → case mapping through the on-disk shape.
    @Test func decodesStopFailureAsRecognizedEvent() throws {
        let json = #"{"schemaVersion":2,"updatedAt":1783033591,"event":"StopFailure","sessionID":"abc","project":"VibeMenu"}"#
        let record = try #require(ClaudeHeartbeatRecord.decode(from: Data(json.utf8)))
        #expect(record.event == .stopFailure)
        #expect(record.event != .unknown)
    }

    /// 14a′. A schema-2 file carries the project **folder name**; empty/whitespace/missing all
    /// normalise to `nil` (docs/decisions/0012-session-name-from-cwd.md).
    @Test func decodesProjectFolderName() throws {
        func project(_ json: String) -> String?? {
            ClaudeHeartbeatRecord.decode(from: Data(json.utf8)).map(\.project)
        }
        #expect(project(#"{"schemaVersion":2,"updatedAt":1,"event":"Stop","sessionID":"a","project":"VibeMenu"}"#) == "VibeMenu")
        // Folder names may contain spaces; leading/trailing whitespace is trimmed.
        #expect(project(#"{"schemaVersion":2,"updatedAt":1,"event":"Stop","sessionID":"a","project":"  My Cool Project  "}"#) == "My Cool Project")
        // Empty / whitespace-only / absent ⇒ nil ⇒ generic fallback name.
        #expect(project(#"{"schemaVersion":2,"updatedAt":1,"event":"Stop","sessionID":"a","project":""}"#) == .some(nil))
        #expect(project(#"{"schemaVersion":2,"updatedAt":1,"event":"Stop","sessionID":"a","project":"   "}"#) == .some(nil))
        #expect(project(#"{"schemaVersion":1,"updatedAt":1,"event":"Stop","sessionID":"a"}"#) == .some(nil))
    }

    /// 14b. Malformed / incomplete inputs decode to `nil` (never a crash).
    @Test func malformedInputsDecodeToNil() {
        #expect(ClaudeHeartbeatRecord.decode(from: Data("not json @@@".utf8)) == nil)
        #expect(ClaudeHeartbeatRecord.decode(from: Data("".utf8)) == nil)
        #expect(ClaudeHeartbeatRecord.decode(from: Data("{".utf8)) == nil)             // truncated
        // Missing required fields:
        #expect(ClaudeHeartbeatRecord.decode(from: Data(#"{"event":"Stop"}"#.utf8)) == nil)
        #expect(ClaudeHeartbeatRecord.decode(from: Data(#"{"updatedAt":1,"event":"Stop"}"#.utf8)) == nil)
        #expect(ClaudeHeartbeatRecord.decode(from: Data(#"{"updatedAt":1,"sessionID":"x"}"#.utf8)) == nil)
        #expect(ClaudeHeartbeatRecord.decode(from: Data(#"{"updatedAt":1,"event":"Stop","sessionID":""}"#.utf8)) == nil)
    }

    /// 14c. The reader skips malformed / non-JSON / non-`.json` files and returns only the
    ///      valid records — a bad file never breaks the read.
    @Test func readerIgnoresMalformedFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibemenu-hb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try #"{"schemaVersion":1,"updatedAt":1783033591,"event":"Stop","sessionID":"good"}"#
            .write(to: dir.appendingPathComponent("good.json"), atomically: true, encoding: .utf8)
        try "garbage not json".write(to: dir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let records = ClaudeActivityProvider.readHeartbeatRecords(in: dir)
        #expect(records.count == 1)
        #expect(records.first?.sessionID == "good")
        #expect(records.first?.event == .stop)
    }

    /// The reader returns an empty array (no crash) for a directory that doesn't exist —
    /// the "hook not installed yet" path that makes detection fall back to L1.
    @Test func readerReturnsEmptyForMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibemenu-hb-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(ClaudeActivityProvider.readHeartbeatRecords(in: missing).isEmpty)
    }

    /// End-to-end over the real reader: **sanitized** heartbeat fixtures written into a temp
    /// directory (never real runtime files), read through `readHeartbeatRecords`, and fed straight
    /// into `automationIntent`. This is what the provider does each tick, and it is the shape of the
    /// bug the 2026-07-27 correction fixes: a directory full of *leftover* files is not the same as
    /// a live hook, so it must not suppress the L1 fallback forever.
    @Test func leftoverFilesOnDiskDoNotSuppressTheL1Fallback() throws {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibemenu-hb-l1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        /// Write one heartbeat file in exactly the shape the hook script writes.
        func write(session: String, event: String, age: TimeInterval) throws {
            let updatedAt = now.addingTimeInterval(-age).timeIntervalSince1970
            let json = """
            {"schemaVersion":2,"updatedAt":\(Int(updatedAt)),"event":"\(event)",\
            "sessionID":"\(session)","project":"Fixture"}
            """
            try json.write(to: dir.appendingPathComponent("\(session).json"),
                           atomically: true, encoding: .utf8)
        }
        func intent(metadataAge: TimeInterval?) -> ClaudeAutomationIntent {
            ClaudeActivityState.automationIntent(
                heartbeats: ClaudeActivityProvider.readHeartbeatRecords(in: dir),
                signals: ClaudeActivitySignals(
                    processPresent: true,
                    mostRecentSessionActivity: metadataAge.map { now.addingTimeInterval(-$0) }
                ),
                now: now
            )
        }

        // Two long-forgotten leftovers: a work event past the cap and a finish past the stale
        // window. Both decode fine, so the old `heartbeats.isEmpty` trigger never fired.
        try write(session: "leftover-work", event: "PreToolUse", age: 4000)
        try write(session: "leftover-finish", event: "Stop", age: 3000)
        #expect(ClaudeActivityProvider.readHeartbeatRecords(in: dir).count == 2)
        #expect(intent(metadataAge: 1) == .hold)        // fallback now reachable ⇒ coarse hold
        #expect(intent(metadataAge: 60) == .release)    // stale L1 ⇒ release (no quiet extension)

        // A hook that starts firing again immediately takes back sole authority: its fresh `Stop`
        // releases despite the fresh L1 metadata the finished turn leaves behind.
        try write(session: "live", event: "Stop", age: 2)
        #expect(intent(metadataAge: 1) == .release)

        // …and a fresh work event from the live session holds again.
        try write(session: "live", event: "PostToolUse", age: 2)
        #expect(intent(metadataAge: 60) == .hold)
    }
}

// MARK: - L2 diagnostics (privacy-safe)

@Suite("ClaudeActivityDiagnostics (heartbeat)")
struct ClaudeHeartbeatDiagnosticsTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    /// 15. The DEBUG summary contains the heartbeat state, age, and session count — e.g.
    ///     `process=true, heartbeat=Active age=1s sessions=1, newestAge=none, threshold=10s,
    ///     result=Active` — and carries **no session id** and **no paths**.
    @Test func summaryContainsHeartbeatStateAndAgeButNoPathsOrIds() {
        let record = ClaudeHeartbeatRecord(
            sessionID: "SECRET-SESSION-ID-9999",
            event: .preToolUse,
            updatedAt: now.addingTimeInterval(-1)
        )
        let diag = ClaudeActivityState.diagnostics(
            heartbeats: [record],
            signals: ClaudeActivitySignals(processPresent: true, mostRecentSessionActivity: nil),
            now: now
        )
        #expect(diag.heartbeatState == .active)
        #expect(diag.heartbeatAgeSeconds == 1)
        #expect(diag.sessionCount == 1)
        #expect(diag.result == .active)

        let summary = diag.summary
        #expect(summary == "process=true, heartbeat=Active age=1s sessions=1, "
            + "newestAge=none, threshold=10s, result=Active")
        // No session id, no paths, no contents.
        #expect(!summary.contains("SECRET-SESSION-ID-9999"))
        #expect(!summary.contains("/"))
        #expect(!summary.lowercased().contains(".claude"))
        #expect(!summary.contains(".jsonl"))
    }

    /// The waiting case is legible too, with the correct session count across sessions.
    @Test func summaryShowsWaitingAndSessionCount() {
        let records = [
            ClaudeHeartbeatRecord(sessionID: "a", event: .stop, updatedAt: now.addingTimeInterval(-3)),
            ClaudeHeartbeatRecord(sessionID: "b", event: .notification, updatedAt: now.addingTimeInterval(-5))
        ]
        let diag = ClaudeActivityState.diagnostics(
            heartbeats: records,
            signals: ClaudeActivitySignals(processPresent: true, mostRecentSessionActivity: nil),
            now: now
        )
        #expect(diag.heartbeatState == .waiting)
        #expect(diag.sessionCount == 2)
        #expect(diag.heartbeatAgeSeconds == 3)   // newest of the two
        #expect(diag.summary.contains("heartbeat=Waiting age=3s sessions=2"))
        #expect(diag.summary.contains("result=Waiting"))
    }
}

// MARK: - Production hook script (subprocess)

/// Runs the real `Support/ClaudeHeartbeat/vibemenu-claude-hook.sh` against a temp state
/// directory to prove its privacy contract end-to-end.
@Suite("vibemenu-claude-hook.sh")
struct ClaudeHeartbeatScriptTests {
    /// Locate the script relative to this test file so the test is CWD-independent.
    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/VibeMenuCoreTests/ClaudeHeartbeatTests.swift
            .deletingLastPathComponent()          // .../Tests/VibeMenuCoreTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Support/ClaudeHeartbeat/vibemenu-claude-hook.sh")
    }

    /// Feed `stdin` to the hook script with `VIBEMENU_HEARTBEAT_DIR` pointed at `dir`;
    /// return the process exit code.
    @discardableResult
    private func run(stdin: String, dir: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.environment = [
            "VIBEMENU_HEARTBEAT_DIR": dir.path,
            "HOME": dir.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibemenu-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Read back only the safe heartbeat record fields through VibeMenu's parser.
    private func readRecord(session: String, dir: URL) throws -> ClaudeHeartbeatRecord {
        let data = try Data(contentsOf: dir.appendingPathComponent("\(session).json"))
        return try #require(ClaudeHeartbeatRecord.decode(from: data))
    }

    /// Run one sanitized synthetic hook event and return the resulting safe record.
    @discardableResult
    private func runEvent(
        _ event: String, session: String = "latch-session", dir: URL
    ) throws -> ClaudeHeartbeatRecord {
        let payload = "{\"session_id\":\"\(session)\",\"hook_event_name\":\"\(event)\"}"
        #expect(try run(stdin: payload, dir: dir) == 0)
        return try readRecord(session: session, dir: dir)
    }

    /// Exercise a completed turn through the real hook, then prove a late event remains a quiet
    /// no-op at the Session Radar, automation, timer, and notification layers.
    private func assertTrailingEventIsSuppressed(
        after finish: String, trailing: String
    ) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let initial = try runEvent("PreToolUse", dir: dir)
        var store = ClaudeSessionStore()
        store.update(records: [initial], processPresent: true, now: initial.updatedAt)
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude(store.sessions).isEmpty)

        let finished = try runEvent(finish, dir: dir)
        store.update(
            records: [finished], processPresent: true,
            now: finished.updatedAt.addingTimeInterval(1)
        )
        #expect(store.sessions[0].state == .done)
        #expect(!store.sessions[0].state.showsElapsedTimer)
        #expect(store.keepAwakeIntent == .release)
        #expect(tracker.updateClaude(store.sessions).count == 1)
        let completedTurnStart = store.sessions[0].startedAt

        let trailingRecord = try runEvent(trailing, dir: dir)
        // The latch leaves both safe generation fields untouched, including same-second events.
        #expect(trailingRecord.event == finished.event)
        #expect(trailingRecord.updatedAt == finished.updatedAt)

        store.update(
            records: [trailingRecord], processPresent: true,
            now: trailingRecord.updatedAt.addingTimeInterval(2)
        )
        #expect(store.sessions[0].state == .done)
        #expect(!store.sessions[0].state.showsElapsedTimer)
        #expect(store.sessions[0].startedAt == completedTurnStart)
        #expect(store.keepAwakeIntent == .release)
        #expect(ClaudeActivityState.automationIntent(
            heartbeats: [trailingRecord],
            signals: ClaudeActivitySignals(processPresent: true, mostRecentSessionActivity: nil),
            now: trailingRecord.updatedAt.addingTimeInterval(2)
        ) == .release)
        #expect(tracker.updateClaude(store.sessions).isEmpty)
    }

    /// Write a minimal safe heartbeat fixture with a deterministic timestamp, for the explicit
    /// same-second latch test. No transcript or hook payload data is involved.
    private func writeSafeRecord(
        event: String, updatedAt: TimeInterval, session: String, dir: URL
    ) throws {
        let data = Data(
            "{\"schemaVersion\":2,\"updatedAt\":\(updatedAt),\"event\":\"\(event)\",\"sessionID\":\"\(session)\",\"project\":\"\"}\n"
                .utf8
        )
        try data.write(to: dir.appendingPathComponent("\(session).json"), options: .atomic)
    }

    @Test("Stop -> PostToolUse remains Done with no timer, reacquire, or notification")
    func stopThenPostToolUseIsSuppressed() throws {
        try assertTrailingEventIsSuppressed(after: "Stop", trailing: "PostToolUse")
    }

    @Test("Stop -> SubagentStop remains Done with no timer, reacquire, or notification")
    func stopThenSubagentStopIsSuppressed() throws {
        try assertTrailingEventIsSuppressed(after: "Stop", trailing: "SubagentStop")
    }

    @Test("StopFailure -> trailing work remains Done")
    func stopFailureThenTrailingWorkIsSuppressed() throws {
        try assertTrailingEventIsSuppressed(after: "StopFailure", trailing: "PreToolUse")
    }

    @Test("Same-second trailing events preserve the completed generation")
    func sameSecondTrailingEventIsSuppressed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeSafeRecord(event: "Stop", updatedAt: 6_000_000, session: "same-second", dir: dir)
        let suppressed = try runEvent("SubagentStop", session: "same-second", dir: dir)
        #expect(suppressed.event == .stop)
        #expect(suppressed.updatedAt == Date(timeIntervalSince1970: 6_000_000))
    }

    @Test("Repeated Stop and StopFailure events are idempotent")
    func repeatedFinishesAreIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stop = try runEvent("Stop", session: "stop-session", dir: dir)
        let repeatedStop = try runEvent("Stop", session: "stop-session", dir: dir)
        let repeatedFailure = try runEvent("StopFailure", session: "stop-session", dir: dir)
        #expect(repeatedStop == stop)
        #expect(repeatedFailure == stop)

        let failure = try runEvent("StopFailure", session: "failure-session", dir: dir)
        let repeatedFailureOnly = try runEvent(
            "StopFailure", session: "failure-session", dir: dir
        )
        let repeatedStopAfterFailure = try runEvent(
            "Stop", session: "failure-session", dir: dir
        )
        #expect(repeatedFailureOnly == failure)
        #expect(repeatedStopAfterFailure == failure)
    }

    @Test("Stop -> UserPromptSubmit -> PreToolUse starts a new turn")
    func promptBoundaryBeginsNewTurn() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stop = try runEvent("Stop", dir: dir)
        var store = ClaudeSessionStore()
        store.update(records: [stop], processPresent: true, now: stop.updatedAt)
        #expect(store.sessions[0].state == .done)
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude(store.sessions).isEmpty)

        let prompt = try runEvent("UserPromptSubmit", dir: dir)
        store.update(
            records: [prompt], processPresent: true,
            now: prompt.updatedAt.addingTimeInterval(5)
        )
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].startedAt == prompt.updatedAt)
        #expect(store.sessions[0].elapsed(now: prompt.updatedAt.addingTimeInterval(5)) == 5)

        let preTool = try runEvent("PreToolUse", dir: dir)
        store.update(
            records: [preTool], processPresent: true,
            now: preTool.updatedAt.addingTimeInterval(6)
        )
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].startedAt == prompt.updatedAt)
        #expect(store.sessions[0].elapsed(now: prompt.updatedAt.addingTimeInterval(6)) == 6)
        #expect(tracker.updateClaude(store.sessions).isEmpty)

        let finished = try runEvent("Stop", dir: dir)
        store.update(
            records: [finished], processPresent: true,
            now: finished.updatedAt.addingTimeInterval(1)
        )
        #expect(store.sessions[0].state == .done)
        #expect(!store.sessions[0].state.showsElapsedTimer)
        #expect(tracker.updateClaude(store.sessions).count == 1)
    }

    @Test("Stop -> PermissionRequest -> PostToolUse is one new approval turn, then Done")
    func permissionBoundaryBeginsAndPreservesNewTurn() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stop = try runEvent("Stop", dir: dir)
        var store = ClaudeSessionStore()
        store.update(records: [stop], processPresent: true, now: stop.updatedAt)
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude(store.sessions).isEmpty)

        let request = try runEvent("PermissionRequest", dir: dir)
        store.update(
            records: [request], processPresent: true,
            now: request.updatedAt.addingTimeInterval(4)
        )
        #expect(store.sessions[0].state == .permissionRequested)
        #expect(store.sessions[0].startedAt == request.updatedAt)
        #expect(store.sessions[0].elapsed(now: request.updatedAt.addingTimeInterval(4)) == 4)
        #expect(tracker.updateClaude(store.sessions).count == 1)

        let postTool = try runEvent("PostToolUse", dir: dir)
        store.update(
            records: [postTool], processPresent: true,
            now: postTool.updatedAt.addingTimeInterval(5)
        )
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].startedAt == request.updatedAt)
        #expect(store.sessions[0].elapsed(now: request.updatedAt.addingTimeInterval(5)) == 5)
        #expect(tracker.updateClaude(store.sessions).isEmpty)

        let finished = try runEvent("Stop", dir: dir)
        store.update(
            records: [finished], processPresent: true,
            now: finished.updatedAt.addingTimeInterval(1)
        )
        #expect(store.sessions[0].state == .done)
        #expect(!store.sessions[0].state.showsElapsedTimer)
        #expect(tracker.updateClaude(store.sessions).count == 1)
    }

    @Test("Stop -> SessionEnd remains terminal")
    func sessionEndRemainsTerminalAfterFinish() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stop = try runEvent("Stop", dir: dir)
        var store = ClaudeSessionStore()
        store.update(records: [stop], processPresent: true, now: stop.updatedAt)
        let end = try runEvent("SessionEnd", dir: dir)
        #expect(end.event == .sessionEnd)
        store.update(
            records: [end], processPresent: true,
            now: end.updatedAt.addingTimeInterval(2)
        )
        #expect(store.sessions[0].state == .done)
        #expect(!store.sessions[0].state.showsElapsedTimer)
        #expect(store.keepAwakeIntent == .release)
    }

    /// 12. The script writes **only** the five allowed fields (schema 2), with correct values,
    ///     and exits 0. `project` is the final path component of `cwd` — the folder name only.
    @Test func writesOnlyAllowedFields() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = #"{"session_id":"sess-42","hook_event_name":"PreToolUse","cwd":"/Users/x/Work/DemoRepo","tool_name":"Bash"}"#
        let code = try run(stdin: payload, dir: dir)
        #expect(code == 0)

        let file = dir.appendingPathComponent("sess-42.json")
        let data = try Data(contentsOf: file)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "updatedAt", "event", "sessionID", "project"])
        #expect(object["event"] as? String == "PreToolUse")
        #expect(object["sessionID"] as? String == "sess-42")
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["project"] as? String == "DemoRepo")   // folder name only, not the path
        #expect(object["updatedAt"] != nil)
    }

    /// 13. The script ignores sensitive payload fields entirely — none of them appear in the
    ///     written file. The one deliberate disclosure is the project **folder name** (the final
    ///     path component of `cwd`, schema 2); the **full path and every parent directory** must
    ///     still never leak (docs/decisions/0012-session-name-from-cwd.md).
    @Test func ignoresSensitiveFields() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = """
        {"session_id":"sess-77","hook_event_name":"PostToolUse",\
        "transcript_path":"/Users/someone/.claude/projects/topsecret/session.jsonl",\
        "cwd":"/Users/someone/SecretParent/PrivateRepo",\
        "prompt":"MY SECRET PROMPT",\
        "tool_input":{"command":"cat ~/.ssh/id_rsa"},\
        "tool_response":"ssh-private-key-material"}
        """
        let code = try run(stdin: payload, dir: dir)
        #expect(code == 0)

        let file = dir.appendingPathComponent("sess-77.json")
        let contents = try String(contentsOf: file, encoding: .utf8)
        // Nothing sensitive leaks — including the full path, the parent directories, and the
        // `cwd` key name itself (only the derived `project` folder name is written).
        for secret in ["SECRET PROMPT", "topsecret", "session.jsonl", "SecretParent",
                       "id_rsa", "ssh-private-key-material", "transcript_path", "\"cwd\"",
                       "tool_input", "tool_response", "/Users/"] {
            #expect(!contents.contains(secret), "leaked: \(secret)")
        }
        // It records the safe fields, including only the final folder name of cwd.
        #expect(contents.contains("\"event\":\"PostToolUse\""))
        #expect(contents.contains("\"sessionID\":\"sess-77\""))
        #expect(contents.contains("\"project\":\"PrivateRepo\""))
    }

    /// 13c. A realistic `StopFailure` payload — the turn errored out, so the payload carries the
    ///      error detail the event is *about* — records only the safe finish signal
    ///      (`event=StopFailure`, session id, folder name). The error type/message must never leak,
    ///      exactly as for every other event: docs/decisions/0019 keeps the same privacy contract.
    @Test func stopFailurePayloadRecordsFinishAndIgnoresErrorDetail() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = """
        {"session_id":"sess-err","hook_event_name":"StopFailure",\
        "cwd":"/Users/someone/Work/MyRepo",\
        "error_type":"rate_limit",\
        "error":{"type":"overloaded","message":"SECRET-ERROR-DETAIL upstream 529"}}
        """
        let code = try run(stdin: payload, dir: dir)
        #expect(code == 0)

        let contents = try String(contentsOf: dir.appendingPathComponent("sess-err.json"), encoding: .utf8)
        #expect(contents.contains("\"event\":\"StopFailure\""))
        #expect(contents.contains("\"sessionID\":\"sess-err\""))
        #expect(contents.contains("\"project\":\"MyRepo\""))
        // The error detail the event carries must never leak into VibeMenu's heartbeat file.
        for secret in ["SECRET-ERROR-DETAIL", "rate_limit", "overloaded", "529",
                       "error_type", "\"error\"", "message"] {
            #expect(!contents.contains(secret), "leaked: \(secret)")
        }
    }

    /// 13b. **Nested fields cannot override top-level fields.** The payload's TOP-LEVEL
    ///      `hook_event_name`/`session_id` decide the event and filename; identically-named
    ///      keys buried inside `tool_input`/`tool_response` (which can carry attacker- or
    ///      file-controlled data) must be ignored entirely. This is the regression guard for
    ///      the Codex finding that a regex scan could let a nested `session_id` steer the
    ///      output filename or a nested `hook_event_name` steer the event.
    @Test func nestedFieldsCannotOverrideTopLevel() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Top level says Stop / real-session; the nested objects try to smuggle in a
        // different event, a different session id (used as a filename), and secrets.
        let payload = """
        {"hook_event_name":"Stop","session_id":"real-session",\
        "tool_input":{"hook_event_name":"PreToolUse","session_id":"NESTEDSECRET",\
        "command":"cat ~/.ssh/id_rsa"},\
        "tool_response":{"session_id":"ANOTHERSECRET","data":"ssh-private-key-material"}}
        """
        let code = try run(stdin: payload, dir: dir)
        #expect(code == 0)

        // The file is named for the TOP-LEVEL session id, and it is the only file written.
        let jsonFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
        #expect(jsonFiles == ["real-session.json"])
        #expect(!jsonFiles.contains { $0.contains("NESTEDSECRET") })
        #expect(!jsonFiles.contains { $0.contains("ANOTHERSECRET") })

        let contents = try String(contentsOf: dir.appendingPathComponent("real-session.json"), encoding: .utf8)
        // Top-level values won.
        #expect(contents.contains("\"event\":\"Stop\""))
        #expect(contents.contains("\"sessionID\":\"real-session\""))
        // Nothing nested — neither the smuggled ids nor the secrets — leaked into the file.
        for secret in ["NESTEDSECRET", "ANOTHERSECRET", "PreToolUse", "id_rsa",
                       "ssh-private-key-material", "tool_input", "tool_response", "command"] {
            #expect(!contents.contains(secret), "leaked: \(secret)")
        }
    }

    /// Missing `hook_event_name` (but a valid `session_id`) ⇒ documented safe `unknown`
    /// event, written to the session's own file, still exit 0.
    @Test func missingEventWritesUnknownEvent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let code = try run(stdin: #"{"session_id":"sess-only"}"#, dir: dir)
        #expect(code == 0)
        let contents = try String(contentsOf: dir.appendingPathComponent("sess-only.json"), encoding: .utf8)
        #expect(contents.contains("\"event\":\"unknown\""))
        #expect(contents.contains("\"sessionID\":\"sess-only\""))
    }

    /// Missing `session_id` ⇒ documented `unknown-session.json`, still exit 0.
    @Test func missingSessionWritesUnknownSession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let code = try run(stdin: #"{"hook_event_name":"Stop"}"#, dir: dir)
        #expect(code == 0)
        let file = dir.appendingPathComponent("unknown-session.json")
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("\"sessionID\":\"unknown-session\""))
        #expect(contents.contains("\"event\":\"Stop\""))
    }

    /// Garbage stdin never blocks Claude: exit 0, event recorded as `unknown`.
    @Test func garbageStdinExitsZero() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let code = try run(stdin: "this is not json at all", dir: dir)
        #expect(code == 0)
        let file = dir.appendingPathComponent("unknown-session.json")
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("\"event\":\"unknown\""))
    }

    /// A malicious `session_id` cannot escape the sessions directory (path-traversal is
    /// sanitized away; the file stays inside `dir`).
    @Test func pathTraversalSessionIsSanitized() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let code = try run(
            stdin: #"{"session_id":"../../etc/evil","hook_event_name":"SessionStart"}"#, dir: dir
        )
        #expect(code == 0)
        // Nothing was written outside `dir`.
        let escaped = dir.deletingLastPathComponent().appendingPathComponent("etc/evil.json")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        // A sanitized file exists inside `dir`.
        let inside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
        #expect(inside.count == 1)
        #expect(!inside[0].contains("/"))
    }
}
