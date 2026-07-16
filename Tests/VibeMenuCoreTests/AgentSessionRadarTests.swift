import Foundation
import Testing
@testable import VibeMenuCore

// Pure ordering tests for `AgentSessionRadar` (docs/decisions/0017): the unified, interleaved AI
// Agent session list that fixes Codex starvation (Claude no longer always fills the shared cap
// first) while keeping ONE compact budget. No SwiftUI, no I/O.

@Suite("AgentSessionRadar — interleave + shared cap")
struct AgentSessionRadarTests {

    // MARK: builders

    private func claudeRow(_ id: String, _ state: ClaudeSessionState, activityAgo: TimeInterval, now: Date) -> RadarRow {
        let s = ClaudeSession(
            id: id, state: state, event: .preToolUse,
            startedAt: now.addingTimeInterval(-activityAgo),
            lastEventAt: now.addingTimeInterval(-activityAgo)
        )
        return RadarRow(session: s, name: id)
    }

    private func codexSession(_ id: String, _ state: CodexSessionState, activityAgo: TimeInterval, now: Date) -> CodexSession {
        CodexSession(
            id: id, state: state, folderName: id,
            startedAt: now.addingTimeInterval(-activityAgo - 60),
            lastActivity: now.addingTimeInterval(-activityAgo)
        )
    }

    private func claudePresentation(_ rows: [RadarRow], hidden: Int = 0, overflow: [RadarRow] = [], older: Int = 0) -> SessionRadar.Presentation {
        SessionRadar.Presentation(rows: rows, hiddenCount: hidden, overflowRows: overflow, olderHiddenCount: older)
    }

    // MARK: tests

    @Test("No Codex rows → exact Claude-only passthrough (byte-for-byte)")
    func passthroughWhenNoCodex() {
        let now = Date()
        let rows = [claudeRow("a", .working, activityAgo: 5, now: now),
                    claudeRow("b", .done, activityAgo: 30, now: now)]
        let overflow = [claudeRow("c", .done, activityAgo: 90, now: now)]
        let claude = claudePresentation(rows, hidden: 1, overflow: overflow, older: 0)

        let p = AgentSessionRadar.present(claude: claude, codex: [])
        #expect(p.items == rows.map(AgentSessionRadar.Item.claude))
        #expect(p.claudeOverflowRows == overflow)
        #expect(p.claudeHiddenCount == 1)
        #expect(p.codexHiddenCount == 0)
    }

    @Test("An active Codex session sorts above a finished Claude session (Codex not always last)")
    func activeCodexBeatsDoneClaude() {
        let now = Date()
        let claude = claudePresentation([claudeRow("cl", .done, activityAgo: 100, now: now)])
        let codex = [codexSession("cx", .active, activityAgo: 5, now: now)]

        let p = AgentSessionRadar.present(claude: claude, codex: codex)
        #expect(p.items.count == 2)
        // Codex active (bucket 1) comes before Claude done (bucket 3).
        if case .codex(let row) = p.items.first { #expect(row.session.id == "cx") }
        else { Issue.record("expected Codex row first, got \(p.items.first as Any)") }
        if case .claude(let row) = p.items.last { #expect(row.session.id == "cl") }
        else { Issue.record("expected Claude row last") }
    }

    @Test("Shared 4-row cap: busy Codex bumps finished Claude rows into overflow")
    func sharedCapBumpsClaude() {
        let now = Date()
        let claudeRows = [
            claudeRow("c1", .done, activityAgo: 40, now: now),
            claudeRow("c2", .done, activityAgo: 50, now: now),
            claudeRow("c3", .done, activityAgo: 60, now: now),
            claudeRow("c4", .done, activityAgo: 70, now: now),
        ]
        let claude = claudePresentation(claudeRows)
        let codex = [
            codexSession("x1", .active, activityAgo: 5, now: now),
            codexSession("x2", .active, activityAgo: 10, now: now),
        ]

        let p = AgentSessionRadar.present(claude: claude, codex: codex)
        #expect(p.items.count == 4)
        // Two active Codex rows take the top slots.
        let codexShown = p.items.filter { if case .codex = $0 { return true } else { return false } }.count
        #expect(codexShown == 2)
        // Two Claude rows were bumped into overflow.
        #expect(p.claudeHiddenCount == 2)
        #expect(p.claudeOverflowRows.map(\.id) == ["c3", "c4"])
        #expect(p.codexHiddenCount == 0)
    }

    @Test("Excess Codex sessions beyond the cap collapse into the Codex overflow count")
    func codexOverflowCounted() {
        let now = Date()
        let claude = claudePresentation([claudeRow("c1", .working, activityAgo: 2, now: now)])
        let codex = (0..<6).map { codexSession("x\($0)", .idle, activityAgo: TimeInterval(20 + $0), now: now) }

        let p = AgentSessionRadar.present(claude: claude, codex: codex)
        #expect(p.items.count == 4)                 // 1 claude (working) + 3 codex fill the cap
        #expect(p.codexHiddenCount == 3)            // 6 codex, 3 shown
        #expect(p.claudeHiddenCount == 0)
    }

    @Test("A lone visible Codex row is not indexed even if a same-named sibling is bumped below the cap")
    func loneVisibleCodexNotIndexed() {
        let now = Date()
        // Three working Claude rows fill the top of the shared 4-cap; two same-named Codex idle
        // sessions compete for the last slot — only the fresher shows.
        let claude = claudePresentation([
            claudeRow("a", .working, activityAgo: 1, now: now),
            claudeRow("b", .working, activityAgo: 2, now: now),
            claudeRow("c", .working, activityAgo: 3, now: now),
        ])
        // Both Codex sessions share a folder name so disambiguation would index them if applied
        // across the full list; only the fresher one is visible, so it must stay un-indexed.
        let codex = [
            CodexSession(id: "x-new", state: .idle, folderName: "webapp", startedAt: now.addingTimeInterval(-100), lastActivity: now.addingTimeInterval(-30)),
            CodexSession(id: "x-old", state: .idle, folderName: "webapp", startedAt: now.addingTimeInterval(-200), lastActivity: now.addingTimeInterval(-90)),
        ]
        let p = AgentSessionRadar.present(claude: claude, codex: codex)
        #expect(p.items.count == 4)
        let codexName = p.items.compactMap { item -> String? in
            if case .codex(let r) = item { return r.name } else { return nil }
        }
        #expect(codexName == ["webapp"])          // lone visible → no "· 1" index
        #expect(p.codexHiddenCount == 1)
    }

    @Test("No sessions at all → empty presentation (section is omitted entirely; no placeholder row)")
    func noSessionsEmpty() {
        // With no Claude and no Codex rows the presenter yields nothing at all. The menu omits the whole
        // AI Agent sessions section in this case (see `hasVisibleContent`) — no "No active sessions"
        // placeholder, no aggregate idle status row, and no reserved height.
        let p = AgentSessionRadar.present(claude: claudePresentation([]), codex: [])
        #expect(p.items.isEmpty)
        #expect(p.claudeHiddenCount == 0)
        #expect(p.codexHiddenCount == 0)
        #expect(p.claudeOverflowRows.isEmpty)
    }

    @Test("Claude-only sessions present (Codex empty) → only Claude rows, non-empty")
    func claudeOnlyPresent() {
        let now = Date()
        let claude = claudePresentation([claudeRow("a", .working, activityAgo: 3, now: now)])
        let p = AgentSessionRadar.present(claude: claude, codex: [])
        #expect(p.items.count == 1)
        #expect(!p.items.isEmpty)
        if case .claude = p.items.first {} else { Issue.record("expected a Claude row") }
    }

    @Test("Codex-only sessions present (Claude empty) → only Codex rows, non-empty")
    func codexOnlyPresent() {
        let now = Date()
        let codex = [codexSession("x", .active, activityAgo: 5, now: now)]
        let p = AgentSessionRadar.present(claude: claudePresentation([]), codex: codex)
        #expect(p.items.count == 1)
        #expect(!p.items.isEmpty)
        if case .codex = p.items.first {} else { Issue.record("expected a Codex row") }
    }

    @Test("Within a provider, the reader's own order is preserved (never re-sorted internally)")
    func preservesWithinProviderOrder() {
        let now = Date()
        // Two Codex sessions, both active; reader already ordered x-early before x-late by recency.
        let codex = [
            codexSession("x-early", .active, activityAgo: 3, now: now),
            codexSession("x-late", .active, activityAgo: 8, now: now),
        ]
        let claude = claudePresentation([])
        let p = AgentSessionRadar.present(claude: claude, codex: codex)
        let ids = p.items.compactMap { item -> String? in
            if case .codex(let r) = item { return r.session.id } else { return nil }
        }
        #expect(ids == ["x-early", "x-late"])
    }
}

// The single gate that decides whether the whole AI Agent sessions section is drawn (and therefore
// whether it reserves any vertical height in the menu). The section must be shown **iff** the feature
// is on and at least one visible row survives; there is no "no sessions at all" placeholder, so the
// no-sessions case and the all-hidden case both collapse to zero height — the fix for the empty gap
// that used to sit between Codex Limits and Thermal pressure.
@Suite("AgentSessionRadar — hasVisibleContent (section gate)")
struct AgentSessionRadarContentTests {

    private func claudeRow(_ id: String, _ state: ClaudeSessionState, activityAgo: TimeInterval, now: Date) -> RadarRow {
        let s = ClaudeSession(
            id: id, state: state, event: .preToolUse,
            startedAt: now.addingTimeInterval(-activityAgo),
            lastEventAt: now.addingTimeInterval(-activityAgo)
        )
        return RadarRow(session: s, name: id)
    }

    private func codexSession(_ id: String, _ state: CodexSessionState, activityAgo: TimeInterval, now: Date) -> CodexSession {
        CodexSession(
            id: id, state: state, folderName: id,
            startedAt: now.addingTimeInterval(-activityAgo - 60),
            lastActivity: now.addingTimeInterval(-activityAgo)
        )
    }

    private func present(_ rows: [RadarRow]) -> SessionRadar.Presentation {
        SessionRadar.Presentation(rows: rows, hiddenCount: 0, overflowRows: [], olderHiddenCount: 0)
    }

    @Test("Feature off → no section, even if visible rows exist")
    func featureOffHidesSection() {
        let now = Date()
        let claude = present([claudeRow("a", .working, activityAgo: 2, now: now)])
        #expect(!AgentSessionRadar.hasVisibleContent(showSessions: false, claude: claude, codex: []))
    }

    @Test("No sessions at all → no section (no placeholder, no reserved height)")
    func noSessionsHidesSection() {
        #expect(!AgentSessionRadar.hasVisibleContent(showSessions: true, claude: present([]), codex: []))
    }

    @Test("All sessions hidden → no section (hidden rows are filtered out before this gate → empty inputs)")
    func allHiddenHidesSection() {
        // The app filters user-hidden rows *before* calling the radar (Claude's `visibleSessions`,
        // Codex's `visibleSessions`), so "the user hid every row" reaches this gate as empty inputs —
        // and must collapse the section exactly like "no sessions at all".
        #expect(!AgentSessionRadar.hasVisibleContent(showSessions: true, claude: present([]), codex: []))
    }

    @Test("Claude sessions visible → section appears")
    func claudeVisibleShowsSection() {
        let now = Date()
        let claude = present([claudeRow("a", .working, activityAgo: 2, now: now)])
        #expect(AgentSessionRadar.hasVisibleContent(showSessions: true, claude: claude, codex: []))
    }

    @Test("Codex sessions visible → section appears")
    func codexVisibleShowsSection() {
        let now = Date()
        let codex = [codexSession("x", .active, activityAgo: 5, now: now)]
        #expect(AgentSessionRadar.hasVisibleContent(showSessions: true, claude: present([]), codex: codex))
    }

    @Test("Both providers visible → section appears")
    func bothVisibleShowsSection() {
        let now = Date()
        let claude = present([claudeRow("a", .working, activityAgo: 2, now: now)])
        let codex = [codexSession("x", .active, activityAgo: 5, now: now)]
        #expect(AgentSessionRadar.hasVisibleContent(showSessions: true, claude: claude, codex: codex))
    }
}
