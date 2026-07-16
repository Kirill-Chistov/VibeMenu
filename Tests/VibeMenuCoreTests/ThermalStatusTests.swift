import Foundation
import Testing
@testable import VibeMenuCore

// Uses Swift Testing (see AutomationPolicyTests). These tests exercise the thermal
// slice with no dependency on the host Mac's real thermal state: the mapping is a
// pure function over `ProcessInfo.ThermalState`, and the observable model is driven
// by a fake provider.

/// Mapping `ProcessInfo.ThermalState` → `ThermalPressureState`.
@Suite("ThermalPressureState mapping")
struct ThermalPressureMappingTests {

    @Test func nominalMapsToNominal() {
        #expect(ThermalPressureState(.nominal) == .nominal)
    }

    @Test func fairMapsToFair() {
        #expect(ThermalPressureState(.fair) == .fair)
    }

    @Test func seriousMapsToSerious() {
        #expect(ThermalPressureState(.serious) == .serious)
    }

    @Test func criticalMapsToCritical() {
        #expect(ThermalPressureState(.critical) == .critical)
    }
}

/// Display labels used by the menu-bar UI.
@Suite("ThermalPressureState display labels")
struct ThermalDisplayLabelTests {

    @Test func labelsMatchSpec() {
        #expect(ThermalPressureState.nominal.displayName == "Nominal")
        #expect(ThermalPressureState.fair.displayName == "Fair")
        #expect(ThermalPressureState.serious.displayName == "Serious")
        #expect(ThermalPressureState.critical.displayName == "Critical")
    }
}

/// Framework-free style intent used by the Thermal row. The concrete SwiftUI
/// `Color`/weight mapping lives in `VibeMenuApp`; here we only pin the pure tokens.
@Suite("ThermalPressureState display style")
struct ThermalDisplayStyleTests {

    @Test func styleMatchesPressure() {
        #expect(ThermalPressureState.nominal.displayStyle == .nominal)
        #expect(ThermalPressureState.fair.displayStyle == .fair)
        #expect(ThermalPressureState.serious.displayStyle == .serious)
        #expect(ThermalPressureState.critical.displayStyle == .critical)
    }
}

/// A fake provider so model/state-update behavior is testable without touching the
/// real hardware thermal state.
private final class FakeThermalProvider: ThermalStatusObserving {
    var thermalPressure: ThermalPressureState?
    private var onChange: (@Sendable (ThermalPressureState?) -> Void)?

    init(initial: ThermalPressureState?) {
        self.thermalPressure = initial
    }

    func start(onChange: @escaping @Sendable (ThermalPressureState?) -> Void) {
        self.onChange = onChange
        onChange(thermalPressure)
    }

    func stop() {
        onChange = nil
    }

    /// Simulate a thermal-state change notification.
    func emit(_ value: ThermalPressureState?) {
        thermalPressure = value
        onChange?(value)
    }
}

/// The observable model reflects the provider's value and updates on change. Marked
/// `@MainActor` because `ThermalStatusModel` is main-actor isolated.
@Suite("ThermalStatusModel", .serialized)
@MainActor
struct ThermalStatusModelTests {

    @Test func exposesInitialValueFromProvider() {
        let model = ThermalStatusModel(provider: FakeThermalProvider(initial: .fair))
        #expect(model.pressure == .fair)
        #expect(model.displayLabel == "Fair")
    }

    @Test func updatesWhenProviderEmitsChange() {
        let provider = FakeThermalProvider(initial: .nominal)
        let model = ThermalStatusModel(provider: provider)
        model.start()
        #expect(model.pressure == .nominal)

        provider.emit(.serious)
        #expect(model.pressure == .serious)
        #expect(model.displayLabel == "Serious")
    }

    @Test func nilPressureShowsUnknown() {
        let provider = FakeThermalProvider(initial: nil)
        let model = ThermalStatusModel(provider: provider)
        #expect(model.pressure == nil)
        #expect(model.displayLabel == "Unknown")

        model.start()
        provider.emit(.critical)
        #expect(model.displayLabel == "Critical")

        provider.emit(nil)
        #expect(model.displayLabel == "Unknown")
    }

    @Test func displayStyleMirrorsPressureWithUnknownFallback() {
        let provider = FakeThermalProvider(initial: nil)
        let model = ThermalStatusModel(provider: provider)
        #expect(model.displayStyle == .unknown)

        model.start()
        provider.emit(.nominal)
        #expect(model.displayStyle == .nominal)

        provider.emit(.critical)
        #expect(model.displayStyle == .critical)

        provider.emit(nil)
        #expect(model.displayStyle == .unknown)
    }
}
