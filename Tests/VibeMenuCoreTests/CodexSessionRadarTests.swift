import Foundation
import Testing
@testable import VibeMenuCore

// Pure presentation tests for `CodexSessionRadar.present` (docs/decisions/0017): the standalone
// Codex cap and name disambiguation. The shared menu's cross-provider budget and overflow are tested
// through `AgentSessionRadar`.

@Suite("CodexSessionRadar — caps + disambiguation")
struct CodexSessionRadarTests {
    private func session(_ id: String, folder: String?, started: TimeInterval) -> CodexSession {
        CodexSession(id: id, state: .active, folderName: folder,
                     startedAt: Date(timeIntervalSince1970: 1_770_000_000 + started),
                     lastActivity: Date(timeIntervalSince1970: 1_770_000_100 + started))
    }

    @Test("Caps to the budget and reports the elided count")
    func capsToBudget() {
        let sessions = (0..<6).map { session("s\($0)", folder: "P\($0)", started: Double($0)) }
        let p = CodexSessionRadar.present(sessions, limit: 4)
        #expect(p.rows.count == 4)
        #expect(p.hiddenCount == 2)
        #expect(p.rows.map(\.session.id) == ["s0", "s1", "s2", "s3"])   // order preserved
    }

    @Test("Budget of 0 shows nothing, everything is hidden")
    func zeroBudget() {
        let sessions = [session("a", folder: "P", started: 0), session("b", folder: "Q", started: 1)]
        let p = CodexSessionRadar.present(sessions, limit: 0)
        #expect(p.rows.isEmpty)
        #expect(p.hiddenCount == 2)
    }

    @Test("Empty input → no rows, nothing hidden")
    func empty() {
        let p = CodexSessionRadar.present([], limit: 4)
        #expect(p.rows.isEmpty)
        #expect(p.hiddenCount == 0)
    }

    @Test("Two same-folder rows get 1/2 suffixes; a unique one is left bare")
    func disambiguation() {
        let sessions = [
            session("a", folder: "VibeMenu", started: 0),
            session("b", folder: "VibeMenu", started: 10),
            session("c", folder: "Other", started: 5),
        ]
        let p = CodexSessionRadar.present(sessions, limit: 4)
        let namesByID = Dictionary(uniqueKeysWithValues: p.rows.map { ($0.session.id, $0.name) })
        #expect(namesByID["a"] == "VibeMenu 1")   // earlier startedAt → index 1
        #expect(namesByID["b"] == "VibeMenu 2")
        #expect(namesByID["c"] == "Other")        // unique name, no suffix
    }

    @Test("A folder-less session uses the generic name")
    func genericName() {
        let p = CodexSessionRadar.present([session("a", folder: nil, started: 0)], limit: 4)
        #expect(p.rows.first?.name == CodexSession.genericName)
    }
}

@Suite("Standalone Codex presentation budgets")
struct AgentSharedBudgetTests {
    // Provider-local budgets retained for the standalone Codex presenter.
    private func codexBudget(claudeRowCount: Int) -> Int {
        max(0, SessionRadar.maxVisibleRows - claudeRowCount)
    }
    private func codex(_ n: Int) -> [CodexSession] {
        (0..<n).map {
            CodexSession(id: "c\($0)", state: .active, folderName: "P\($0)",
                         startedAt: Date().addingTimeInterval(Double($0)),
                         lastActivity: Date().addingTimeInterval(Double($0)))
        }
    }

    @Test("Codex only (no Claude rows): up to 4 Codex rows show")
    func codexOnly() {
        let p = CodexSessionRadar.present(codex(6), limit: codexBudget(claudeRowCount: 0))
        #expect(p.rows.count == 4)
        #expect(p.hiddenCount == 2)
    }

    @Test("Claude + Codex share the budget: 2 Claude leaves 2 Codex slots")
    func sharedBudget() {
        let p = CodexSessionRadar.present(codex(5), limit: codexBudget(claudeRowCount: 2))
        #expect(p.rows.count == 2)
        #expect(p.hiddenCount == 3)
    }

    @Test("Claude fills all 4 slots: Codex primary rows collapse entirely to overflow")
    func claudeFull() {
        let p = CodexSessionRadar.present(codex(3), limit: codexBudget(claudeRowCount: 4))
        #expect(p.rows.isEmpty)
        #expect(p.hiddenCount == 3)
    }
}
