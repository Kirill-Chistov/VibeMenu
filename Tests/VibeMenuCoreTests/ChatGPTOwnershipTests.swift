import Foundation
import Testing
@testable import VibeMenuCore

// Final pre-release naming + sleep-prevention ownership for the unified ChatGPT desktop app
// (docs/decisions/0017-codex-session-support.md, Amendment 6).
//
// Two things are proved here:
//
//   1. **ChatGPT Work and Codex are independent keep-awake owners.** They are derived from the same
//      raw session list but reach `PowerAssertionModel` as separate sources, so one mode finishing can
//      never release an assertion the other still needs — while still creating exactly **one** shared
//      IOKit assertion. Manual ownership stays independent and still wins.
//   2. **The final user-visible naming.** The session pill says `ChatGPT Work`, the limits section says
//      `ChatGPT limits`, Settings says `ChatGPT` / `Track ChatGPT sessions`, the source stays
//      `ChatGPT (Work + Codex)`, and neither limits section carries an `Experimental` badge — without
//      losing any of the truthful source/privacy/freshness/shared-allowance copy.
//
// Pure values and a spy backend only — no real power assertion is ever created.

// MARK: - Session pills

@Suite("Session Radar pills — ChatGPT Work / Codex")
struct ChatGPTSessionPillTests {

    private func session(_ mode: CodexSessionMode) -> CodexSession {
        let now = Date()
        return CodexSession(
            id: "s-\(mode.rawValue)", state: .active, folderName: "proj",
            startedAt: now.addingTimeInterval(-60), lastActivity: now, mode: mode
        )
    }

    @Test("A Work-mode row's pill spells out ChatGPT Work, never a bare `Work`")
    func workPill() {
        #expect(CodexSessionMode.work.label == "ChatGPT Work")
        #expect(session(.work).agent == "ChatGPT Work")
    }

    @Test("A Codex-mode row's pill stays Codex")
    func codexPill() {
        #expect(CodexSessionMode.codex.label == "Codex")
        #expect(session(.codex).agent == "Codex")
    }

    @Test("The pill is still derived, never a raw originator")
    func pillCarriesNoOriginator() {
        for mode in CodexSessionMode.allCases {
            #expect(!mode.label.contains("_desktop"))
            #expect(!mode.label.lowercased().contains("originator"))
        }
    }
}

// MARK: - Independent ChatGPT Work / Codex ownership

@Suite("PowerAssertionModel — ChatGPT Work and Codex hold independently", .serialized)
@MainActor
struct ChatGPTWorkOwnershipTests {

    private final class SpyBackend: PowerAssertionCreating {
        private(set) var createCount = 0
        private(set) var releaseCount = 0
        private(set) var liveIDs: Set<UInt32> = []
        private var nextID: UInt32 = 1
        func create(name: String) -> UInt32? {
            createCount += 1; let id = nextID; nextID += 1; liveIDs.insert(id); return id
        }
        @discardableResult func release(_ id: UInt32) -> Bool {
            releaseCount += 1; liveIDs.remove(id); return true
        }
    }

    private func makeModel() -> (PowerAssertionModel, SpyBackend) {
        let backend = SpyBackend()
        return (PowerAssertionModel(manager: SystemPowerAssertionManager(backend: backend)), backend)
    }

    /// A session list as the reader would publish it, so the tests exercise the real
    /// list → per-mode intent → owner path the app wires up.
    private func sessions(work: CodexSessionState?, codex: CodexSessionState?) -> [CodexSession] {
        let now = Date()
        var list: [CodexSession] = []
        if let work {
            list.append(CodexSession(id: "s-work", state: work, folderName: "W",
                                     startedAt: now.addingTimeInterval(-60), lastActivity: now,
                                     mode: .work))
        }
        if let codex {
            list.append(CodexSession(id: "s-codex", state: codex, folderName: "C",
                                     startedAt: now.addingTimeInterval(-60), lastActivity: now,
                                     mode: .codex))
        }
        return list
    }

    /// Exactly what `AppDelegate` does on every session update: refresh **both** intents from the same
    /// raw list, each scoped to its own mode.
    private func apply(_ model: PowerAssertionModel, _ list: [CodexSession]) {
        model.updateCodexAutomation(CodexSessionActivity.automationIntent(list, mode: .codex))
        model.updateChatGPTWorkAutomation(CodexSessionActivity.automationIntent(list, mode: .work))
    }

    @Test("Work-only activity holds only the ChatGPT Work owner")
    func workOnlyHoldsWork() {
        let (model, backend) = makeModel()
        apply(model, sessions(work: .active, codex: .done))

        #expect(model.isActive)
        #expect(model.activeHoldingSources == [.chatGPTWork])
        #expect(model.statusPresentation.owners == [.chatGPTWork])
        #expect(model.statusLabel == "On · ChatGPT Work")
        #expect(backend.createCount == 1)
    }

    @Test("Codex-only activity holds only the Codex owner")
    func codexOnlyHoldsCodex() {
        let (model, backend) = makeModel()
        apply(model, sessions(work: .done, codex: .active))

        #expect(model.isActive)
        #expect(model.activeHoldingSources == [.codex])
        #expect(model.statusPresentation.owners == [.codex])
        #expect(model.statusLabel == "On · Codex")
        #expect(backend.createCount == 1)
    }

    @Test("Work + Codex shows both owners while creating one shared assertion")
    func bothOwnersOneAssertion() {
        let (model, backend) = makeModel()
        apply(model, sessions(work: .active, codex: .active))

        #expect(model.activeHoldingSources == [.codex, .chatGPTWork])
        #expect(model.statusLabel == "On · Codex and ChatGPT Work")
        #expect(backend.createCount == 1)     // one assertion, not one per owner
        #expect(backend.liveIDs.count == 1)
    }

    @Test("Work finishing while Codex is still active keeps the assertion")
    func workFinishingKeepsCodexHold() {
        let (model, backend) = makeModel()
        apply(model, sessions(work: .active, codex: .active))
        #expect(backend.createCount == 1)

        apply(model, sessions(work: .done, codex: .active))
        #expect(model.isActive)
        #expect(model.automationRequested)
        #expect(model.activeHoldingSources == [.codex])
        #expect(model.statusLabel == "On · Codex")
        #expect(backend.releaseCount == 0)    // Work's release never touched Codex's hold
    }

    @Test("Codex finishing while Work is still active keeps the assertion")
    func codexFinishingKeepsWorkHold() {
        let (model, backend) = makeModel()
        apply(model, sessions(work: .active, codex: .active))

        apply(model, sessions(work: .active, codex: .done))
        #expect(model.isActive)
        #expect(model.automationRequested)
        #expect(model.activeHoldingSources == [.chatGPTWork])
        #expect(model.statusLabel == "On · ChatGPT Work")
        #expect(backend.releaseCount == 0)
    }

    @Test("The assertion releases only after both modes finish")
    func releasesOnlyAfterBothFinish() {
        let (model, backend) = makeModel()
        apply(model, sessions(work: .active, codex: .active))

        apply(model, sessions(work: .idle, codex: .active))
        #expect(model.isActive)
        #expect(backend.releaseCount == 0)

        apply(model, sessions(work: .idle, codex: .stale))
        #expect(!model.isActive)
        #expect(!model.automationRequested)
        #expect(model.activeHoldingSources.isEmpty)
        #expect(model.statusLabel == "Off")
        #expect(backend.releaseCount == 1)
        #expect(backend.liveIDs.isEmpty)
    }

    @Test("Claude + Codex + Work reads `On · Claude, Codex, and ChatGPT Work`")
    func threeAgentOrdering() {
        let (model, backend) = makeModel()
        model.updateClaudeAutomation(.hold)
        apply(model, sessions(work: .active, codex: .active))

        #expect(model.activeHoldingSources == [.claude, .codex, .chatGPTWork])
        #expect(model.statusPresentation.owners == [.claude, .codex, .chatGPTWork])
        #expect(model.statusLabel == "On · Claude, Codex, and ChatGPT Work")
        #expect(backend.createCount == 1)
    }

    @Test("Manual stays first and independent with all three agents holding")
    func manualFirstAndIndependent() {
        let (model, backend) = makeModel()
        apply(model, sessions(work: .active, codex: .active))
        model.updateClaudeAutomation(.hold)

        model.setManualRequested(true)
        #expect(model.statusPresentation.owners == [.manual, .claude, .codex, .chatGPTWork])
        #expect(model.statusLabel == "On · Manual, Claude, Codex, and ChatGPT Work")
        #expect(backend.createCount == 1)

        // Turning manual off changes only manual ownership; the agents keep holding.
        model.setManualRequested(false)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Claude, Codex, and ChatGPT Work")
        #expect(backend.releaseCount == 0)

        // …and with manual back on, every agent releasing cannot drop the user's own hold.
        model.setManualRequested(true)
        model.updateClaudeAutomation(.release)
        apply(model, sessions(work: .done, codex: .done))
        #expect(model.manualRequested)
        #expect(!model.automationRequested)
        #expect(model.isActive)
        #expect(model.statusLabel == "On · Manual")
        #expect(backend.releaseCount == 0)
    }

    @Test("The owner order is stable regardless of which source held first")
    func ownerOrderIsStable() {
        let (model, _) = makeModel()
        // Work first, then Codex, then Claude — the reverse of the presentation order.
        model.updateChatGPTWorkAutomation(.hold)
        model.updateCodexAutomation(.hold)
        model.updateClaudeAutomation(.hold)
        #expect(model.statusLabel == "On · Claude, Codex, and ChatGPT Work")

        // And the pure presentation type sorts a shuffled source list the same way.
        let presentation = PowerAssertionPresentationState(
            assertionState: .preventingIdleSleep,
            manualRequested: true,
            automationSources: [.chatGPTWork, .claude, .codex]
        )
        #expect(presentation.owners == [.manual, .claude, .codex, .chatGPTWork])
        #expect(presentation.text == "On · Manual, Claude, Codex, and ChatGPT Work")
    }

    @Test("cleanup clears every owner, including ChatGPT Work")
    func cleanupClearsEveryOwner() {
        let (model, backend) = makeModel()
        model.updateClaudeAutomation(.hold)
        apply(model, sessions(work: .active, codex: .active))
        #expect(model.activeHoldingSources.count == 3)

        model.cleanup()
        #expect(!model.automationRequested)
        #expect(!model.isActive)
        #expect(model.activeHoldingSources.isEmpty)
        #expect(model.statusLabel == "Off")
        #expect(backend.releaseCount == 1)
        #expect(backend.liveIDs.isEmpty)
    }

    @Test("Disabled tracking publishes an empty list ⇒ neither mode can hold")
    func disabledTrackingHoldsNothing() {
        let (model, backend) = makeModel()
        apply(model, [])
        #expect(!model.automationRequested)
        #expect(!model.isActive)
        #expect(backend.createCount == 0)
    }

    @Test("Usage-limit state still cannot affect sleep prevention")
    func usageLimitsCannotHold() {
        // There is no API by which a usage-limit reading can request a hold: the only ChatGPT entry
        // points are `updateCodexAutomation` / `updateChatGPTWorkAutomation`, and the app drives both
        // solely from `CodexSessionActivity` over the *session* list. A fresh, fully-populated usage
        // snapshot therefore leaves the assertion inactive.
        let (model, backend) = makeModel()
        let now = Date()
        let snapshot = CodexUsageLimitSnapshot(
            limits: [
                CodexUsageLimit(windowMinutes: 300, usedPercent: 91, resetsAt: now, slot: "primary"),
                CodexUsageLimit(windowMinutes: 10080, usedPercent: 99, resetsAt: now, slot: "secondary"),
            ],
            capturedAt: now,
            source: .rollout
        )
        #expect(snapshot.hasData)

        #expect(!model.automationRequested)
        #expect(!model.isActive)
        #expect(model.activeHoldingSources.isEmpty)
        #expect(backend.createCount == 0)

        // Even while both modes are genuinely working, ownership comes from sessions alone.
        apply(model, sessions(work: .active, codex: .active))
        #expect(model.activeHoldingSources == [.codex, .chatGPTWork])
    }
}

// MARK: - Final user-visible naming

@Suite("ChatGPT naming and the removed Experimental classification")
struct ChatGPTNamingTests {

    /// The app source, located relative to this test file so the check is CWD-independent. The menu
    /// and Settings literals live in SwiftUI views that `VibeMenuCore` tests cannot instantiate, so
    /// the copy that is *not* owned by a core constant is guarded at the source level instead.
    private var appSource: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/VibeMenuCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/VibeMenuApp/VibeMenuApp.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("The limits section header is `ChatGPT limits`")
    func limitsHeader() {
        #expect(CodexUsageLimitsMenuCopy.sectionTitle == "ChatGPT limits")
        // The view renders the constant, so the header can never drift from what is tested here.
        #expect(appSource.contains("Text(CodexUsageLimitsMenuCopy.sectionTitle)"))
        #expect(!appSource.contains("\"OpenAI limits\""))
    }

    @Test("Settings uses `ChatGPT` and `Track ChatGPT sessions`")
    func settingsNaming() {
        #expect(CodexUsageLimitsMenuCopy.settingsGroupTitle == "ChatGPT")
        #expect(CodexUsageLimitsMenuCopy.settingsTrackSessionsTitle == "Track ChatGPT sessions")
        #expect(appSource.contains("Text(CodexUsageLimitsMenuCopy.settingsGroupTitle)"))
        #expect(appSource.contains("CodexUsageLimitsMenuCopy.settingsTrackSessionsTitle"))
        #expect(!appSource.contains("\"Track OpenAI sessions\""))
        #expect(!appSource.contains("Text(\"OpenAI\")"))
    }

    @Test("The source wording stays `ChatGPT (Work + Codex)`")
    func sourceWordingUnchanged() {
        #expect(CodexUsageLimitsMenuCopy.settingsSourceName == "ChatGPT (Work + Codex)")
    }

    @Test("Neither Claude limits nor ChatGPT limits shows an `Experimental` badge")
    func noExperimentalBadge() {
        let source = appSource
        #expect(!source.isEmpty)                       // the guard is meaningless if the read failed
        #expect(source.contains("Text(\"Claude Limits\")"))
        #expect(!source.contains("Text(\"Experimental\")"))
        // No core-owned copy reintroduces the classification either.
        for text in [
            CodexUsageLimitsMenuCopy.sectionTitle,
            CodexUsageLimitsMenuCopy.settingsGroupTitle,
            CodexUsageLimitsMenuCopy.settingsTrackSessionsTitle,
            CodexUsageLimitsMenuCopy.settingsSourceName,
            CodexUsageLimitsMenuCopy.emptyState,
            CodexUsageLimitsMenuCopy.emptyStateHelp,
            CodexUsageLimitsMenuCopy.sharedAllowanceNote,
        ] {
            #expect(!text.lowercased().contains("experimental"))
        }
    }

    @Test("Removing the badge kept every honest explanation")
    func honestCopySurvives() {
        // Local-only source, and no network path to refresh it.
        let help = CodexUsageLimitsMenuCopy.emptyStateHelp
        #expect(help.contains("own local session files"))
        #expect(help.contains("never contacts OpenAI"))
        #expect(help.contains("network, cookies, API keys, or account data"))

        // Freshness is bound to a real turn — not to opening the app or its usage screen.
        let note = CodexUsageLimitsMenuCopy.sharedAllowanceNote
        #expect(note.contains("Work"))
        #expect(note.contains("Codex"))
        #expect(note.contains("share one"))            // one shared allowance covers both modes
        #expect(note.contains("runs a turn"))
        #expect(note.lowercased().contains("does not refresh it"))

        // The unavailable state stays honest rather than fabricating a bar.
        #expect(CodexUsageLimitsMenuCopy.emptyState.contains("No recent"))
        #expect(CodexUsageLimitsMenuCopy.emptyState.contains("Work or Codex turn"))
    }

    @Test("The rename left every persisted preference key untouched")
    func preferenceKeysUnchanged() {
        let source = appSource
        for key in [
            "showCodexSessions", "showCodexLimits", "codexLimitsHiddenIDs",
            "codexLimitsSectionExpanded", "showClaudeLimits", "claudeLimitsHiddenIDs",
        ] {
            #expect(source.contains("= \"\(key)\""))
        }

        // And the values stored under them still decode to the same visible rows.
        let now = Date()
        let weekly = CodexUsageLimit(windowMinutes: 10080, usedPercent: 12, resetsAt: now, slot: "primary")
        let fiveHour = CodexUsageLimit(windowMinutes: 300, usedPercent: 7, resetsAt: now, slot: "secondary")
        let visibility = CodexUsageLimitVisibility(persisted: "weekly")
        #expect(visibility.isHidden(weekly))
        #expect(visibility.isVisible(fiveHour))
        #expect(visibility.visibleLimits(in: CodexUsageLimitSnapshot(
            limits: [weekly, fiveHour], capturedAt: now, source: .rollout
        )).map(\.visibilityID) == ["fiveHour"])
    }

    @Test("The keep-awake source raw values are stable and never user-visible")
    func sourceRawValuesAreInternal() {
        #expect(AgentKeepAwakeSource.claude.rawValue == "claude")
        #expect(AgentKeepAwakeSource.codex.rawValue == "codex")
        #expect(AgentKeepAwakeSource.chatGPTWork.rawValue == "work")
        // The visible names come from `PowerAssertionOwner`, not from these raw values.
        #expect(PowerAssertionOwner(source: .chatGPTWork).displayName == "ChatGPT Work")
        #expect(PowerAssertionOwner(source: .codex).displayName == "Codex")
        #expect(PowerAssertionOwner(source: .claude).displayName == "Claude")
        #expect(PowerAssertionOwner.manual.displayName == "Manual")
    }
}
