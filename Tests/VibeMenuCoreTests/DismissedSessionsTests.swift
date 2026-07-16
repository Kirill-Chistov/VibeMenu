import Foundation
import Testing
@testable import VibeMenuCore

// Manual dismiss / hide tests (docs/decisions/0013-session-title-and-dismiss.md). Pure and
// synthetic. Verifies the Option-2 behaviour: a dismissed row stays hidden until the session
// emits a *newer* event, then reappears; dismissals for pruned sessions are dropped.

@Suite("DismissedSessionRegistry")
struct DismissedSessionRegistryTests {
    private let t0 = Date(timeIntervalSince1970: 6_000_000)

    private func session(
        _ id: String, state: ClaudeSessionState = .done, lastEventAt: Date
    ) -> ClaudeSession {
        ClaudeSession(
            id: id, state: state, event: .stop,
            startedAt: lastEventAt, lastEventAt: lastEventAt
        )
    }

    @Test func newRegistryHidesNothing() {
        var reg = DismissedSessionRegistry()
        #expect(reg.isEmpty)
        let s = session("a", lastEventAt: t0)
        #expect(!reg.isHidden(s))
        #expect(reg.reconcile(with: [s]).map(\.id) == ["a"])
    }

    @Test func dismissHidesUntilNewerEvent() {
        var reg = DismissedSessionRegistry()
        let s = session("a", lastEventAt: t0)
        reg.dismiss(s)
        #expect(reg.isHidden(s))
        // Same event (no new activity) → still hidden.
        #expect(reg.reconcile(with: [s]).isEmpty)

        // A newer event for the same session → un-hidden and included; watermark dropped.
        let newer = session("a", state: .working, lastEventAt: t0.addingTimeInterval(5))
        #expect(reg.reconcile(with: [newer]).map(\.id) == ["a"])
        #expect(reg.isEmpty)          // watermark cleared after un-dismiss
        #expect(!reg.isHidden(newer))
    }

    /// A finished session that never emits again stays hidden across ticks (the main use case:
    /// clearing completed sessions).
    @Test func finishedSessionStaysHidden() {
        var reg = DismissedSessionRegistry()
        let done = session("done", state: .done, lastEventAt: t0)
        reg.dismiss(done)
        for _ in 0..<5 {
            #expect(reg.reconcile(with: [done]).isEmpty)
        }
    }

    @Test func onlyDismissedSessionsAreHidden() {
        var reg = DismissedSessionRegistry()
        let a = session("a", lastEventAt: t0)
        let b = session("b", lastEventAt: t0)
        reg.dismiss(a)
        let visible = reg.reconcile(with: [a, b])
        #expect(visible.map(\.id) == ["b"])   // a hidden, b untouched
    }

    /// A dismissal for a session no longer present (pruned from the radar) is forgotten, so the
    /// map cannot grow without bound.
    @Test func dropsDismissalsForVanishedSessions() {
        var reg = DismissedSessionRegistry()
        let a = session("a", lastEventAt: t0)
        reg.dismiss(a)
        #expect(!reg.isEmpty)
        _ = reg.reconcile(with: [])        // a is gone this tick
        #expect(reg.isEmpty)
    }

    @Test func reconcilePreservesInputOrder() {
        var reg = DismissedSessionRegistry()
        let a = session("a", lastEventAt: t0)
        let b = session("b", lastEventAt: t0)
        let c = session("c", lastEventAt: t0)
        reg.dismiss(b)
        #expect(reg.reconcile(with: [a, b, c]).map(\.id) == ["a", "c"])
    }

    /// Re-dismissing a session that reappeared refreshes the watermark to its latest event, so it
    /// stays hidden until its *next* event (not immediately un-hidden by the event that revived it).
    @Test func reDismissRefreshesWatermark() {
        var reg = DismissedSessionRegistry()
        let s1 = session("a", lastEventAt: t0)
        reg.dismiss(s1)
        let revived = session("a", state: .working, lastEventAt: t0.addingTimeInterval(10))
        #expect(reg.reconcile(with: [revived]).map(\.id) == ["a"])   // reappears

        reg.dismiss(revived)                                          // user hides it again
        #expect(reg.reconcile(with: [revived]).isEmpty)              // hidden at same event
        let evenNewer = session("a", lastEventAt: t0.addingTimeInterval(20))
        #expect(reg.reconcile(with: [evenNewer]).map(\.id) == ["a"]) // next event revives again
    }
}
