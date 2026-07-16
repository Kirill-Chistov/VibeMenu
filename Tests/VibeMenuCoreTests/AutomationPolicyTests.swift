import Testing
@testable import VibeMenuCore

// Uses Swift Testing (`import Testing`) rather than XCTest: XCTest ships with full
// Xcode, but this repo is validated with the Command Line Tools toolchain, which
// bundles Swift Testing but not XCTest. See CONTRIBUTING.md.

/// Truth-table tests for the pure decision core. This is the correctness heart of
/// VibeMenu (SPEC §6, §15 task 5), so it is exercised exhaustively where cheap.
@Suite("AutomationPolicy")
struct AutomationPolicyTests {

    // MARK: - Required cases

    /// An idle agent should not request sleep prevention.
    @Test func idleAgentDoesNotRequestSleepPrevention() {
        let decision = AutomationPolicy.decide(
            PolicyInput(mode: .automatic, agent: .idle)
        )
        #expect(decision.desiredAssertion == .inactive)
        #expect(decision.reason == .agentIdle)
    }

    /// A working agent should request sleep prevention when automation is enabled.
    @Test func workingAgentRequestsSleepPreventionWhenAutomatic() {
        let decision = AutomationPolicy.decide(
            PolicyInput(mode: .automatic, agent: .working)
        )
        #expect(decision.desiredAssertion == .preventingIdleSleep)
        #expect(decision.reason == .agentWorking)
    }

    /// Force-off should never request sleep prevention — for any agent state or
    /// thermal level.
    @Test func forceOffNeverRequestsSleepPrevention() {
        for agent in AgentActivityState.allCases {
            for thermal in ThermalPressureState.allCases {
                let decision = AutomationPolicy.decide(
                    PolicyInput(mode: .forceOff, agent: agent, thermal: thermal)
                )
                #expect(
                    decision.desiredAssertion == .inactive,
                    "force-off must never prevent sleep (agent=\(agent), thermal=\(thermal))"
                )
                #expect(decision.reason == .forcedOff)
            }
        }
    }

    /// Serious/critical thermal state must not be ignored by the policy model, even
    /// though the exact response is still a TODO.
    @Test func seriousAndCriticalThermalAreNotIgnored() {
        for thermal in [ThermalPressureState.serious, .critical] {
            let decision = AutomationPolicy.decide(
                PolicyInput(mode: .automatic, agent: .working, thermal: thermal)
            )
            #expect(
                decision.thermalWarning,
                "policy must surface \(thermal) thermal pressure, not ignore it"
            )
        }

        // ...and the flag is genuinely conditional, not hard-coded true.
        let nominal = AutomationPolicy.decide(
            PolicyInput(mode: .automatic, agent: .working, thermal: .nominal)
        )
        #expect(nominal.thermalWarning == false)
    }

    // MARK: - Additional truth-table coverage

    /// Force-awake always requests sleep prevention, even with no agent present.
    @Test func forceAwakeAlwaysRequestsSleepPrevention() {
        let decision = AutomationPolicy.decide(
            PolicyInput(mode: .forceAwake, agent: .noAgent)
        )
        #expect(decision.desiredAssertion == .preventingIdleSleep)
        #expect(decision.reason == .forcedAwake)
    }

    /// An agent waiting for input is not "working": allow sleep (SPEC §5.1).
    @Test func waitingForInputDoesNotRequestSleepPrevention() {
        let decision = AutomationPolicy.decide(
            PolicyInput(mode: .automatic, agent: .waitingForInput)
        )
        #expect(decision.desiredAssertion == .inactive)
        #expect(decision.reason == .agentWaitingForInput)
    }

    /// With automation disabled, a working agent still does not prevent sleep.
    @Test func disabledModeDoesNotRequestSleepPrevention() {
        let decision = AutomationPolicy.decide(
            PolicyInput(mode: .disabled, agent: .working)
        )
        #expect(decision.desiredAssertion == .inactive)
        #expect(decision.reason == .automationDisabled)
    }

    /// No agent under automatic mode does not prevent sleep.
    @Test func noAgentUnderAutomaticDoesNotRequestSleepPrevention() {
        let decision = AutomationPolicy.decide(
            PolicyInput(mode: .automatic, agent: .noAgent)
        )
        #expect(decision.desiredAssertion == .inactive)
        #expect(decision.reason == .noAgent)
    }
}
