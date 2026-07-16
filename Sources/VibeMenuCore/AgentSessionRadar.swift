import Foundation

// Unified ordering for the AI Agent session list (docs/decisions/0017-codex-session-support.md).
//
// The menu shows Claude Code and (opt-in) Codex Desktop sessions in one compact list under a single
// "AI Agent" status. The two providers share ONE row budget (`SessionRadar.maxVisibleRows`). The
// earlier code filled that budget "all Claude first, then Codex fills the remainder", so a busy
// machine running Claude could starve Codex to zero visible rows. This pure presenter instead
// **interleaves** the two by activity, so a more-active Codex session can take a slot ahead of a
// finished Claude one — while keeping the same shared cap (the product choice: "keep the shared
// budget, just fix ordering").
//
// It never re-orders a provider's rows *among themselves* — Claude's rows arrive already
// attention-first from `SessionRadar`, Codex's already most-active-first from `CodexSessionReader`;
// this only merges the two ordered streams. When Codex is disabled/empty it reduces exactly to the
// previous Claude-only behaviour. Pure and I/O-free; fully unit-tested.

public enum AgentSessionRadar {
    /// One row in the unified list — a Claude radar row or a Codex row. Carries the exact pre-named
    /// row each provider already produced; this layer only orders and caps, never renames.
    public enum Item: Equatable, Sendable, Identifiable {
        case claude(RadarRow)
        case codex(CodexRow)

        public var id: String {
            switch self {
            case .claude(let row): "claude:\(row.id)"
            case .codex(let row): "codex:\(row.id)"
            }
        }
    }

    /// The presented unified list plus the per-provider overflow accounting the menu needs.
    public struct Presentation: Equatable, Sendable {
        /// The interleaved visible rows, most-active-first, capped at the shared budget.
        public let items: [Item]
        /// Claude rows not shown — Claude's own elided rows plus any bumped out of the shared cap by
        /// a more-active Codex row — feeding the existing expandable "more recent sessions" control.
        public let claudeOverflowRows: [RadarRow]
        /// Total Claude sessions not shown (drives the "+N more recent sessions" label).
        public let claudeHiddenCount: Int
        /// Claude sessions beyond the overflow peek (drives "+N older sessions hidden").
        public let claudeOlderHiddenCount: Int
        /// Codex sessions not shown (drives "+N more Codex sessions").
        public let codexHiddenCount: Int

        public init(
            items: [Item],
            claudeOverflowRows: [RadarRow],
            claudeHiddenCount: Int,
            claudeOlderHiddenCount: Int,
            codexHiddenCount: Int
        ) {
            self.items = items
            self.claudeOverflowRows = claudeOverflowRows
            self.claudeHiddenCount = claudeHiddenCount
            self.claudeOlderHiddenCount = claudeOlderHiddenCount
            self.codexHiddenCount = codexHiddenCount
        }
    }

    /// Merge Claude's presentation and the Codex session list into one interleaved, capped list.
    ///
    /// `claude` is `SessionRadar.present(...)` (its own eligibility/cap/overflow already applied);
    /// `codex` is the reader's most-active-first Codex sessions. The visible set is the top `limit`
    /// rows by a unified activity rank across both; the remainder becomes each provider's overflow.
    public static func present(
        claude: SessionRadar.Presentation,
        codex: [CodexSession],
        limit: Int = SessionRadar.maxVisibleRows
    ) -> Presentation {
        let cap = max(0, limit)
        // Order the Codex rows by activity for the merge; names are assigned later over the *visible*
        // rows only (so a lone visible row is never given a "· 1" index, matching the Claude side).
        let codexRows = codex.map { CodexRow(session: $0, name: $0.displayName) }

        // Fast path: no Codex rows ⇒ exactly the previous Claude-only behaviour, byte-for-byte.
        if codexRows.isEmpty {
            return Presentation(
                items: claude.rows.map(Item.claude),
                claudeOverflowRows: claude.overflowRows,
                claudeHiddenCount: claude.hiddenCount,
                claudeOlderHiddenCount: claude.olderHiddenCount,
                codexHiddenCount: 0
            )
        }

        // Stable two-way merge of the already-ordered streams: never reorders a provider's rows
        // among themselves, only chooses which stream's head comes next by (activity bucket, then
        // recency; ties keep Claude first for determinism).
        let claudeRows = claude.rows
        var merged: [Item] = []
        merged.reserveCapacity(claudeRows.count + codexRows.count)
        var ci = 0, xi = 0
        while ci < claudeRows.count && xi < codexRows.count {
            if preferClaude(claudeRows[ci], over: codexRows[xi]) {
                merged.append(.claude(claudeRows[ci])); ci += 1
            } else {
                merged.append(.codex(codexRows[xi])); xi += 1
            }
        }
        while ci < claudeRows.count { merged.append(.claude(claudeRows[ci])); ci += 1 }
        while xi < codexRows.count { merged.append(.codex(codexRows[xi])); xi += 1 }

        let capped = Array(merged.prefix(cap))
        let visibleIDs = Set(capped.map(\.id))

        // Name the *visible* Codex rows by disambiguating only among themselves (a lone visible row
        // stays un-indexed, exactly like Claude's `SessionRadar.disambiguate(visible)`).
        let visibleCodex = capped.compactMap { item -> CodexSession? in
            if case .codex(let row) = item { return row.session } else { return nil }
        }
        let codexNames = Dictionary(
            uniqueKeysWithValues: CodexSessionRadar.disambiguate(visibleCodex).map { ($0.session.id, $0.name) }
        )
        let visible = capped.map { item -> Item in
            if case .codex(let row) = item {
                return .codex(CodexRow(session: row.session, name: codexNames[row.session.id] ?? row.name))
            }
            return item
        }

        // Claude rows bumped out of the shared cap, in Claude's original order, fold into the
        // expandable overflow ahead of Claude's own elided rows — capped to the same peek bound so
        // the expanded list stays bounded, with the remainder counted as "older hidden".
        let bumpedClaude = claudeRows.filter { !visibleIDs.contains(Item.claude($0).id) }
        let claudeHiddenCount = claude.hiddenCount + bumpedClaude.count
        let claudeOverflowRows = Array((bumpedClaude + claude.overflowRows).prefix(SessionRadar.maxOverflowRows))
        let claudeOlderHiddenCount = max(0, claudeHiddenCount - claudeOverflowRows.count)

        let codexShown = visible.reduce(into: 0) { count, item in
            if case .codex = item { count += 1 }
        }
        let codexHiddenCount = max(0, codexRows.count - codexShown)

        return Presentation(
            items: visible,
            claudeOverflowRows: claudeOverflowRows,
            claudeHiddenCount: claudeHiddenCount,
            claudeOlderHiddenCount: claudeOlderHiddenCount,
            codexHiddenCount: codexHiddenCount
        )
    }

    /// Whether the AI Agent sessions section has any **visible** row to draw — the single decision that
    /// gates the whole section in the menu (docs/decisions/0017). The section is shown **iff** the
    /// feature is on *and* at least one interleaved row survives per-provider hiding and the shared cap.
    ///
    /// There is deliberately **no** "no sessions at all" placeholder: when nothing is visible the
    /// section (and its dividers) is omitted entirely so it reserves zero vertical height, rather than
    /// keeping space for a muted "No active sessions" line — which, wrapped by its dividers and the
    /// menu's stack spacing, read as a large empty gap between the section above and Thermal pressure.
    ///
    /// Callers pass the already-hidden-filtered rows (Claude's `SessionRadar.present(visibleSessions…)`
    /// and Codex's `visibleSessions`), so user-hidden rows are removed *before* this decision, never
    /// after layout — a section the user has fully hidden collapses exactly like one with no sessions.
    public static func hasVisibleContent(
        showSessions: Bool,
        claude: SessionRadar.Presentation,
        codex: [CodexSession],
        limit: Int = SessionRadar.maxVisibleRows
    ) -> Bool {
        guard showSessions else { return false }
        return !present(claude: claude, codex: codex, limit: limit).items.isEmpty
    }

    /// Whether a Claude row should sort ahead of a Codex row: lower activity bucket wins; within the
    /// same bucket the more recent wins; an exact tie keeps Claude first (stable/deterministic).
    static func preferClaude(_ claude: RadarRow, over codex: CodexRow) -> Bool {
        let cb = claudeBucket(claude.session.state)
        let xb = codexBucket(codex.session.state)
        if cb != xb { return cb < xb }
        let ca = claude.session.lastEventAt
        let xa = codex.session.lastActivity
        if ca != xa { return ca > xa }
        return true
    }

    /// Coarse cross-provider activity bucket for a Claude state (lower = more attention). Aligns the
    /// two providers' independent state enums onto one ordering: a Claude "needs you" beats working,
    /// which beats a finished/stale row.
    static func claudeBucket(_ state: ClaudeSessionState) -> Int {
        switch state {
        case .permissionRequested: 0   // waiting on the user — highest attention
        case .working, .quietWorking: 1
        case .done: 3
        case .stale: 4
        case .unknown: 5
        }
    }

    /// Coarse cross-provider activity bucket for a Codex state (lower = more attention). Codex never
    /// claims a "needs you" bucket (0) — it has no reliable attention signal (ADR 0017).
    static func codexBucket(_ state: CodexSessionState) -> Int {
        switch state {
        case .active: 1
        case .idle: 2
        case .done: 3
        case .stale: 4
        case .unknown: 5
        }
    }
}
