import Foundation
import Testing
@testable import VibeMenuCore

// Uses Swift Testing (see AutomationPolicyTests / ThermalStatusTests). The manager's
// idempotency, state, and error handling are exercised against a spy backend, so no
// real system power assertion is ever created in the test process.

/// Spy `PowerAssertionCreating` backend: counts create/release calls, tracks live
/// ids, and can be forced to simulate a failed creation.
private final class SpyAssertionBackend: PowerAssertionCreating {
    private(set) var createCount = 0
    private(set) var releaseCount = 0
    private(set) var liveIDs: Set<UInt32> = []
    var shouldFail = false
    /// When true, `release` reports failure (and leaves the id live), simulating a
    /// non-`kIOReturnSuccess` `IOPMAssertionRelease`.
    var shouldFailRelease = false
    private var nextID: UInt32 = 1

    func create(name: String) -> UInt32? {
        createCount += 1
        if shouldFail { return nil }
        let id = nextID
        nextID += 1
        liveIDs.insert(id)
        return id
    }

    @discardableResult
    func release(_ id: UInt32) -> Bool {
        releaseCount += 1
        if shouldFailRelease { return false }
        liveIDs.remove(id)
        return true
    }
}

@Suite("SystemPowerAssertionManager")
struct PowerAssertionManagerTests {

    @Test func initialStateIsInactive() {
        let backend = SpyAssertionBackend()
        let manager = SystemPowerAssertionManager(backend: backend)
        #expect(manager.state == .inactive)
        #expect(backend.createCount == 0)
    }

    @Test func enablingRequestsOneAssertion() {
        let backend = SpyAssertionBackend()
        let manager = SystemPowerAssertionManager(backend: backend)
        manager.preventIdleSleep()
        #expect(manager.state == .preventingIdleSleep)
        #expect(backend.createCount == 1)
        #expect(backend.liveIDs.count == 1)
    }

    @Test func enablingTwiceDoesNotDuplicate() {
        let backend = SpyAssertionBackend()
        let manager = SystemPowerAssertionManager(backend: backend)
        manager.preventIdleSleep()
        manager.preventIdleSleep()
        #expect(backend.createCount == 1)
        #expect(backend.liveIDs.count == 1)
        #expect(manager.state == .preventingIdleSleep)
    }

    @Test func disablingReleasesTheAssertion() {
        let backend = SpyAssertionBackend()
        let manager = SystemPowerAssertionManager(backend: backend)
        manager.preventIdleSleep()
        manager.allowSleep()
        #expect(manager.state == .inactive)
        #expect(backend.releaseCount == 1)
        #expect(backend.liveIDs.isEmpty)
    }

    @Test func disablingTwiceIsSafe() {
        let backend = SpyAssertionBackend()
        let manager = SystemPowerAssertionManager(backend: backend)
        manager.preventIdleSleep()
        manager.allowSleep()
        manager.allowSleep()
        #expect(manager.state == .inactive)
        #expect(backend.releaseCount == 1) // second disable is a no-op
    }

    @Test func disablingWhenNeverEnabledIsSafe() {
        let backend = SpyAssertionBackend()
        let manager = SystemPowerAssertionManager(backend: backend)
        manager.allowSleep()
        #expect(manager.state == .inactive)
        #expect(backend.releaseCount == 0)
    }

    @Test func failedCreationReportsAcquisitionFailure() {
        let backend = SpyAssertionBackend()
        backend.shouldFail = true
        let manager = SystemPowerAssertionManager(backend: backend)
        manager.preventIdleSleep()
        #expect(manager.state == .acquisitionFailed) // error-safe: no crash, no false "Active"
        #expect(backend.createCount == 1)
        #expect(backend.liveIDs.isEmpty)
    }

    @Test func retryAfterFailureCanSucceed() {
        let backend = SpyAssertionBackend()
        backend.shouldFail = true
        let manager = SystemPowerAssertionManager(backend: backend)
        manager.preventIdleSleep()
        #expect(manager.state == .acquisitionFailed)

        backend.shouldFail = false
        manager.preventIdleSleep()
        #expect(manager.state == .preventingIdleSleep)
        #expect(backend.createCount == 2)
        #expect(backend.liveIDs.count == 1)
    }

    @Test func failedReleaseKeepsAssertionHeld() {
        let backend = SpyAssertionBackend()
        let manager = SystemPowerAssertionManager(backend: backend)
        manager.preventIdleSleep()
        #expect(manager.state == .preventingIdleSleep)

        backend.shouldFailRelease = true
        manager.allowSleep()
        // Release failed: the manager must keep holding the id (state stays active,
        // the spy still counts it live) rather than dropping a live assertion.
        #expect(manager.state == .preventingIdleSleep)
        #expect(backend.releaseCount == 1)
        #expect(backend.liveIDs.count == 1)

        // A later retry, once release succeeds, frees the same assertion.
        backend.shouldFailRelease = false
        manager.allowSleep()
        #expect(manager.state == .inactive)
        #expect(backend.releaseCount == 2)
        #expect(backend.liveIDs.isEmpty)
    }

    @Test func deinitReleasesActiveAssertion() {
        let backend = SpyAssertionBackend()
        do {
            let manager = SystemPowerAssertionManager(backend: backend)
            manager.preventIdleSleep()
            #expect(backend.liveIDs.count == 1)
        }
        // `manager` has no other references, so ARC deallocates it here; its deinit
        // must release the held assertion (cleanup / teardown path).
        #expect(backend.releaseCount == 1)
        #expect(backend.liveIDs.isEmpty)
    }
}

@Suite("PowerAssertionPresentationState")
struct PowerAssertionPresentationStateTests {

    private func presentation(
        _ state: PowerAssertionState,
        manual: Bool = false,
        sources: [AgentKeepAwakeSource] = []
    ) -> PowerAssertionPresentationState {
        PowerAssertionPresentationState(
            assertionState: state,
            manualRequested: manual,
            automationSources: sources
        )
    }

    @Test func inactiveWithNoRequestIsOff() {
        let value = presentation(.inactive)
        #expect(value.text == "Off")
        #expect(value.owners.isEmpty)
    }

    @Test func manualAssertionIsOnWithManualOwner() {
        let value = presentation(.preventingIdleSleep, manual: true)
        #expect(value.text == "On · Manual")
        #expect(value.owners == [.manual])
    }

    @Test func claudeAssertionIsOnWithClaudeOwner() {
        let value = presentation(.preventingIdleSleep, sources: [.claude])
        #expect(value.text == "On · Claude")
        #expect(value.owners == [.claude])
    }

    @Test func codexAssertionIsOnWithCodexOwner() {
        let value = presentation(.preventingIdleSleep, sources: [.codex])
        #expect(value.text == "On · Codex")
        #expect(value.owners == [.codex])
    }

    @Test func bothAutomationSourcesAreRepresented() {
        let value = presentation(.preventingIdleSleep, sources: [.claude, .codex])
        #expect(value.text == "On · Claude and Codex")
        #expect(value.owners == [.claude, .codex])
    }

    @Test func manualAndAutomationOwnersAreAllRepresented() {
        let value = presentation(.preventingIdleSleep, manual: true, sources: [.codex, .claude])
        #expect(value.text == "On · Manual, Claude, and Codex")
        #expect(value.owners == [.manual, .claude, .codex])
    }

    @Test func acquisitionFailureIsNeverOn() {
        let value = presentation(.acquisitionFailed, manual: true, sources: [.claude])
        #expect(value.text == "Couldn’t enable")
        #expect(!value.text.hasPrefix("On"))
        #expect(value.owners == [.manual, .claude])
    }

    @Test func activeWithoutKnownOwnerStillReportsOn() {
        // This is the release-failure presentation: the manager still reports a held
        // assertion after ownership has released, so the UI must not claim "Off".
        let value = presentation(.preventingIdleSleep)
        #expect(value.text == "On")
    }

    @Test func sourceOrderingIsStable() {
        let value = presentation(.preventingIdleSleep, sources: [.codex, .claude])
        #expect(value.owners == [.claude, .codex])
        #expect(value.text == "On · Claude and Codex")
    }

    @Test func releasingOneSourceStillReportsTheOther() {
        let value = presentation(.preventingIdleSleep, sources: [.codex])
        #expect(value.text == "On · Codex")
        #expect(value.text != "Off")
    }
}

/// The observable model reflects and drives the manager. Uses the real manager over a
/// spy backend (still no real system assertion). `@MainActor` because the model is
/// main-actor isolated.
@Suite("PowerAssertionModel", .serialized)
@MainActor
struct PowerAssertionModelTests {

    @Test func startsInactive() {
        let model = PowerAssertionModel(
            manager: SystemPowerAssertionManager(backend: SpyAssertionBackend())
        )
        #expect(!model.isActive)
        #expect(!model.manualRequested)
        #expect(!model.automationRequested)
        #expect(!model.manualToggleIsOn)
        #expect(model.displayLabel == "Inactive")
        #expect(model.statusLabel == "Off")
        #expect(model.activeHoldingSources.isEmpty)
    }

    @Test func toggleEnablesThenDisables() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.toggle()
        #expect(model.isActive)
        #expect(model.manualRequested)
        #expect(model.manualToggleIsOn)
        #expect(model.displayLabel == "Active")
        #expect(model.statusLabel == "On · Manual")
        #expect(backend.createCount == 1)

        model.toggle()
        #expect(!model.isActive)
        #expect(!model.manualRequested)
        #expect(!model.manualToggleIsOn)
        #expect(model.displayLabel == "Inactive")
        #expect(backend.releaseCount == 1)
    }

    @Test func cleanupReleasesActiveAssertion() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))
        model.enable()
        #expect(model.isActive)

        model.cleanup()
        #expect(!model.isActive)
        #expect(backend.releaseCount == 1)
        #expect(backend.liveIDs.isEmpty)
    }

    @Test func failedAcquisitionIsHonestAndNotActive() {
        let backend = SpyAssertionBackend()
        backend.shouldFail = true
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.enable()

        #expect(model.state == .acquisitionFailed)
        #expect(!model.isActive)
        #expect(model.statusLabel == "Couldn’t enable")
    }

    @Test func failedReleaseRemainsActiveInStatus() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))
        model.enable()

        backend.shouldFailRelease = true
        model.disable()

        #expect(model.state == .preventingIdleSleep)
        #expect(model.isActive)
        #expect(model.statusLabel == "On")
        #expect(backend.liveIDs.count == 1)
    }

    @Test func manualOffClaudeActiveMakesEffectiveActive() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeActivity(.active)

        #expect(!model.manualRequested)
        #expect(!model.manualToggleIsOn)
        #expect(model.automationRequested)
        #expect(model.effectiveIsActive)
        #expect(model.isActive)
        #expect(model.activeHoldingSources == [.claude])
        #expect(model.statusLabel == "On · Claude")
        #expect(backend.createCount == 1)
    }

    @Test func manualToggleRemainsInteractiveWhileClaudeHolds() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeAutomation(.hold)
        #expect(!model.manualRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Claude")

        model.setManualRequested(true)
        #expect(model.manualRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Manual and Claude")
        #expect(backend.createCount == 1)

        model.setManualRequested(false)
        #expect(!model.manualRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Claude")
        #expect(backend.releaseCount == 0)
    }

    @Test func manualToggleRemainsInteractiveWhileCodexHolds() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateCodexAutomation(.hold)
        #expect(!model.manualRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Codex")

        model.setManualRequested(true)
        #expect(model.manualRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Manual and Codex")
        #expect(backend.createCount == 1)

        model.setManualRequested(false)
        #expect(!model.manualRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Codex")
        #expect(backend.releaseCount == 0)
    }

    @Test func manualToggleRemainsInteractiveWhileClaudeAndCodexHold() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeAutomation(.hold)
        model.updateCodexAutomation(.hold)
        #expect(!model.manualRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Claude and Codex")

        model.setManualRequested(true)
        #expect(model.manualRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Manual, Claude, and Codex")
        #expect(backend.createCount == 1)

        model.setManualRequested(false)
        #expect(!model.manualRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Claude and Codex")
        #expect(backend.releaseCount == 0)
    }

    @Test func manualOffClaudeIdleMakesEffectiveInactiveImmediately() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeActivity(.active)
        model.updateClaudeActivity(.idle)

        #expect(!model.manualRequested)
        #expect(!model.automationRequested)
        #expect(!model.effectiveIsActive)
        #expect(!model.isActive)
        #expect(backend.releaseCount == 1)
    }

    @Test func manualOnClaudeActiveKeepsEffectiveActive() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.enable()
        model.updateClaudeActivity(.active)

        #expect(model.manualRequested)
        #expect(model.manualToggleIsOn)
        #expect(model.automationRequested)
        #expect(model.effectiveIsActive)
        #expect(model.isActive)
        #expect(backend.createCount == 1)
    }

    @Test func manualOnClaudeIdleKeepsEffectiveActive() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.enable()
        model.updateClaudeActivity(.active)
        model.updateClaudeActivity(.notDetected)

        #expect(model.manualRequested)
        #expect(!model.automationRequested)
        #expect(model.effectiveIsActive)
        #expect(model.isActive)
        #expect(backend.releaseCount == 0)
    }

    @Test func automationDoesNotMutateManualPreference() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeActivity(.active)
        #expect(!model.manualRequested)
        #expect(!model.manualToggleIsOn)

        model.updateClaudeActivity(.waiting)
        #expect(!model.manualRequested)
        #expect(!model.manualToggleIsOn)

        model.enable()
        model.updateClaudeActivity(.active)
        model.updateClaudeActivity(.running)
        #expect(model.manualRequested)
        #expect(model.manualToggleIsOn)
    }

    @Test func activeToIdleReleasesAssertion() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeActivity(.active)

        model.updateClaudeActivity(.idle)
        #expect(!model.automationRequested)
        #expect(!model.effectiveIsActive)
        #expect(!model.isActive)
        #expect(backend.releaseCount == 1)
    }

    @Test func repeatedStateUpdatesAreIdempotent() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeActivity(.active)
        model.updateClaudeActivity(.active)
        #expect(backend.createCount == 1)
        #expect(model.isActive)

        model.updateClaudeActivity(.idle)
        model.updateClaudeActivity(.idle)
        #expect(backend.releaseCount == 1)
        #expect(!model.isActive)

        model.updateClaudeActivity(.notDetected)
        #expect(backend.releaseCount == 1)
    }

    @Test func cleanupReleasesAutomationAssertionOnTermination() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeActivity(.active)
        #expect(model.isActive)

        model.cleanup()
        #expect(!model.manualRequested)
        #expect(!model.automationRequested)
        #expect(!model.isActive)
        #expect(backend.releaseCount == 1)
        #expect(backend.liveIDs.isEmpty)
    }

    // MARK: - Intent-driven automation (v0.1.1, docs/decisions/0010)

    /// A `.hold` intent (manual off) makes the effective assertion active while leaving the
    /// manual preference independent.
    @Test func automationHoldMakesEffectiveActive() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeAutomation(.hold)
        #expect(!model.manualRequested)
        #expect(model.automationRequested)
        #expect(model.effectiveIsActive)
        #expect(model.isActive)
        #expect(backend.createCount == 1)
    }

    /// A `.release` intent (manual off) makes the effective assertion inactive.
    @Test func automationReleaseMakesEffectiveInactive() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeAutomation(.hold)
        model.updateClaudeAutomation(.release)
        #expect(!model.automationRequested)
        #expect(!model.effectiveIsActive)
        #expect(!model.isActive)
        #expect(backend.releaseCount == 1)
    }

    /// **Manual keep-awake always wins.** With the manual switch on, an automation
    /// `.release` must keep the assertion held — the effective request stays
    /// `manualRequested || automationRequested`.
    @Test func manualOnKeepsAssertionHeldAfterAutomationReleases() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.enable()                          // manual on
        model.updateClaudeAutomation(.hold)     // automation also holds
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Manual and Claude")

        model.updateClaudeAutomation(.release)  // automation releases…
        #expect(model.manualRequested)          // …manual preference untouched…
        #expect(!model.automationRequested)
        #expect(model.effectiveIsActive)        // …and the assertion stays held.
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Manual")
        #expect(backend.releaseCount == 0)      // never actually released the IOKit assertion
    }

    @Test func releaseOccursOnlyAfterFinalOwnerReleases() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.enable()
        model.updateClaudeAutomation(.hold)
        model.updateCodexAutomation(.hold)
        #expect(backend.createCount == 1)

        model.disable()
        #expect(!model.manualRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Claude and Codex")
        #expect(backend.releaseCount == 0)

        model.updateClaudeAutomation(.release)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Codex")
        #expect(backend.releaseCount == 0)

        model.updateCodexAutomation(.release)
        #expect(!model.isActive)
        #expect(model.statusLabel == "Off")
        #expect(backend.releaseCount == 1)
    }

    /// **Automation expiry never mutates `manualRequested`.** A hold→release cycle (the
    /// quiet-hold cap elapsing) must leave the user's manual preference exactly as it was,
    /// whether off or on.
    @Test func automationExpiryNeverMutatesManualPreference() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        // Manual off throughout.
        model.updateClaudeAutomation(.hold)
        #expect(!model.manualRequested)
        model.updateClaudeAutomation(.release)   // cap elapsed
        #expect(!model.manualRequested)
        #expect(!model.manualToggleIsOn)

        // Manual on throughout.
        model.enable()
        model.updateClaudeAutomation(.hold)
        model.updateClaudeAutomation(.release)   // cap elapsed again
        #expect(model.manualRequested)
        #expect(model.manualToggleIsOn)
    }

    /// Cleanup (app teardown) drops the automation hold and releases the assertion. The
    /// provider owns the only detection timer and cancels it in `stop()`; the model's job on
    /// teardown is to release — there is no per-release timer in the model to leak.
    @Test func cleanupReleasesAutomationHold() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeAutomation(.hold)
        #expect(model.isActive)

        model.cleanup()
        #expect(!model.automationRequested)
        #expect(!model.isActive)
        #expect(backend.releaseCount == 1)
        #expect(backend.liveIDs.isEmpty)
    }

    /// Repeated identical intents are idempotent (no duplicate IOKit create/release).
    @Test func repeatedIntentsAreIdempotent() {
        let backend = SpyAssertionBackend()
        let model = PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend))

        model.updateClaudeAutomation(.hold)
        model.updateClaudeAutomation(.hold)
        #expect(backend.createCount == 1)

        model.updateClaudeAutomation(.release)
        model.updateClaudeAutomation(.release)
        #expect(backend.releaseCount == 1)
    }
}
