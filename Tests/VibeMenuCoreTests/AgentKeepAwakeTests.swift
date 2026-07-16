import Foundation
import Testing
@testable import VibeMenuCore

// Tests for the shared, provider-neutral keep-awake decision (docs/decisions/0017, Fix 1): Codex
// session activity now feeds the *same* sleep-prevention loop as Claude, and Claude + Codex hold the
// single assertion independently. Pure `CodexSessionActivity` mapping + the set-based `PowerAssertionModel`.

// MARK: - Pure Codex activity → intent

@Suite("CodexSessionActivity.automationIntent")
struct CodexSessionActivityTests {

    private func session(_ id: String, _ state: CodexSessionState) -> CodexSession {
        let now = Date()
        return CodexSession(
            id: id, state: state, folderName: "proj",
            startedAt: now.addingTimeInterval(-120), lastActivity: now.addingTimeInterval(-5)
        )
    }

    @Test("An active Codex session holds")
    func activeHolds() {
        #expect(CodexSessionActivity.automationIntent([session("x", .active)]) == .hold)
    }

    @Test("Done / idle / stale / unknown never hold (conservative)")
    func nonActiveReleases() {
        #expect(CodexSessionActivity.automationIntent([session("x", .idle)]) == .release)
        #expect(CodexSessionActivity.automationIntent([session("x", .done)]) == .release)
        #expect(CodexSessionActivity.automationIntent([session("x", .stale)]) == .release)
        #expect(CodexSessionActivity.automationIntent([session("x", .unknown)]) == .release)
    }

    @Test("Empty list (disabled / missing / stale data) releases")
    func emptyReleases() {
        #expect(CodexSessionActivity.automationIntent([]) == .release)
    }

    @Test("Any one active session among finished ones holds")
    func mixHolds() {
        let sessions = [session("a", .done), session("b", .active), session("c", .stale)]
        #expect(CodexSessionActivity.automationIntent(sessions) == .hold)
    }

    @Test("Only done/stale sessions do not hold")
    func onlyFinishedReleases() {
        let sessions = [session("a", .done), session("b", .stale)]
        #expect(CodexSessionActivity.automationIntent(sessions) == .release)
    }
}

// MARK: - Shared model: Claude + Codex feed the same assertion

@Suite("PowerAssertionModel — shared agent activity", .serialized)
@MainActor
struct SharedAgentAutomationTests {

    private final class SpyBackend: PowerAssertionCreating {
        private(set) var createCount = 0
        private(set) var releaseCount = 0
        private(set) var liveIDs: Set<UInt32> = []
        private var nextID: UInt32 = 1
        func create(name: String) -> UInt32? {
            createCount += 1; let id = nextID; nextID += 1; liveIDs.insert(id); return id
        }
        @discardableResult func release(_ id: UInt32) -> Bool { releaseCount += 1; liveIDs.remove(id); return true }
    }

    private func makeModel() -> (PowerAssertionModel, SpyBackend) {
        let backend = SpyBackend()
        return (PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend)), backend)
    }

    @Test("Claude active still prevents sleep, exactly as before")
    func claudeStillHolds() {
        let (model, backend) = makeModel()
        model.updateClaudeAutomation(.hold)
        #expect(model.automationRequested)
        #expect(model.isActive)
        #expect(backend.createCount == 1)

        model.updateClaudeAutomation(.release)
        #expect(!model.automationRequested)
        #expect(!model.isActive)
        #expect(backend.releaseCount == 1)
    }

    @Test("Codex active can prevent sleep on its own")
    func codexHolds() {
        let (model, backend) = makeModel()
        model.updateCodexAutomation(.hold)
        #expect(model.automationRequested)
        #expect(model.isActive)
        #expect(backend.createCount == 1)
    }

    @Test("Codex done/stale (release) does not prevent sleep")
    func codexReleaseDoesNotHold() {
        let (model, backend) = makeModel()
        model.updateCodexAutomation(.release)
        #expect(!model.automationRequested)
        #expect(!model.isActive)
        #expect(backend.createCount == 0)
    }

    @Test("Codex disabled (release intent) never holds; only Claude drives the assertion")
    func codexDisabledDoesNotAffect() {
        let (model, backend) = makeModel()
        // Codex feature off ⇒ empty list ⇒ .release fed in; Claude working.
        model.updateCodexAutomation(.release)
        model.updateClaudeAutomation(.hold)
        #expect(model.isActive)
        // Codex releasing again must not drop the assertion Claude is holding.
        model.updateCodexAutomation(.release)
        #expect(model.isActive)
        #expect(backend.releaseCount == 0)
    }

    @Test("Claude + Codex combined: assertion held until BOTH release")
    func combinedHoldsUntilBothRelease() {
        let (model, backend) = makeModel()
        model.updateClaudeAutomation(.hold)
        model.updateCodexAutomation(.hold)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Claude and Codex")
        #expect(backend.createCount == 1)   // one shared assertion, not two

        // Claude finishes but Codex is still working → stays held, no release yet.
        model.updateClaudeAutomation(.release)
        #expect(model.automationRequested)
        #expect(model.isActive)
        #expect(model.activeHoldingSources == [.codex])
        #expect(model.statusLabel == "On · Codex")
        #expect(backend.releaseCount == 0)

        // Codex finishes too → now it releases.
        model.updateCodexAutomation(.release)
        #expect(!model.automationRequested)
        #expect(!model.isActive)
        #expect(backend.releaseCount == 1)
    }

    @Test("Manual keep-awake still wins over both agents releasing")
    func manualWins() {
        let (model, backend) = makeModel()
        model.enable()                       // manual on
        model.updateClaudeAutomation(.hold)
        model.updateCodexAutomation(.hold)
        #expect(model.isActive)

        model.updateClaudeAutomation(.release)
        model.updateCodexAutomation(.release)
        #expect(model.manualRequested)       // manual untouched
        #expect(!model.automationRequested)
        #expect(model.effectiveIsActive)     // still held by manual
        #expect(model.isActive)
        #expect(backend.releaseCount == 0)   // never actually released
    }

    @Test("Codex usage limits never touch sleep prevention (only session activity feeds it)")
    func usageLimitsNeverAffectSleep() {
        // There is no API by which Codex *usage limits* can request a hold: the only Codex entry point
        // is `updateCodexAutomation`, which the app drives solely from `CodexSessionActivity` over the
        // session list — never from the usage-limit model. This test documents that invariant: with no
        // agent hold requested, the assertion is inactive regardless of any usage-limit state.
        let (model, backend) = makeModel()
        #expect(!model.automationRequested)
        #expect(!model.isActive)
        #expect(backend.createCount == 0)
    }

    @Test("Repeated Codex holds are idempotent (one shared assertion)")
    func codexIdempotent() {
        let (model, backend) = makeModel()
        model.updateCodexAutomation(.hold)
        model.updateCodexAutomation(.hold)
        #expect(backend.createCount == 1)
        model.updateCodexAutomation(.release)
        model.updateCodexAutomation(.release)
        #expect(backend.releaseCount == 1)
    }

    @Test("cleanup clears every agent hold and releases")
    func cleanupClearsAll() {
        let (model, backend) = makeModel()
        model.updateClaudeAutomation(.hold)
        model.updateCodexAutomation(.hold)
        #expect(model.isActive)

        model.cleanup()
        #expect(!model.automationRequested)
        #expect(!model.isActive)
        #expect(backend.releaseCount == 1)
        #expect(backend.liveIDs.isEmpty)
    }
}
