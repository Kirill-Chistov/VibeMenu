import Foundation
import Testing
@testable import VibeMenuCore

// Uses Swift Testing (see PowerAssertionTests / ThermalStatusTests). The model's
// enable / disable / failure / external-drift behavior is exercised against a fake
// controller, so no real `SMAppService` login item is ever registered by the tests.

private enum FakeLoginItemError: Error { case failed }

/// Fake `LoginItemControlling`: models an actual status flag plus optional failures for
/// register/unregister. A *failing* operation is configurable to leave the status
/// unchanged (drift scenarios) — mirroring an unsigned/ad-hoc Debug build where the call
/// throws and the real status does not move.
private final class FakeLoginItemController: LoginItemControlling {
    var isEnabled: Bool
    var registerShouldThrow = false
    var unregisterShouldThrow = false
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func register() throws {
        registerCount += 1
        if registerShouldThrow { throw FakeLoginItemError.failed }
        isEnabled = true
    }

    func unregister() throws {
        unregisterCount += 1
        if unregisterShouldThrow { throw FakeLoginItemError.failed }
        isEnabled = false
    }
}

@Suite("LoginItemModel", .serialized)
@MainActor
struct LoginItemModelTests {

    // 1. Initial refresh reflects enabled.
    @Test func initialStatusReflectsEnabled() {
        let model = LoginItemModel(controller: FakeLoginItemController(isEnabled: true))
        #expect(model.isEnabled)
    }

    // 2. Initial refresh reflects disabled / non-enabled.
    @Test func initialStatusReflectsDisabled() {
        let model = LoginItemModel(controller: FakeLoginItemController(isEnabled: false))
        #expect(!model.isEnabled)
    }

    // 3. Toggle on calls register and reflects enabled.
    @Test func enableRegistersAndReflectsEnabled() {
        let controller = FakeLoginItemController(isEnabled: false)
        let model = LoginItemModel(controller: controller)

        model.setEnabled(true)

        #expect(model.isEnabled)
        #expect(controller.registerCount == 1)
        #expect(controller.unregisterCount == 0)
    }

    // 4. Toggle off calls unregister and reflects disabled.
    @Test func disableUnregistersAndReflectsDisabled() {
        let controller = FakeLoginItemController(isEnabled: true)
        let model = LoginItemModel(controller: controller)

        model.setEnabled(false)

        #expect(!model.isEnabled)
        #expect(controller.unregisterCount == 1)
        #expect(controller.registerCount == 0)
    }

    // 5. Failed register does not leave model enabled if actual status is disabled.
    @Test func failedRegisterDoesNotFalselyEnable() {
        let controller = FakeLoginItemController(isEnabled: false)
        controller.registerShouldThrow = true
        let model = LoginItemModel(controller: controller)

        model.setEnabled(true) // throws internally; must not crash

        #expect(!model.isEnabled) // reflects actual disabled status, not the attempt
        #expect(controller.registerCount == 1)
    }

    // 6. Failed unregister does not leave model disabled if actual status is still enabled.
    @Test func failedUnregisterDoesNotFalselyDisable() {
        let controller = FakeLoginItemController(isEnabled: true)
        controller.unregisterShouldThrow = true
        let model = LoginItemModel(controller: controller)

        model.setEnabled(false) // throws internally; must not crash

        #expect(model.isEnabled) // reflects actual still-enabled status, not the attempt
        #expect(controller.unregisterCount == 1)
    }

    // 7. External System Settings change is reflected on refresh.
    @Test func externalChangeReflectedOnRefresh() {
        let controller = FakeLoginItemController(isEnabled: false)
        let model = LoginItemModel(controller: controller)
        #expect(!model.isEnabled)

        // Simulate the user enabling the login item in macOS System Settings while
        // VibeMenu was running: actual status flips underneath the model.
        controller.isEnabled = true
        model.refresh()
        #expect(model.isEnabled)

        // And the reverse: disabled externally.
        controller.isEnabled = false
        model.refresh()
        #expect(!model.isEnabled)
    }

    // 8. Repeated refresh/toggle operations are idempotent enough and do not crash.
    @Test func repeatedOperationsAreIdempotentAndSafe() {
        let controller = FakeLoginItemController(isEnabled: false)
        let model = LoginItemModel(controller: controller)

        model.setEnabled(true)
        model.setEnabled(true)
        #expect(model.isEnabled)

        model.refresh()
        model.refresh()
        #expect(model.isEnabled)

        model.setEnabled(false)
        model.setEnabled(false)
        #expect(!model.isEnabled)
        #expect(!model.isEnabled)

        // A late external drift + refresh still tracks reality, no crash.
        controller.isEnabled = true
        model.refresh()
        #expect(model.isEnabled)
    }
}
