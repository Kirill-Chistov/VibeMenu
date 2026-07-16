import Foundation

// Protocols + no-op stubs that define the *shape* of the runtime collaborators the
// app will eventually depend on. Real behavior is deferred (SPEC §5); these exist
// so the app can compile against final boundaries and so future work has seams to
// fill without reshaping the architecture.
//
// Architecture rule: anything touching private APIs, root, or clamshell must NOT
// live here — it belongs outside VibeMenuCore behind its own ADR + human approval
// (see docs/ARCHITECTURE.md and docs/decisions/0005-v0-1-scope.md).

// MARK: - Agent monitoring

/// Observes whether a watched coding agent is working — using process presence and
/// file *metadata* (modification times) only, never transcript contents
/// (docs/PRIVACY.md, SPEC §5.1).
public protocol AgentMonitoring: AnyObject {
    var state: AgentActivityState { get }
    func start()
    func stop()
}

/// No-op placeholder. Reports `.unknown` and does nothing.
public final class StubAgentMonitor: AgentMonitoring {
    public private(set) var state: AgentActivityState = .unknown

    public init() {}

    // TODO: observe `claude` process presence (e.g. `proc_listpids`) plus the
    // current session-file mtime via FSEvents / DispatchSource. Event-driven only —
    // no polling loop (docs/decisions/0006-lightweight-resource-budget.md). Never read
    // transcript *contents*.
    public func start() {}
    public func stop() {}
}

// MARK: - Power assertions
//
// Manual sleep prevention is now REAL: `PowerAsserting` / `SystemPowerAssertionManager`
// / `PowerAssertionModel` live in `PowerAssertionManager.swift`, backed by public
// IOKit power-assertion APIs. (This section previously held a no-op stub.)

// MARK: - System status

/// Exposes thermal / CPU / memory / battery via public APIs. Deferred; the stub
/// reports nominal thermal state and assembles a snapshot from what it is given.
///
/// NOTE: v0.1 already ships a *real* thermal reading via the focused
/// `ThermalStatusObserving` / `SystemThermalStatusProvider` seam (see
/// `ThermalStatusProvider.swift`), which the menu UI consumes directly. This
/// broader snapshot provider stays a stub until CPU/memory/battery are wired; a
/// later change can have it consume the thermal provider instead of hard-coding
/// `.nominal`.
public protocol SystemStatusProviding: AnyObject {
    var thermalPressure: ThermalPressureState { get }
    func snapshot(agent: AgentActivityState, assertion: PowerAssertionState) -> SystemSnapshot
}

public final class StubSystemStatus: SystemStatusProviding {
    public private(set) var thermalPressure: ThermalPressureState = .nominal

    public init() {}

    // TODO: read `ProcessInfo.processInfo.thermalState` (observe
    // `thermalStateDidChangeNotification`), `host_statistics64` for CPU/memory, and
    // `IOPowerSources` for battery. Public APIs only; no exact temperatures.
    public func snapshot(
        agent: AgentActivityState,
        assertion: PowerAssertionState
    ) -> SystemSnapshot {
        SystemSnapshot(agent: agent, thermal: thermalPressure, assertion: assertion)
    }
}
