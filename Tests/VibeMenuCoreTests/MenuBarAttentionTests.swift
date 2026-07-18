import Foundation
import Testing
@testable import VibeMenuCore

@Suite("Claude menu-bar attention")
struct MenuBarAttentionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(
        _ id: String,
        _ state: ClaudeSessionState,
        event: ClaudeHeartbeatEvent = .preToolUse
    ) -> ClaudeSession {
        ClaudeSession(
            id: id,
            state: state,
            event: event,
            startedAt: now,
            lastEventAt: now
        )
    }

    @Test("No raw sessions means no attention indication")
    func noSessionsDoNotNeedAttention() {
        #expect(!sessionsNeedAttention([]))
    }

    @Test("Working, Quiet, Done, Stale, and Unknown do not need attention")
    func ordinaryStatesDoNotNeedAttention() {
        let sessions = [
            session("working", .working),
            session("quiet", .quietWorking),
            session("done", .done, event: .stop),
            session("stale", .stale),
            session("unknown", .unknown, event: .unknown),
        ]

        #expect(!sessionsNeedAttention(sessions))
    }

    @Test("One permission-requested session needs attention")
    func oneApprovalNeedsAttention() {
        let approval = session("approval", .permissionRequested, event: .permissionRequested)

        #expect(sessionsNeedAttention([approval]))
    }

    @Test("One approval among ordinary sessions needs attention")
    func oneApprovalAmongOrdinarySessionsNeedsAttention() {
        let sessions = [
            session("working", .working),
            session("approval", .permissionRequested, event: .permissionRequested),
            session("done", .done, event: .stop),
        ]

        #expect(sessionsNeedAttention(sessions))
    }

    @Test("Clearing the approval state removes attention")
    func clearedApprovalNeedsNoAttention() {
        let approval = session("session", .permissionRequested, event: .permissionRequested)
        let cleared = session("session", .done, event: .stop)

        #expect(sessionsNeedAttention([approval]))
        #expect(!sessionsNeedAttention([cleared]))
    }

    @Test("Hidden row presentation does not determine raw attention")
    func hiddenApprovalStillNeedsAttentionInRawList() {
        let approval = session("approval", .permissionRequested, event: .permissionRequested)
        let ordinary = session("ordinary", .done, event: .stop)
        var dismissed = DismissedSessionRegistry()
        dismissed.dismiss(approval)

        let visible = dismissed.reconcile(with: [approval, ordinary])

        #expect(visible.map(\.id) == ["ordinary"])
        #expect(!sessionsNeedAttention(visible))
        #expect(sessionsNeedAttention([approval, ordinary]))
    }
}
