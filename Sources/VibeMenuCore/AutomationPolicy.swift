import Foundation

/// User-facing automation mode. Manual overrides always win over activity-driven
/// behavior.
public enum AutomationMode: String, Equatable, Sendable, CaseIterable {
    /// Automation is off; VibeMenu never requests sleep prevention on its own.
    case disabled

    /// Follow agent activity: awake while working, release when idle.
    case automatic

    /// Manual override: always prevent idle sleep, regardless of agent state.
    case forceAwake

    /// Manual override: never prevent sleep, even if an agent is working.
    case forceOff
}

/// Immutable inputs to a single policy decision. Pure value type — no I/O.
///
/// `battery` and other signals are intentionally omitted for now: v0.1 lid-open
/// automation does not need them, and we build the shape, not the full behavior.
public struct PolicyInput: Equatable, Sendable {
    public var mode: AutomationMode
    public var agent: AgentActivityState
    public var thermal: ThermalPressureState

    public init(
        mode: AutomationMode,
        agent: AgentActivityState,
        thermal: ThermalPressureState = .nominal
    ) {
        self.mode = mode
        self.agent = agent
        self.thermal = thermal
    }
}

/// Why the policy arrived at its decision — surfaced in the UI ("why it's awake").
public enum PolicyReason: String, Equatable, Sendable {
    case forcedOff
    case forcedAwake
    case automationDisabled
    case agentWorking
    case agentIdle
    case agentWaitingForInput
    case noAgent
}

/// The pure result of a policy decision.
public struct PolicyDecision: Equatable, Sendable {
    /// The sleep-prevention state VibeMenu *should* be in.
    public let desiredAssertion: PowerAssertionState

    /// Human-readable justification for the decision.
    public let reason: PolicyReason

    /// True when thermal pressure is serious or critical.
    ///
    /// The policy never silently ignores high thermal pressure: it always flags it
    /// here so the UI (and future logic) can react. The *exact* response — e.g.
    /// whether serious/critical should auto-release a lid-open assertion — is a
    /// deferred product decision (TODO / future ADR), so v0.1 only surfaces it.
    public let thermalWarning: Bool

    public init(
        desiredAssertion: PowerAssertionState,
        reason: PolicyReason,
        thermalWarning: Bool
    ) {
        self.desiredAssertion = desiredAssertion
        self.reason = reason
        self.thermalWarning = thermalWarning
    }
}

/// Pure decision core: `(mode × agent activity × thermal) → desired power state`.
///
/// This type is intentionally free of I/O so it can be exhaustively unit-tested and
/// audited by a human plus a second model (SPEC §6, §12). All real correctness of
/// the automation loop lives here; everything else is plumbing.
public enum AutomationPolicy {

    /// Decide the desired sleep-prevention state for the given inputs.
    public static func decide(_ input: PolicyInput) -> PolicyDecision {
        // Thermal pressure is *always* evaluated, never dropped — even when it does
        // not (yet) change the assertion outcome.
        // TODO(ADR): decide whether serious/critical thermal pressure should
        // auto-release a lid-open assertion, or only warn. For v0.1 we surface it.
        let thermalWarning = input.thermal >= .serious

        switch input.mode {
        case .forceOff:
            // Manual "force off" wins over everything, including a working agent.
            return PolicyDecision(
                desiredAssertion: .inactive,
                reason: .forcedOff,
                thermalWarning: thermalWarning
            )

        case .disabled:
            return PolicyDecision(
                desiredAssertion: .inactive,
                reason: .automationDisabled,
                thermalWarning: thermalWarning
            )

        case .forceAwake:
            return PolicyDecision(
                desiredAssertion: .preventingIdleSleep,
                reason: .forcedAwake,
                thermalWarning: thermalWarning
            )

        case .automatic:
            switch input.agent {
            case .working:
                return PolicyDecision(
                    desiredAssertion: .preventingIdleSleep,
                    reason: .agentWorking,
                    thermalWarning: thermalWarning
                )

            case .idle:
                return PolicyDecision(
                    desiredAssertion: .inactive,
                    reason: .agentIdle,
                    thermalWarning: thermalWarning
                )

            case .waitingForInput:
                // Paused-on-a-prompt is not "working": allow sleep (SPEC §5.1).
                return PolicyDecision(
                    desiredAssertion: .inactive,
                    reason: .agentWaitingForInput,
                    thermalWarning: thermalWarning
                )

            case .noAgent, .unknown:
                return PolicyDecision(
                    desiredAssertion: .inactive,
                    reason: .noAgent,
                    thermalWarning: thermalWarning
                )
            }
        }
    }
}
