import Foundation

/// A lightweight, immutable snapshot of everything the menu-bar UI needs to render
/// at a given moment.
///
/// Pure value type; assembled by the app layer from the (currently stubbed)
/// monitors. Kept deliberately small per the lightweight resource budget
/// (docs/decisions/0006-lightweight-resource-budget.md) — no history buffers, no heavy
/// time series.
public struct SystemSnapshot: Equatable, Sendable {
    public var agent: AgentActivityState
    public var thermal: ThermalPressureState
    public var assertion: PowerAssertionState

    public init(
        agent: AgentActivityState,
        thermal: ThermalPressureState,
        assertion: PowerAssertionState
    ) {
        self.agent = agent
        self.thermal = thermal
        self.assertion = assertion
    }

    /// A neutral "nothing wired yet" snapshot used by the placeholder UI in v0.0.
    public static let placeholder = SystemSnapshot(
        agent: .unknown,
        thermal: .nominal,
        assertion: .inactive
    )
}
