import Foundation
import Observation

/// Observable app-state object that feeds the menu-bar UI a live thermal reading.
///
/// It owns no system knowledge itself — it takes a `ThermalStatusObserving` via
/// dependency injection and republishes its values as observable state. That keeps
/// the low-level `ProcessInfo` adapter separate from the observable surface and
/// lets tests drive state changes with a fake provider (no real thermal states
/// required).
///
/// `@MainActor` because it backs SwiftUI; `@Observable` so the `MenuBarExtra`
/// content re-renders when `pressure` changes.
@MainActor
@Observable
public final class ThermalStatusModel {
    /// Current thermal pressure, or `nil` when unmappable / not yet observed.
    public private(set) var pressure: ThermalPressureState?

    @ObservationIgnored private let provider: ThermalStatusObserving

    public init(provider: ThermalStatusObserving) {
        self.provider = provider
        self.pressure = provider.thermalPressure
    }

    /// Start observing thermal-state changes. Idempotent.
    public func start() {
        provider.start { [weak self] newValue in
            // The provider guarantees main-queue delivery, so we are already on
            // the main actor here.
            MainActor.assumeIsolated {
                self?.pressure = newValue
            }
        }
    }

    /// Stop observing.
    public func stop() {
        provider.stop()
    }

    /// UI label: one of Nominal / Fair / Serious / Critical, or "Unknown" when the
    /// value is absent or could not be mapped.
    public var displayLabel: String {
        pressure?.displayName ?? "Unknown"
    }

    /// Framework-free style intent for the Thermal row, mirroring `displayLabel`.
    /// Absent / unmappable pressure maps to `.unknown` (default text styling).
    public var displayStyle: ThermalDisplayStyle {
        pressure?.displayStyle ?? .unknown
    }
}
