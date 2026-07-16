import Foundation

/// Observes the Mac's thermal *pressure* (not exact temperatures) using only
/// public Apple APIs, and reports it as a `ThermalPressureState?`.
///
/// The abstraction exists so the app can depend on a seam that is trivially
/// faked in tests: the real implementation reads `ProcessInfo`, while a test
/// double can feed synthetic values to verify the observable model and mapping
/// without ever forcing the hardware into a thermal state.
///
/// Event-driven by contract: implementations observe change *notifications*;
/// they must not run a timer or polling loop
/// (docs/decisions/0006-lightweight-resource-budget.md).
public protocol ThermalStatusObserving: AnyObject {
    /// The current thermal pressure, or `nil` if it can't be mapped
    /// (surfaced as "Unknown" in the UI).
    var thermalPressure: ThermalPressureState? { get }

    /// Begin observing. `onChange` is invoked once immediately with the current
    /// value, then again on every thermal-state change. Callbacks are delivered
    /// on the main queue. Calling `start` again re-subscribes (idempotent).
    func start(onChange: @escaping @Sendable (ThermalPressureState?) -> Void)

    /// Stop observing and release the notification subscription.
    func stop()
}

/// Real, public-API thermal provider.
///
/// - Current value: `ProcessInfo.processInfo.thermalState`.
/// - Live updates: `ProcessInfo.thermalStateDidChangeNotification`.
///
/// Both are public, documented, sandbox-tolerable, non-root APIs (docs/ARCHITECTURE.md
/// "Public-API preference"); no SMC, no IOReport, no exact °C. The single
/// NotificationCenter subscription is event-driven — zero idle CPU, no timer.
public final class SystemThermalStatusProvider: ThermalStatusObserving {
    private var observerToken: NSObjectProtocol?

    public init() {}

    public var thermalPressure: ThermalPressureState? {
        ThermalPressureState(ProcessInfo.processInfo.thermalState)
    }

    public func start(onChange: @escaping @Sendable (ThermalPressureState?) -> Void) {
        stop()
        // Emit the value present at startup so the UI is correct before any change.
        onChange(ThermalPressureState(ProcessInfo.processInfo.thermalState))
        observerToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            onChange(ThermalPressureState(ProcessInfo.processInfo.thermalState))
        }
    }

    public func stop() {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
            self.observerToken = nil
        }
    }

    deinit { stop() }
}
