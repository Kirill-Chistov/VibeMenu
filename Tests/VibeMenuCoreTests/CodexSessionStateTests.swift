import Foundation
import Testing
@testable import VibeMenuCore

// Pure activity-heuristic tests for `CodexSessionState.derive` (docs/decisions/0017). The heuristic
// is deliberately conservative: `.active` only on very recent, non-completed activity; `.done` only
// on a real completion marker; otherwise it ages down to `.idle`/`.stale`. No fake "working".

@Suite("CodexSessionState.derive — activity heuristic")
struct CodexSessionStateDeriveTests {
    let active = CodexSessionState.defaultActiveWindow    // 60
    let idle = CodexSessionState.defaultIdleWindow        // 900
    let done = CodexSessionState.defaultDoneWindow        // 900

    @Test("Very recent, not completed → active")
    func recentNotCompleted() {
        #expect(CodexSessionState.derive(age: 5, endedWithCompletion: false) == .active)
        #expect(CodexSessionState.derive(age: active, endedWithCompletion: false) == .active)   // boundary
    }

    @Test("Past the active window but recent, not completed → idle")
    func recentIdle() {
        #expect(CodexSessionState.derive(age: active + 1, endedWithCompletion: false) == .idle)
        #expect(CodexSessionState.derive(age: idle, endedWithCompletion: false) == .idle)       // boundary
    }

    @Test("Old, not completed → stale (never a fake active)")
    func oldNotCompleted() {
        #expect(CodexSessionState.derive(age: idle + 1, endedWithCompletion: false) == .stale)
        #expect(CodexSessionState.derive(age: 10 * 3600, endedWithCompletion: false) == .stale)
    }

    @Test("Recently completed → done (only on the reliable marker)")
    func recentlyCompleted() {
        #expect(CodexSessionState.derive(age: 5, endedWithCompletion: true) == .done)
        #expect(CodexSessionState.derive(age: done, endedWithCompletion: true) == .done)        // boundary
    }

    @Test("Completed long ago → stale")
    func completedLongAgo() {
        #expect(CodexSessionState.derive(age: done + 1, endedWithCompletion: true) == .stale)
    }

    @Test("Clock skew (negative age) is clamped to just-now → active when not completed")
    func clockSkewClamped() {
        #expect(CodexSessionState.derive(age: -30, endedWithCompletion: false) == .active)
        #expect(CodexSessionState.derive(age: -30, endedWithCompletion: true) == .done)
    }

    @Test("Completion always wins over freshness (a fresh completed turn is Done, not Active)")
    func completionWinsOverFreshness() {
        #expect(CodexSessionState.derive(age: 1, endedWithCompletion: true) == .done)
    }
}

@Suite("CodexSessionState — display mapping")
struct CodexSessionStateDisplayTests {
    @Test("Labels are the terse expected words")
    func labels() {
        #expect(CodexSessionState.active.label == "Active")
        #expect(CodexSessionState.idle.label == "Idle")
        #expect(CodexSessionState.done.label == "Done")
        #expect(CodexSessionState.stale.label == "Stale")
    }

    @Test("Only .active shows the elapsed timer")
    func timerOnlyForActive() {
        #expect(CodexSessionState.active.showsElapsedTimer)
        for s in [CodexSessionState.idle, .done, .stale, .unknown] {
            #expect(!s.showsElapsedTimer)
        }
    }

    @Test("Sort priority puts active first, done below idle")
    func sortPriority() {
        #expect(CodexSessionState.active.sortPriority < CodexSessionState.idle.sortPriority)
        #expect(CodexSessionState.idle.sortPriority < CodexSessionState.done.sortPriority)
        #expect(CodexSessionState.done.sortPriority < CodexSessionState.stale.sortPriority)
    }

    @Test("Display style maps active→working, idle→idle, done→done, stale/unknown→inactive")
    func displayStyle() {
        #expect(CodexSessionState.active.displayStyle == .working)
        #expect(CodexSessionState.idle.displayStyle == .idle)
        #expect(CodexSessionState.done.displayStyle == .done)
        #expect(CodexSessionState.stale.displayStyle == .inactive)
        #expect(CodexSessionState.unknown.displayStyle == .inactive)
    }
}

// `AutomationPolicy` remains the older Claude-only pure policy, while active Codex sessions feed the
// provider-neutral `PowerAssertionModel` through `CodexSessionActivity` (ADR 0017 Amendment 3). These
// tests pin the narrower fact that no Codex field was added to the legacy policy input.
@Suite("AutomationPolicy remains Claude-only")
struct CodexLegacyPolicyTests {

    @Test("With no Claude agent, the legacy policy returns no assertion")
    func noClaudeInputReturnsNoLegacyPolicyAssertion() {
        // Codex is intentionally not an input to this type; its separate shared-power path is tested in
        // AgentKeepAwakeTests and PowerAssertionTests.
        let decision = AutomationPolicy.decide(PolicyInput(mode: .automatic, agent: .noAgent))
        #expect(decision.desiredAssertion == .inactive)
        #expect(decision.reason == .noAgent)
    }

    @Test("The legacy policy remains a pure function of mode, Claude agent, and thermal")
    func policyInputHasNoCodexChannel() {
        // Building an active Codex session is possible, but there is deliberately no policy overload that
        // accepts it. Codex activity contributes later through the provider-neutral power model; this
        // test documents only the legacy policy's Claude working→awake / idle→asleep behavior.
        let working = AutomationPolicy.decide(PolicyInput(mode: .automatic, agent: .working))
        let idle = AutomationPolicy.decide(PolicyInput(mode: .automatic, agent: .idle))
        #expect(working.desiredAssertion == .preventingIdleSleep)
        #expect(idle.desiredAssertion == .inactive)
    }
}
