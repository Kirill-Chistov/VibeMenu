import Foundation
import Testing
@testable import VibeMenuCore

// Manual hide / dismiss tests for Codex rows (docs/decisions/0017, Fix 2). Two layers:
//   1. `DismissedCodexRegistry` — the pure Option-2 watermark logic, mirroring the Claude registry,
//      including the stable-id-across-title-change guarantee.
//   2. `CodexSessionModel` — hiding removes rows from `visibleSessions` (applied BEFORE the menu's
//      cap/interleave) while the raw `sessions` list fed to the keep-awake loop is untouched.

// MARK: - Registry

@Suite("DismissedCodexRegistry")
struct DismissedCodexRegistryTests {
    private let t0 = Date(timeIntervalSince1970: 6_000_000)

    private func session(
        _ id: String, state: CodexSessionState = .done, folderName: String? = "proj",
        title: String? = nil, lastActivity: Date
    ) -> CodexSession {
        CodexSession(
            id: id, state: state, folderName: folderName,
            startedAt: lastActivity.addingTimeInterval(-60), lastActivity: lastActivity, title: title
        )
    }

    @Test func newRegistryHidesNothing() {
        var reg = DismissedCodexRegistry()
        #expect(reg.isEmpty)
        let s = session("a", lastActivity: t0)
        #expect(!reg.isHidden(s))
        #expect(reg.reconcile(with: [s]).map(\.id) == ["a"])
    }

    @Test func dismissHidesUntilNewerActivity() {
        var reg = DismissedCodexRegistry()
        let s = session("a", lastActivity: t0)
        reg.dismiss(s)
        #expect(reg.isHidden(s))
        #expect(reg.reconcile(with: [s]).isEmpty)   // same activity → still hidden

        let newer = session("a", state: .active, lastActivity: t0.addingTimeInterval(5))
        #expect(reg.reconcile(with: [newer]).map(\.id) == ["a"])   // newer activity → revived
        #expect(reg.isEmpty)
    }

    @Test func finishedSessionStaysHidden() {
        var reg = DismissedCodexRegistry()
        let done = session("done", state: .done, lastActivity: t0)
        reg.dismiss(done)
        for _ in 0..<5 { #expect(reg.reconcile(with: [done]).isEmpty) }
    }

    /// The whole point of keying on the opaque session id: a session whose safe **title** changes
    /// (folder → thread_name, or a renamed thread) keeps the same id, so it stays hidden. Hiding must
    /// never depend on the display title/folder.
    @Test func hiddenStaysHiddenWhenTitleChanges() {
        var reg = DismissedCodexRegistry()
        let noTitle = session("sess-1", folderName: "webapp", title: nil, lastActivity: t0)
        reg.dismiss(noTitle)
        #expect(reg.reconcile(with: [noTitle]).isEmpty)

        // Same id + same activity, but now a title resolved (or the folder differs) — still hidden.
        let titled = session("sess-1", folderName: "webapp", title: "Refactor the parser", lastActivity: t0)
        #expect(reg.isHidden(titled))
        #expect(reg.reconcile(with: [titled]).isEmpty)
    }

    @Test func dropsDismissalsForVanishedSessions() {
        var reg = DismissedCodexRegistry()
        reg.dismiss(session("a", lastActivity: t0))
        #expect(!reg.isEmpty)
        _ = reg.reconcile(with: [])
        #expect(reg.isEmpty)
    }

    @Test func reconcilePreservesInputOrder() {
        var reg = DismissedCodexRegistry()
        let a = session("a", lastActivity: t0), b = session("b", lastActivity: t0), c = session("c", lastActivity: t0)
        reg.dismiss(b)
        #expect(reg.reconcile(with: [a, b, c]).map(\.id) == ["a", "c"])
    }

    @Test func hideAllLeavesNothing() {
        var reg = DismissedCodexRegistry()
        let all = [session("a", lastActivity: t0), session("b", lastActivity: t0), session("c", lastActivity: t0)]
        for s in all { reg.dismiss(s) }
        #expect(reg.reconcile(with: all).isEmpty)   // every row hidden → none visible
    }
}

// MARK: - Model

/// Fake provider that lets a test push session lists synchronously (no timer, no files).
private final class FakeCodexProvider: CodexSessionObserving, @unchecked Sendable {
    private(set) var sessions: [CodexSession] = []
    private var callback: (@Sendable ([CodexSession]) -> Void)?

    func start(onSessions: @escaping @Sendable ([CodexSession]) -> Void) {
        callback = onSessions
        callback?(sessions)
    }
    func stop() { callback = nil }

    /// Emit a new list, as the real provider would on change.
    func emit(_ newSessions: [CodexSession]) {
        sessions = newSessions
        callback?(newSessions)
    }
}

@Suite("CodexSessionModel — hide is view-only", .serialized)
@MainActor
struct CodexSessionModelHideTests {
    private let t0 = Date(timeIntervalSince1970: 6_000_000)

    private func session(_ id: String, state: CodexSessionState = .active, lastActivity: Date) -> CodexSession {
        CodexSession(
            id: id, state: state, folderName: id,
            startedAt: lastActivity.addingTimeInterval(-60), lastActivity: lastActivity
        )
    }

    @Test("Hiding every visible row leaves no session rows, but the raw list (power loop) is untouched")
    func hideAllLeavesNoVisibleRowsButKeepsRaw() {
        let provider = FakeCodexProvider()
        let model = CodexSessionModel(provider: provider)

        var lastRaw: [CodexSession] = []
        model.onSessionsChange = { lastRaw = $0 }
        model.start()

        let sessions = [session("a", lastActivity: t0), session("b", lastActivity: t0)]
        provider.emit(sessions)
        #expect(model.visibleSessions.map(\.id) == ["a", "b"])
        #expect(lastRaw.map(\.id) == ["a", "b"])

        // Hide both.
        model.dismiss(sessions[0])
        model.dismiss(sessions[1])
        #expect(model.visibleSessions.isEmpty)      // nothing left to draw
        // The raw list — what feeds `CodexSessionActivity.automationIntent` — is unchanged, so hiding a
        // row never stops an active Codex session from preventing sleep.
        #expect(model.sessions.map(\.id) == ["a", "b"])
        // dismiss() must NOT re-fire the power-loop hook (it is display-only).
        #expect(lastRaw.map(\.id) == ["a", "b"])
    }

    @Test("A hidden Codex row does not reappear on a same-activity refresh (no forced-back rows)")
    func hiddenRowStaysHiddenAcrossRefresh() {
        let provider = FakeCodexProvider()
        let model = CodexSessionModel(provider: provider)
        model.start()

        let s = session("a", state: .done, lastActivity: t0)
        provider.emit([s])
        model.dismiss(s)
        #expect(model.visibleSessions.isEmpty)

        // Same session re-emitted (a normal tick, no new activity) — must stay hidden.
        provider.emit([s])
        #expect(model.visibleSessions.isEmpty)
    }

    /// Hidden filtering must run BEFORE the shared cap/interleave, so a hidden most-active session can
    /// never occupy a slot and push a still-visible one out of view. Five active sessions, hide the two
    /// freshest: the 3 remaining fill the 4-cap and none of the hidden ids appear anywhere.
    @Test("Hidden Codex rows are filtered before the shared cap/interleave (never occupy a slot)")
    func hiddenFilteredBeforeCap() {
        let provider = FakeCodexProvider()
        let model = CodexSessionModel(provider: provider)
        model.start()

        // Most-active-first order (as the reader would produce): a is freshest.
        let sessions = (0..<5).map { i in
            session("s\(i)", state: .active, lastActivity: t0.addingTimeInterval(-Double(i)))
        }
        provider.emit(sessions)
        model.dismiss(sessions[0])   // hide the two freshest
        model.dismiss(sessions[1])

        let claudeEmpty = SessionRadar.Presentation(rows: [], hiddenCount: 0, overflowRows: [], olderHiddenCount: 0)
        let p = AgentSessionRadar.present(claude: claudeEmpty, codex: model.visibleSessions)
        let shownIDs = p.items.compactMap { item -> String? in
            if case .codex(let r) = item { return r.session.id } else { return nil }
        }
        #expect(shownIDs == ["s2", "s3", "s4"])       // hidden s0/s1 never occupy a slot
        #expect(!shownIDs.contains("s0"))
        #expect(!shownIDs.contains("s1"))
    }

    @Test("A hidden Codex row reappears once it shows newer activity (mirrors Claude)")
    func hiddenRowRevivesOnNewActivity() {
        let provider = FakeCodexProvider()
        let model = CodexSessionModel(provider: provider)
        model.start()

        let s = session("a", state: .idle, lastActivity: t0)
        provider.emit([s])
        model.dismiss(s)
        #expect(model.visibleSessions.isEmpty)

        let newer = session("a", state: .active, lastActivity: t0.addingTimeInterval(10))
        provider.emit([newer])
        #expect(model.visibleSessions.map(\.id) == ["a"])
    }
}
