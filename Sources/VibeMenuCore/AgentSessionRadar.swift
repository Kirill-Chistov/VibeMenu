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
// this merges both the primary and bounded hidden streams. When Codex is disabled/empty it reduces
// exactly to the previous Claude-only behaviour. Pure and I/O-free; fully unit-tested.

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

    /// The presented unified list plus one bounded, provider-neutral overflow list.
    public struct Presentation: Equatable, Sendable {
        /// The interleaved visible rows, most-active-first, capped at the shared budget.
        public let items: [Item]
        /// The next most-active eligible rows from both providers, capped at the shared overflow bound.
        public let overflowItems: [Item]
        /// Total eligible rows not shown in `items`, across both providers.
        public let hiddenCount: Int
        /// Eligible rows beyond `overflowItems`, across both providers.
        public let olderHiddenCount: Int

        public init(
            items: [Item],
            overflowItems: [Item] = [],
            hiddenCount: Int,
            olderHiddenCount: Int = 0
        ) {
            self.items = items
            self.overflowItems = overflowItems
            self.hiddenCount = hiddenCount
            self.olderHiddenCount = olderHiddenCount
        }
    }

    /// Merge Claude's presentation and the Codex session list into one interleaved, capped list.
    ///
    /// `claude` is `SessionRadar.present(...)` (its own eligibility/cap/overflow already applied);
    /// `codex` is the reader's most-active-first, provider-filtered Codex sessions. The visible set is
    /// the top `limit` rows by a unified activity rank across both. The hidden suffixes are then merged
    /// by the same rank for one bounded expandable overflow list.
    public static func present(
        claude: SessionRadar.Presentation,
        codex: [CodexSession],
        limit: Int = SessionRadar.maxVisibleRows
    ) -> Presentation {
        let cap = max(0, limit)
        // The reader already orders Codex most-active-first. Names are assigned after the shared
        // primary + overflow slices are known, so expanded rows retain provider disambiguation too.
        let codexRows = codex.map { CodexRow(session: $0, name: $0.displayName) }

        // Stable two-way merge of the already-ordered streams: never reorder a provider's rows
        // among themselves, only choose which stream's head comes next by (activity bucket, then
        // recency; ties keep Claude first for determinism).
        let claudeRows = claude.rows
        let merged = merge(claude: claudeRows, codex: codexRows)
        let capped = Array(merged.prefix(cap))
        let visibleIDs = Set(capped.map(\.id))

        // A Claude row can be bumped from the shared primary cap by a more-active Codex row. It is
        // part of the hidden Claude stream before SessionRadar's own elided rows. Both streams are
        // already provider-ordered, so their suffixes can be merged with the same cross-provider rank.
        let bumpedClaude = claudeRows.filter { !visibleIDs.contains(Item.claude($0).id) }
        let hiddenClaude = bumpedClaude + claude.overflowRows
        let hiddenCodex = codexRows.filter { !visibleIDs.contains(Item.codex($0).id) }
        let hiddenMerged = merge(claude: hiddenClaude, codex: hiddenCodex)
        let rawOverflow = Array(hiddenMerged.prefix(SessionRadar.maxOverflowRows))

        let hiddenCount = claude.hiddenCount + bumpedClaude.count + hiddenCodex.count
        let olderHiddenCount = max(0, hiddenCount - rawOverflow.count)

        // Apply Codex disambiguation separately to the primary and expanded slices, matching the
        // existing provider presenters and keeping the four-row primary names unchanged when a
        // same-named sibling is only in the hidden slice. Claude rows retain the names assigned by
        // its existing presenter, including its provider-specific collision rules.
        let visibleCodex = capped.compactMap { item -> CodexSession? in
            if case .codex(let row) = item { return row.session }
            return nil
        }
        let overflowCodex = rawOverflow.compactMap { item -> CodexSession? in
            if case .codex(let row) = item { return row.session }
            return nil
        }
        let visibleCodexNames = Dictionary(
            uniqueKeysWithValues: CodexSessionRadar.disambiguate(visibleCodex).map { ($0.session.id, $0.name) }
        )
        let overflowCodexNames = Dictionary(
            uniqueKeysWithValues: CodexSessionRadar.disambiguate(overflowCodex).map { ($0.session.id, $0.name) }
        )

        return Presentation(
            items: named(capped, codexNames: visibleCodexNames),
            overflowItems: named(rawOverflow, codexNames: overflowCodexNames),
            hiddenCount: hiddenCount,
            olderHiddenCount: olderHiddenCount
        )
    }

    /// Merge two already-ordered provider streams using the shared activity rank.
    private static func merge(claude: [RadarRow], codex: [CodexRow]) -> [Item] {
        var merged: [Item] = []
        merged.reserveCapacity(claude.count + codex.count)
        var ci = 0
        var xi = 0
        while ci < claude.count && xi < codex.count {
            if preferClaude(claude[ci], over: codex[xi]) {
                merged.append(.claude(claude[ci]))
                ci += 1
            } else {
                merged.append(.codex(codex[xi]))
                xi += 1
            }
        }
        while ci < claude.count {
            merged.append(.claude(claude[ci]))
            ci += 1
        }
        while xi < codex.count {
            merged.append(.codex(codex[xi]))
            xi += 1
        }
        return merged
    }

    /// Replace only Codex names after the visible and expanded slices are selected.
    private static func named(_ items: [Item], codexNames: [String: String]) -> [Item] {
        items.map { item in
            guard case .codex(let row) = item else { return item }
            return .codex(CodexRow(session: row.session, name: codexNames[row.session.id] ?? row.name))
        }
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
