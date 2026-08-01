import Foundation

/// Whether VibeMenu is currently holding a sleep-prevention power assertion.
///
/// v0.1 only ever prevents *idle system sleep* (lid open). Manual keep-awake is
/// wired to a **real** public IOKit power assertion
/// (`IOPMAssertionCreateWithName` / `IOPMAssertionRelease` with
/// `kIOPMAssertPreventUserIdleSystemSleep`) via `SystemPowerAssertionManager`
/// (see PowerAssertionManager.swift); this enum defines the observable shape
/// (SPEC §5.2).
///
/// Lid-closed / clamshell operation (kernel `disablesleep`) is explicitly out of
/// scope for v0.1 and would require a separate ADR + human approval
/// (SPEC §5.7; docs/decisions/0005-v0-1-scope.md). No clamshell / lid-close behavior
/// is implemented here.
public enum PowerAssertionState: String, Equatable, Sendable, CaseIterable {
    /// No assertion held; the system follows its normal sleep policy.
    case inactive

    /// Holding an assertion that prevents idle *system* sleep (lid open).
    case preventingIdleSleep

    /// An assertion was requested, but the system backend could not create one. No
    /// assertion is held; this is intentionally distinct from normal inactivity so
    /// the UI never turns a failed request into a misleading "On" state.
    case acquisitionFailed
}

/// The user-visible owners of VibeMenu's sleep-prevention request, in intentional
/// presentation order (Manual → Claude → Codex → ChatGPT Work). This is separate from the
/// provider-neutral automation source type because the manual preference is also an owner
/// from the user's perspective.
///
/// The ChatGPT desktop app's two modes appear as **two owners**, never one merged entry: they
/// hold and release independently, so collapsing them in the label would misreport which work
/// is actually keeping the Mac awake.
public enum PowerAssertionOwner: String, Equatable, Sendable, CaseIterable {
    case manual
    case claude
    case codex
    case chatGPTWork = "work"

    public var displayName: String {
        switch self {
        case .manual: "Manual"
        case .claude: "Claude"
        case .codex: "Codex"
        case .chatGPTWork: "ChatGPT Work"
        }
    }

    /// The owner that a given automation source presents as. Total and exhaustive, so a new
    /// keep-awake source can never silently fall through into an unrelated owner's label.
    public init(source: AgentKeepAwakeSource) {
        switch source {
        case .claude: self = .claude
        case .codex: self = .codex
        case .chatGPTWork: self = .chatGPTWork
        }
    }
}

/// Framework-free presentation state for the compact Sleep prevention status line.
/// It is derived from the manager's actual state, not just from requested ownership.
public struct PowerAssertionPresentationState: Equatable, Sendable {
    public let assertionState: PowerAssertionState
    /// Current requested owners, ordered Manual → Claude → Codex → ChatGPT Work. For a failed
    /// acquisition these are the owners that requested the unsuccessful assertion.
    public let owners: [PowerAssertionOwner]

    public init(
        assertionState: PowerAssertionState,
        manualRequested: Bool,
        automationSources: [AgentKeepAwakeSource]
    ) {
        self.assertionState = assertionState

        var owners: [PowerAssertionOwner] = []
        if manualRequested {
            owners.append(.manual)
        }
        // Ordered by `AgentKeepAwakeSource.allCases` (Claude → Codex → ChatGPT Work), not by the
        // order the caller happened to pass, so the label is stable whichever source held first.
        for source in AgentKeepAwakeSource.allCases where automationSources.contains(source) {
            owners.append(PowerAssertionOwner(source: source))
        }
        self.owners = owners
    }

    /// Honest compact wording for the menu. An active assertion with no current
    /// owner is possible after a release failure; "On" remains truthful while
    /// avoiding an invented owner.
    public var text: String {
        switch assertionState {
        case .inactive:
            return "Off"
        case .acquisitionFailed:
            return "Couldn’t enable"
        case .preventingIdleSleep:
            guard !owners.isEmpty else { return "On" }
            return "On · " + owners.map(\.displayName).joinedNaturally
        }
    }
}

private extension Array where Element == String {
    var joinedNaturally: String {
        switch count {
        case 0: ""
        case 1: self[0]
        case 2: "\(self[0]) and \(self[1])"
        default: dropLast().joined(separator: ", ") + ", and \(last!)"
        }
    }
}
