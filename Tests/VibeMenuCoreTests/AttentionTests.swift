import Foundation
import Testing
@testable import VibeMenuCore

@Suite("Attention v1 — notification permission and transitions")
struct AttentionTests {
    private let t0 = Date(timeIntervalSince1970: 6_000_000)

    private func claude(
        _ id: String,
        state: ClaudeSessionState,
        event: ClaudeHeartbeatEvent,
        at: Date,
        name: String = "Project"
    ) -> ClaudeSession {
        ClaudeSession(
            id: id, state: state, event: event, startedAt: at, lastEventAt: at,
            projectName: name
        )
    }

    private func codex(
        _ id: String,
        state: CodexSessionState,
        at: Date,
        completed: Bool,
        name: String = "Project"
    ) -> CodexSession {
        CodexSession(
            id: id, state: state, folderName: name, startedAt: at,
            lastActivity: at, endedWithCompletion: completed
        )
    }

    @Test("Notification preference is off by default and denied permission stays off")
    func permissionGate() {
        var preference = AttentionNotificationPreference()
        #expect(!preference.isEnabled)
        #expect(preference.beginUserChange(requested: false) == .none)
        #expect(!preference.isEnabled)
        #expect(preference.beginUserChange(requested: true) == .requestAuthorization)
        #expect(!preference.isEnabled)

        preference.finishAuthorization(granted: false)
        #expect(!preference.isEnabled)

        #expect(preference.beginUserChange(requested: true) == .requestAuthorization)
        preference.finishAuthorization(granted: true)
        #expect(preference.isEnabled)

        let event = AttentionNotification(provider: .claude, displayName: "Project", kind: .finished)
        preference.apply(requested: false)
        #expect(preference.deliverable([event]).isEmpty)
        preference.finishAuthorization(granted: true)
        #expect(preference.deliverable([event]) == [event])

        preference.apply(requested: false)
        #expect(!preference.isEnabled)
    }

    @Test("Initial target states establish a silent baseline")
    func initialStatesAreSilent() {
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude([
            claude("claude", state: .done, event: .stop, at: t0)
        ]).isEmpty)
        #expect(tracker.updateCodex([
            codex("codex", state: .done, at: t0, completed: true)
        ]).isEmpty)
    }

    @Test("Same Claude heartbeat stays silent when process-derived state changes")
    func sameClaudeHeartbeatAcrossDerivedStateChangeIsSilent() {
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude([
            claude("s", state: .working, event: .userPromptSubmit, at: t0)
        ]).isEmpty)
        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .userPromptSubmit, at: t0)
        ]).isEmpty)
        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .userPromptSubmit, at: t0)
        ]).isEmpty)
    }

    @Test("Same timestamp UserPromptSubmit to Stop notifies once")
    func sameTimestampFinishEventNotifiesOnce() {
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude([
            claude("s", state: .working, event: .userPromptSubmit, at: t0)
        ]).isEmpty)

        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .stop, at: t0)
        ]) == [AttentionNotification(
            provider: .claude, displayName: "Project", kind: .finished
        )])
        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .stop, at: t0)
        ]).isEmpty)
    }

    @Test("Only genuine Claude finish events notify")
    func onlyGenuineClaudeFinishesNotify() {
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude([
            claude("existing", state: .working, event: .userPromptSubmit, at: t0)
        ]).isEmpty)

        // Process absence can derive a fresh active heartbeat as Done, but it is not completion
        // evidence and must stay silent.
        #expect(tracker.updateClaude([
            claude("existing", state: .done, event: .userPromptSubmit, at: t0.addingTimeInterval(1)),
            claude("started", state: .done, event: .sessionStart, at: t0.addingTimeInterval(1))
        ]).isEmpty)
    }

    @Test("Newer Stop and StopFailure generations each notify")
    func newerClaudeFinishGenerationsNotify() {
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .stop, at: t0)
        ]).isEmpty)

        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .stop, at: t0.addingTimeInterval(1))
        ]).count == 1)
        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .stopFailure, at: t0.addingTimeInterval(2))
        ]) == [AttentionNotification(
            provider: .claude, displayName: "Project", kind: .finished
        )])
        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .stopFailure, at: t0.addingTimeInterval(2))
        ]).isEmpty)
    }

    @Test("A new SessionStart after baseline is silent")
    func newSessionStartAfterBaselineIsSilent() {
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude([
            claude("existing", state: .working, event: .userPromptSubmit, at: t0)
        ]).isEmpty)
        #expect(tracker.updateClaude([
            claude("new", state: .done, event: .sessionStart, at: t0.addingTimeInterval(1))
        ]).isEmpty)
    }

    @Test("A newer Claude completion notifies even when polling observes Done twice")
    func newerClaudeCompletionGenerationNotifiesWithoutWorkingSnapshot() {
        var tracker = AttentionTransitionTracker()
        let firstCompletion = t0.addingTimeInterval(1)
        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .stop, at: firstCompletion)
        ]).isEmpty)

        let secondCompletion = t0.addingTimeInterval(2)
        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .stop, at: secondCompletion)
        ]) == [AttentionNotification(
            provider: .claude, displayName: "Project", kind: .finished
        )])
    }

    @Test("A newer Claude permission request notifies even when approval remains the state")
    func newerPermissionRequestGenerationNotifiesWithoutStateChange() {
        var tracker = AttentionTransitionTracker()
        let firstRequest = t0.addingTimeInterval(1)
        #expect(tracker.updateClaude([
            claude("s", state: .permissionRequested, event: .permissionRequested, at: firstRequest)
        ]).isEmpty)

        let secondRequest = t0.addingTimeInterval(2)
        #expect(tracker.updateClaude([
            claude("s", state: .permissionRequested, event: .permissionRequested, at: secondRequest)
        ]) == [AttentionNotification(
            provider: .claude, displayName: "Project", kind: .needsApproval
        )])
    }

    @Test("A newer Codex completion notifies even when polling observes Done twice")
    func newerCodexCompletionGenerationNotifiesWithoutWorkingSnapshot() {
        var tracker = AttentionTransitionTracker()
        let firstCompletion = t0.addingTimeInterval(1)
        #expect(tracker.updateCodex([
            codex("s", state: .done, at: firstCompletion, completed: true)
        ]).isEmpty)

        let secondCompletion = t0.addingTimeInterval(2)
        #expect(tracker.updateCodex([
            codex("s", state: .done, at: secondCompletion, completed: true)
        ]) == [AttentionNotification(
            provider: .codex, displayName: "Project", kind: .finished
        )])
    }

    @Test("Repeated identical heartbeat markers remain silent")
    func repeatedIdenticalMarkersAreSilent() {
        var tracker = AttentionTransitionTracker()
        let claudeDone = t0.addingTimeInterval(1)
        #expect(tracker.updateClaude([
            claude("claude", state: .done, event: .stop, at: claudeDone)
        ]).isEmpty)
        #expect(tracker.updateClaude([
            claude("claude", state: .done, event: .stop, at: claudeDone)
        ]).isEmpty)

        let codexDone = t0.addingTimeInterval(2)
        #expect(tracker.updateCodex([
            codex("codex", state: .done, at: codexDone, completed: true)
        ]).isEmpty)
        #expect(tracker.updateCodex([
            codex("codex", state: .done, at: codexDone, completed: true)
        ]).isEmpty)
    }

    @Test("A new target-state session can notify after the provider baseline")
    func newSessionAfterBaselineCanNotify() {
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude([
            claude("existing", state: .working, event: .userPromptSubmit, at: t0)
        ]).isEmpty)

        #expect(tracker.updateClaude([
            claude("existing", state: .working, event: .userPromptSubmit, at: t0),
            claude("new", state: .done, event: .stop, at: t0.addingTimeInterval(1))
        ]) == [AttentionNotification(
            provider: .claude, displayName: "Project", kind: .finished
        )])
    }

    @Test("Provider reset makes the next target snapshot a silent baseline")
    func providerDisableReenableEstablishesSilentBaseline() {
        var tracker = AttentionTransitionTracker()
        let first = t0.addingTimeInterval(1)
        #expect(tracker.updateCodex([
            codex("s", state: .done, at: first, completed: true)
        ]).isEmpty)

        let second = t0.addingTimeInterval(2)
        #expect(tracker.updateCodex([
            codex("s", state: .done, at: second, completed: true)
        ]).count == 1)

        tracker.reset(provider: .codex)
        #expect(tracker.updateCodex([
            codex("s", state: .done, at: second, completed: true)
        ]).isEmpty)
        #expect(tracker.updateCodex([
            codex("s", state: .done, at: t0.addingTimeInterval(3), completed: true)
        ]).count == 1)
    }

    @Test("Working and Quiet to Done notify once, then repeated Done is silent")
    func workingAndQuietToDone() {
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude([
            claude("working", state: .working, event: .userPromptSubmit, at: t0),
            claude("quiet", state: .quietWorking, event: .subagentStop, at: t0)
        ]).isEmpty)

        let doneAt = t0.addingTimeInterval(10)
        let first = tracker.updateClaude([
            claude("working", state: .done, event: .stop, at: doneAt),
            claude("quiet", state: .done, event: .stop, at: doneAt)
        ])
        #expect(first.map(\.kind) == [.finished, .finished])
        #expect(tracker.updateClaude([
            claude("working", state: .done, event: .stop, at: doneAt),
            claude("quiet", state: .done, event: .stop, at: doneAt)
        ]).isEmpty)
    }

    @Test("Working or Quiet to Needs approval notifies once")
    func workingToApproval() {
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude([
            claude("working", state: .working, event: .preToolUse, at: t0),
            claude("quiet", state: .quietWorking, event: .subagentStop, at: t0)
        ]).isEmpty)

        let approvalAt = t0.addingTimeInterval(2)
        let events = tracker.updateClaude([
            claude(
                "working", state: .permissionRequested, event: .permissionRequested, at: approvalAt
            ),
            claude(
                "quiet", state: .permissionRequested, event: .permissionRequested, at: approvalAt
            )
        ])
        #expect(events == [
            AttentionNotification(provider: .claude, displayName: "Project", kind: .needsApproval),
            AttentionNotification(provider: .claude, displayName: "Project", kind: .needsApproval)
        ])
        #expect(tracker.updateClaude([
            claude(
                "working", state: .permissionRequested, event: .permissionRequested, at: approvalAt
            ),
            claude(
                "quiet", state: .permissionRequested, event: .permissionRequested, at: approvalAt
            )
        ]).isEmpty)
    }

    @Test("Done to Working to Done produces a second completion notification")
    func reusedClaudeSessionNotifiesAgain() {
        var tracker = AttentionTransitionTracker()
        #expect(tracker.updateClaude([
            claude("s", state: .working, event: .userPromptSubmit, at: t0)
        ]).isEmpty)

        let firstDone = t0.addingTimeInterval(5)
        #expect(tracker.updateClaude([
            claude("s", state: .done, event: .stop, at: firstDone)
        ]).count == 1)
        #expect(tracker.updateClaude([
            claude("s", state: .working, event: .userPromptSubmit, at: firstDone.addingTimeInterval(5))
        ]).isEmpty)

        let second = tracker.updateClaude([
            claude("s", state: .done, event: .stop, at: firstDone.addingTimeInterval(10))
        ])
        #expect(second == [AttentionNotification(
            provider: .claude, displayName: "Project", kind: .finished
        )])
    }

    @Test("Codex Done is silent initially and notifies after a reused turn finishes")
    func reusedCodexSessionNotifiesAgain() {
        var tracker = AttentionTransitionTracker()
        let doneAt = t0.addingTimeInterval(5)
        #expect(tracker.updateCodex([
            codex("s", state: .done, at: doneAt, completed: true)
        ]).isEmpty)
        #expect(tracker.updateCodex([
            codex("s", state: .active, at: doneAt.addingTimeInterval(5), completed: false)
        ]).isEmpty)
        #expect(tracker.updateCodex([
            codex("s", state: .done, at: doneAt.addingTimeInterval(10), completed: true)
        ]) == [AttentionNotification(
            provider: .codex, displayName: "Project", kind: .finished
        )])
        #expect(tracker.updateCodex([
            codex("s", state: .done, at: doneAt.addingTimeInterval(10), completed: true)
        ]).isEmpty)
    }

    @Test("Claude Done to newer work resets the visible timer, but an identical refresh does not")
    func claudeTurnTimerReset() {
        var store = ClaudeSessionStore()
        let doneAt = t0
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .stop, updatedAt: doneAt)],
            processPresent: true,
            now: doneAt
        )
        #expect(store.sessions[0].startedAt == doneAt)
        #expect(!store.sessions[0].state.showsElapsedTimer)

        let turnAt = doneAt.addingTimeInterval(30)
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .userPromptSubmit, updatedAt: turnAt)],
            processPresent: true,
            now: turnAt.addingTimeInterval(2)
        )
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].startedAt == turnAt)
        #expect(store.sessions[0].elapsed(now: turnAt) == 0)

        let resetStart = store.sessions[0].startedAt
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .userPromptSubmit, updatedAt: turnAt)],
            processPresent: true,
            now: turnAt.addingTimeInterval(20)
        )
        #expect(store.sessions[0].startedAt == resetStart)
        #expect(store.sessions[0].elapsed(now: turnAt.addingTimeInterval(20)) == 20)
    }

    @Test("Done to PermissionRequest to Working preserves the request turn start")
    func approvalFirstReusableTurnStart() {
        var store = ClaudeSessionStore()
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .stop, updatedAt: t0)],
            processPresent: true,
            now: t0
        )

        let requestAt = t0.addingTimeInterval(30)
        store.update(
            records: [ClaudeHeartbeatRecord(
                sessionID: "s", event: .permissionRequested, updatedAt: requestAt
            )],
            processPresent: true,
            now: requestAt
        )
        #expect(store.sessions[0].state == .permissionRequested)
        #expect(store.sessions[0].startedAt == requestAt)
        #expect(store.sessions[0].displayElapsed(now: requestAt.addingTimeInterval(7)) == 7)

        let resumedAt = requestAt.addingTimeInterval(10)
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .postToolUse, updatedAt: resumedAt)],
            processPresent: true,
            now: resumedAt
        )
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].startedAt == requestAt)
        #expect(store.sessions[0].elapsed(now: resumedAt) == 10)
    }

    @Test("PermissionRequest during an existing turn does not reset its timer")
    func approvalDuringWorkingTurnPreservesOriginalStart() {
        var store = ClaudeSessionStore()
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .userPromptSubmit, updatedAt: t0)],
            processPresent: true,
            now: t0
        )

        let requestAt = t0.addingTimeInterval(30)
        store.update(
            records: [ClaudeHeartbeatRecord(
                sessionID: "s", event: .permissionRequested, updatedAt: requestAt
            )],
            processPresent: true,
            now: requestAt
        )
        #expect(store.sessions[0].startedAt == t0)

        let resumedAt = requestAt.addingTimeInterval(10)
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .postToolUse, updatedAt: resumedAt)],
            processPresent: true,
            now: resumedAt
        )
        #expect(store.sessions[0].startedAt == t0)
        #expect(store.sessions[0].elapsed(now: resumedAt) == 40)
    }

    @Test("Stop and StopFailure become Done immediately from Working or Quiet")
    func genuineFinishBecomesDoneImmediately() {
        var store = ClaudeSessionStore()
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .preToolUse, updatedAt: t0)],
            processPresent: true,
            now: t0.addingTimeInterval(300)
        )
        #expect(store.sessions[0].state == .quietWorking)

        let stopAt = t0.addingTimeInterval(300)
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .stop, updatedAt: stopAt)],
            processPresent: false,
            now: stopAt.addingTimeInterval(1_000)
        )
        #expect(store.sessions[0].state == .done)
        #expect(!store.sessions[0].state.showsElapsedTimer)

        let resumedAt = stopAt.addingTimeInterval(1)
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .preToolUse, updatedAt: resumedAt)],
            processPresent: true,
            now: resumedAt.addingTimeInterval(300)
        )
        #expect(store.sessions[0].state == .quietWorking)

        let failureAt = resumedAt.addingTimeInterval(300)
        store.update(
            records: [ClaudeHeartbeatRecord(sessionID: "s", event: .stopFailure, updatedAt: failureAt)],
            processPresent: false,
            now: failureAt.addingTimeInterval(1_000)
        )
        #expect(store.sessions[0].state == .done)
        #expect(!store.sessions[0].state.showsElapsedTimer)
    }

    @Test("Same-second work replacement by Stop becomes Done")
    func sameSecondWorkReplacementByStopBecomesDone() {
        var store = ClaudeSessionStore()
        store.update(
            records: [
                ClaudeHeartbeatRecord(sessionID: "s", event: .preToolUse, updatedAt: t0),
                ClaudeHeartbeatRecord(sessionID: "s", event: .stop, updatedAt: t0)
            ],
            processPresent: true,
            now: t0
        )
        #expect(store.sessions[0].state == .done)
        #expect(store.sessions[0].event == .stop)
    }

    @Test("Codex Done to newer activity resets its visible turn timer")
    func codexTurnTimerReset() {
        var timerStore = CodexSessionTurnStore()
        let first = codex("s", state: .active, at: t0, completed: false)
        let firstTimed = timerStore.update([first], previousSessions: [])
        #expect(firstTimed[0].timerStartedAt == t0)

        let doneAt = t0.addingTimeInterval(10)
        let done = codex("s", state: .done, at: doneAt, completed: true)
        _ = timerStore.update([done], previousSessions: firstTimed)

        let turnAt = t0.addingTimeInterval(20)
        let reused = codex("s", state: .active, at: turnAt, completed: false)
        let reusedTimed = timerStore.update([reused], previousSessions: [done])
        #expect(reusedTimed[0].timerStartedAt == turnAt)
        #expect(reusedTimed[0].elapsed(now: turnAt) == 0)

        let duplicate = timerStore.update([reused], previousSessions: reusedTimed)
        #expect(duplicate[0].timerStartedAt == turnAt)
        #expect(duplicate[0].elapsed(now: turnAt.addingTimeInterval(4)) == 4)
    }

    @Test("Rows and notification clicks share explicit provider targets")
    func providerTargets() {
        #expect(AttentionProvider.claude.applicationBundleIdentifier == "com.anthropic.claudefordesktop")
        #expect(AttentionProvider.codex.applicationBundleIdentifier == "com.openai.codex")
        for rowProvider in AttentionProvider.allCases {
            #expect(AttentionNavigation.provider(fromNotificationValue: rowProvider.rawValue) == rowProvider)
        }
        #expect(AttentionNavigation.provider(fromNotificationValue: "unknown") == nil)
    }
}
