import Foundation
import Observation

// Launch at Login, Settings → General (v0.1).
//
// Same shape as the thermal / power / Claude slices: a small injectable seam
// (`LoginItemControlling`) is republished by a `@MainActor @Observable`
// `LoginItemModel` for the Settings UI, so the decision/state logic is unit-tested
// with a fake controller and the real `SMAppService.mainApp` usage stays out of the
// core (it lives in `VibeMenuApp` — see docs/decisions/0009-launch-at-login.md).
//
// Source of truth: the *actual* login-item status, never a persisted duplicate bool.
// `SMAppService.mainApp.status == .enabled` is the only "ON"; every other status
// (`.notRegistered`, `.notFound`, `.requiresApproval`, future cases) reads as OFF.
// The model reflects that actual status after every operation, so a failed / partial
// register or unregister — common in unsigned/ad-hoc Debug builds — can never leave the
// toggle out of sync with reality.

// MARK: - Controller seam

/// The minimal surface over the system login-item API, isolated so the model's
/// enable/disable/refresh logic can be unit-tested with a fake — without ever touching
/// the real `SMAppService`.
///
/// `isEnabled` reports the *actual* current status (true iff registered/enabled).
/// `register()` / `unregister()` throw on failure; the model catches and re-reads
/// `isEnabled`, so a throw never crashes and never leaves stale state.
public protocol LoginItemControlling: AnyObject {
    /// The actual system status, mapped to a single Bool: `true` iff the app is
    /// currently registered as an enabled login item.
    var isEnabled: Bool { get }

    /// Register the app as a login item. Throws if the system rejects the request.
    func register() throws

    /// Unregister the app as a login item. Throws if the system rejects the request.
    func unregister() throws
}

// MARK: - Observable app model

/// `@MainActor @Observable` surface the Settings UI binds to. Owns no system knowledge
/// itself — it drives a `LoginItemControlling` (injected) and always republishes the
/// controller's *actual* `isEnabled`, never the merely-attempted target state.
///
/// Mirrors the thermal / power slices: the low-level adapter stays out of the observable
/// surface, and tests drive it with a fake controller (enable / disable / failure /
/// external-drift scenarios).
@MainActor
@Observable
public final class LoginItemModel {
    /// Whether the app is currently an enabled login item, as last read from the actual
    /// system status. This is what the Settings toggle displays.
    public private(set) var isEnabled: Bool

    @ObservationIgnored private let controller: LoginItemControlling

    public init(controller: LoginItemControlling) {
        self.controller = controller
        self.isEnabled = controller.isEnabled
    }

    /// Re-read the actual system status. Call when Settings appears so changes made
    /// externally (macOS System Settings → General → Login Items) are reflected.
    /// Idempotent and non-throwing.
    public func refresh() {
        isEnabled = controller.isEnabled
    }

    /// Request the desired login-item state, then reflect the *actual* status.
    ///
    /// On `true` this registers, on `false` it unregisters. If the system call throws
    /// (frequent in unsigned/ad-hoc Debug builds), the error is swallowed — no crash —
    /// and `isEnabled` is refreshed from the controller so the toggle shows what really
    /// happened, not what was attempted. Idempotent enough to call repeatedly.
    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try controller.register()
            } else {
                try controller.unregister()
            }
        } catch {
            // Deliberately swallowed: a failed register/unregister must not crash and
            // must not leave optimistic state. The refresh below reflects reality.
        }
        // Always reflect the actual status — success, no-op, or failure alike.
        isEnabled = controller.isEnabled
    }
}
