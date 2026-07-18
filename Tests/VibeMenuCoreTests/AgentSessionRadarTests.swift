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

    private func ids(_ items: [AgentSessionRadar.Item]) -> [String] {
        items.map(\.id)
    }

    // MARK: tests

    @Test("Claude-only overflow remains expandable through the unified model")
    func claudeOnlyOverflowUsesUnifiedItems() {
        let now = Date()
        let primary = (0..<4).map { claudeRow("c\($0)", .working, activityAgo: Double($0 + 1), now: now) }
        let hidden = claudeRow("c4", .done, activityAgo: 30, now: now)

        let p = AgentSessionRadar.present(
            claude: claudePresentation(primary, hidden: 1, overflow: [hidden]), codex: []
        )

        #expect(ids(p.items) == ["claude:c0", "claude:c1", "claude:c2", "claude:c3"])
        #expect(ids(p.overflowItems) == ["claude:c4"])
        #expect(p.hiddenCount == 1)
        #expect(p.olderHiddenCount == 0)
    }

    @Test("Codex-only overflow produces expandable Codex rows")
    func codexOnlyOverflowUsesUnifiedItems() {
        let now = Date()
        let codex = (0..<6).map { codexSession("x\($0)", .idle, activityAgo: Double($0 + 1), now: now) }

        let p = AgentSessionRadar.present(claude: claudePresentation([]), codex: codex)

        #expect(ids(p.items) == ["codex:x0", "codex:x1", "codex:x2", "codex:x3"])
        #expect(ids(p.overflowItems) == ["codex:x4", "codex:x5"])
        #expect(p.hiddenCount == 2)
        #expect(p.olderHiddenCount == 0)
    }

    @Test("Mixed overflow uses the same shared priority and recency order as primary")
    func mixedOverflowUsesSharedOrdering() {
        let now = Date()
        let claudeRows = [
            claudeRow("c1", .working, activityAgo: 3, now: now),
            claudeRow("c2", .done, activityAgo: 4, now: now),
            claudeRow("c3", .done, activityAgo: 5, now: now),
            claudeRow("c4", .done, activityAgo: 6, now: now),
        ]
        let codex = [
            codexSession("x1", .active, activityAgo: 1, now: now),
            codexSession("x2", .idle, activityAgo: 2, now: now),
            codexSession("x3", .done, activityAgo: 3, now: now),
            codexSession("x4", .done, activityAgo: 4, now: now),
        ]

        let p = AgentSessionRadar.present(claude: claudePresentation(claudeRows), codex: codex)

        #expect(ids(p.items + p.overflowItems) == [
            "codex:x1", "claude:c1", "codex:x2", "codex:x3",
            "claude:c2", "codex:x4", "claude:c3", "claude:c4"
        ])
    }

    @Test("An active hidden Codex row sorts ahead of a hidden Done Claude row")
    func activeHiddenCodexBeatsHiddenDoneClaude() {
        let now = Date()
        let primary = (0..<4).map {
            claudeRow("primary\($0)", .permissionRequested, activityAgo: Double($0 + 1), now: now)
        }
        let hiddenDone = claudeRow("done", .done, activityAgo: 30, now: now)
        let hiddenActive = codexSession("active", .active, activityAgo: 1, now: now)

        let p = AgentSessionRadar.present(
            claude: claudePresentation(primary, hidden: 1, overflow: [hiddenDone]),
            codex: [hiddenActive]
        )

        #expect(ids(p.overflowItems) == ["codex:active", "claude:done"])
    }

    @Test("A higher-priority hidden Claude row sorts ahead of lower-priority Codex rows")
    func higherPriorityHiddenClaudeBeatsLowerPriorityCodex() {
        let now = Date()
        let primary = (0..<4).map {
            claudeRow("primary\($0)", .permissionRequested, activityAgo: Double($0 + 1), now: now)
        }
        let hiddenWorking = claudeRow("working", .working, activityAgo: 40, now: now)
        let hiddenIdle = codexSession("idle", .idle, activityAgo: 1, now: now)
        let hiddenDone = codexSession("done", .done, activityAgo: 2, now: now)

        let p = AgentSessionRadar.present(
            claude: claudePresentation(primary, hidden: 1, overflow: [hiddenWorking]),
            codex: [hiddenIdle, hiddenDone]
        )

        #expect(ids(p.overflowItems) == ["claude:working", "codex:idle", "codex:done"])
    }

    @Test("The primary list remains capped at four rows")
    func primaryListRemainsCappedAtFour() {
        let now = Date()
        let codex = (0..<12).map { codexSession("x\($0)", .active, activityAgo: Double($0 + 1), now: now) }
        let p = AgentSessionRadar.present(claude: claudePresentation([]), codex: codex)

        #expect(p.items.count == SessionRadar.maxVisibleRows)
    }

    @Test("The unified overflow is capped at ten rows")
    func unifiedOverflowIsCappedAtTen() {
        let now = Date()
        let primary = (0..<4).map {
            claudeRow("primary\($0)", .permissionRequested, activityAgo: Double($0 + 1), now: now)
        }
        let claudeOverflow = (0..<12).map {
            claudeRow("c\($0)", .done, activityAgo: Double(30 + $0), now: now)
        }
        let codex = (0..<4).map {
            codexSession("x\($0)", .done, activityAgo: Double(40 + $0), now: now)
        }

        let p = AgentSessionRadar.present(
            claude: claudePresentation(primary, hidden: claudeOverflow.count, overflow: Array(claudeOverflow.prefix(10)), older: 2),
            codex: codex
        )

        #expect(p.items.count == 4)
        #expect(p.overflowItems.count == SessionRadar.maxOverflowRows)
    }

    @Test("hiddenCount includes hidden Claude and Codex rows")
    func hiddenCountIncludesBothProviders() {
        let now = Date()
        let primary = (0..<4).map {
            claudeRow("primary\($0)", .permissionRequested, activityAgo: Double($0 + 1), now: now)
        }
        let claudeHidden = (0..<2).map {
            claudeRow("c\($0)", .done, activityAgo: Double(20 + $0), now: now)
        }
        let codex = (0..<3).map {
            codexSession("x\($0)", .idle, activityAgo: Double(30 + $0), now: now)
        }

        let p = AgentSessionRadar.present(
            claude: claudePresentation(primary, hidden: 2, overflow: claudeHidden), codex: codex
        )

        #expect(p.hiddenCount == 5)
        #expect(p.overflowItems.count == 5)
        #expect(p.olderHiddenCount == 0)
    }

    @Test("olderHiddenCount is the provider-neutral remainder")
    func olderHiddenCountIncludesProviderNeutralRemainder() {
        let now = Date()
        let primary = (0..<4).map {
            claudeRow("primary\($0)", .permissionRequested, activityAgo: Double($0 + 1), now: now)
        }
        let claudeOverflow = (0..<10).map {
            claudeRow("c\($0)", .done, activityAgo: Double(20 + $0), now: now)
        }
        let codex = (0..<3).map {
            codexSession("x\($0)", .idle, activityAgo: Double(40 + $0), now: now)
        }

        let p = AgentSessionRadar.present(
            claude: claudePresentation(primary, hidden: 12, overflow: claudeOverflow, older: 2), codex: codex
        )

        #expect(p.hiddenCount == 15)
        #expect(p.overflowItems.count == SessionRadar.maxOverflowRows)
        #expect(p.olderHiddenCount == 5)
    }

    @Test("Singular and plural provider-neutral counts remain representable")
    func singularAndPluralCounts() {
        let now = Date()
        let primary = (0..<4).map {
            claudeRow("primary\($0)", .permissionRequested, activityAgo: Double($0 + 1), now: now)
        }
        let one = AgentSessionRadar.present(
            claude: claudePresentation(primary, hidden: 1, overflow: [claudeRow("one", .done, activityAgo: 20, now: now)]),
            codex: []
        )
        #expect(one.hiddenCount == 1)
        #expect(one.olderHiddenCount == 0)

        let many = AgentSessionRadar.present(
            claude: claudePresentation(primary, hidden: 2, overflow: [
                claudeRow("one", .done, activityAgo: 20, now: now),
                claudeRow("two", .done, activityAgo: 21, now: now)
            ]),
            codex: []
        )
        #expect(many.hiddenCount == 2)
        #expect(many.overflowItems.count == 2)
    }

    @Test("Hidden or dismissed sessions supplied outside the visible inputs never reappear")
    func hiddenSessionsNeverReappearThroughOverflow() {
        let now = Date()
        let claude = claudePresentation([
            claudeRow("visible-claude", .working, activityAgo: 1, now: now)
        ])
        let codex = [codexSession("visible-codex", .active, activityAgo: 2, now: now)]

        let p = AgentSessionRadar.present(claude: claude, codex: codex)

        #expect(!ids(p.items + p.overflowItems).contains("claude:hidden-claude"))
        #expect(!ids(p.items + p.overflowItems).contains("codex:hidden-codex"))
    }

    @Test("No overflow produces no unified expansion control data")
    func noOverflowProducesNoControlData() {
        let now = Date()
        let claude = claudePresentation([
            claudeRow("a", .working, activityAgo: 1, now: now),
            claudeRow("b", .done, activityAgo: 2, now: now)
        ])
        let p = AgentSessionRadar.present(claude: claude, codex: [])

        #expect(p.hiddenCount == 0)
        #expect(p.overflowItems.isEmpty)
        #expect(p.olderHiddenCount == 0)
    }

    @Test("No Codex rows → exact Claude-only passthrough (byte-for-byte)")
    func passthroughWhenNoCodex() {
        let now = Date()
        let rows = [claudeRow("a", .working, activityAgo: 5, now: now),
                    claudeRow("b", .done, activityAgo: 30, now: now)]
        let overflow = [claudeRow("c", .done, activityAgo: 90, now: now)]
        let claude = claudePresentation(rows, hidden: 1, overflow: overflow, older: 0)

        let p = AgentSessionRadar.present(claude: claude, codex: [])
        #expect(p.items == rows.map(AgentSessionRadar.Item.claude))
        #expect(p.overflowItems == overflow.map(AgentSessionRadar.Item.claude))
        #expect(p.hiddenCount == 1)
        #expect(p.olderHiddenCount == 0)
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
        #expect(p.hiddenCount == 2)
        #expect(p.overflowItems.map(\.id) == ["claude:c3", "claude:c4"])
        #expect(p.olderHiddenCount == 0)
    }

    @Test("Excess Codex sessions beyond the cap produce unified overflow rows")
    func codexOverflowCounted() {
        let now = Date()
        let claude = claudePresentation([claudeRow("c1", .working, activityAgo: 2, now: now)])
        let codex = (0..<6).map { codexSession("x\($0)", .idle, activityAgo: TimeInterval(20 + $0), now: now) }

        let p = AgentSessionRadar.present(claude: claude, codex: codex)
        #expect(p.items.count == 4)                 // 1 claude (working) + 3 codex fill the cap
        #expect(p.overflowItems.count == 3)          // 6 codex, 3 shown
        #expect(p.overflowItems.map(\.id) == ["codex:x3", "codex:x4", "codex:x5"])
        #expect(p.hiddenCount == 3)
        #expect(p.olderHiddenCount == 0)
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
        #expect(p.hiddenCount == 1)
    }

    @Test("No sessions at all → empty presentation (section is omitted entirely; no placeholder row)")
    func noSessionsEmpty() {
        // With no Claude and no Codex rows the presenter yields nothing at all. The menu omits the whole
        // AI Agent sessions section in this case (see `hasVisibleContent`) — no "No active sessions"
        // placeholder, no aggregate idle status row, and no reserved height.
        let p = AgentSessionRadar.present(claude: claudePresentation([]), codex: [])
        #expect(p.items.isEmpty)
        #expect(p.hiddenCount == 0)
        #expect(p.olderHiddenCount == 0)
        #expect(p.overflowItems.isEmpty)
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
