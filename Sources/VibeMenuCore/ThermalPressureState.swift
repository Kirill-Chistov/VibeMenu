import Foundation

/// Public-API-only thermal pressure level.
///
/// Mirrors `ProcessInfo.ThermalState` (nominal / fair / serious / critical) so the
/// core never needs private SMC/IOReport access or exact temperatures
/// (SPEC §5.3, §5.5; docs/decisions/0005-v0-1-scope.md). Exact °C and fan RPM are
/// explicitly out of scope for v0.1.
///
/// Cases are ordered from least to most severe so policy code can compare
/// pressure levels (`thermal >= .serious`).
public enum ThermalPressureState: Int, Equatable, Comparable, Sendable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalPressureState, rhs: ThermalPressureState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension ThermalPressureState {
    /// Map a public `ProcessInfo.ThermalState` to VibeMenu's internal model.
    ///
    /// This is the one and only bridge from Apple's public thermal API into the
    /// core model. It is a *pure* function of its input, so the mapping can be
    /// unit-tested without forcing the real Mac into any thermal state.
    ///
    /// Returns `nil` for any future/unrecognized `ProcessInfo.ThermalState` case
    /// (the `@unknown default` path). The UI surfaces that as "Unknown"; the core
    /// deliberately does not invent a fifth pressure level, so `AutomationPolicy`'s
    /// ordered comparisons (`thermal >= .serious`) stay total over four real cases.
    public init?(_ thermalState: ProcessInfo.ThermalState) {
        switch thermalState {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: return nil
        }
    }

    /// Short, human-readable label for the menu-bar UI. Model-level naming (not
    /// UI styling like colors/icons), kept here so it is pure and testable.
    public var displayName: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    /// UI style *intent* for the Thermal row, expressed as a framework-free token
    /// so the mapping stays pure and unit-testable in the core. `VibeMenuApp`
    /// translates each case into the concrete SwiftUI `Color`/font weight; the core
    /// never imports SwiftUI.
    public var displayStyle: ThermalDisplayStyle {
        switch self {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        }
    }
}

/// Framework-free styling intent for the Thermal row.
///
/// Kept separate from `ThermalPressureState` so the "Unknown" fallback (absent /
/// unmappable pressure) also has a home. The app layer owns the SwiftUI mapping:
/// nominal → green, fair → orange, serious/critical → red (critical bolded),
/// unknown → default text color.
public enum ThermalDisplayStyle: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    /// Absent or unmappable pressure — render with the default text style.
    case unknown
}
