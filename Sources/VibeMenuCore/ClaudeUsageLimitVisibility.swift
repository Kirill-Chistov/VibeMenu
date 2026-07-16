import Foundation

// Per-row visibility preference for the Claude usage-limit menu section
// (docs/decisions/0016-claude-usage-limits.md).
//
// A VibeMenu-only *view* control, mirroring `DismissedSessionRegistry` for the Session Radar: hiding
// a row removes it from the popover and nothing else. It never deletes source data and never stops
// parsing — the snapshot still holds every captured row (hidden rows are parsed/stored internally);
// this type only filters what the menu draws. Rows are keyed by `ClaudeUsageLimit.visibilityID`, a
// stable normalized id, so a preference survives an app relaunch and survives a row briefly
// disappearing from the source and returning.
//
// Stored as the *hidden* set, so a newly detected row (absent from the set) is shown by default — the
// user opts a row out, never in. The set is bounded (a handful of windows/models) and is deliberately
// **not** pruned when a row disappears from the source, so a hidden row that later returns stays
// hidden (unlike the radar's `reconcile`, which prunes because session ids are unbounded).

/// Tracks which Claude usage-limit rows the user has hidden from the menu, keyed by stable id.
public struct ClaudeUsageLimitVisibility: Equatable, Sendable {
    /// The stable visibility ids the user has explicitly hidden. Absence ⇒ visible (the default).
    private var hiddenIDs: Set<String>

    public init(hiddenIDs: Set<String> = []) {
        self.hiddenIDs = hiddenIDs
    }

    /// Decode from the persisted newline-joined string (empty/blank ⇒ nothing hidden). Tolerant of
    /// stray whitespace and blank lines so a hand-edited or partly-written value can't crash.
    public init(persisted: String) {
        let ids = persisted
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.hiddenIDs = Set(ids)
    }

    /// The persisted representation: sorted, newline-joined stable ids (deterministic for diffing and
    /// tests). Empty string when nothing is hidden.
    public var persisted: String {
        hiddenIDs.sorted().joined(separator: "\n")
    }

    /// The hidden ids, sorted (for tests / diagnostics).
    public var hiddenIdentifiers: [String] { hiddenIDs.sorted() }

    /// Whether nothing is hidden.
    public var isEmpty: Bool { hiddenIDs.isEmpty }

    /// Whether a stable id is currently hidden.
    public func isHidden(id: String) -> Bool { hiddenIDs.contains(id) }

    /// Whether a limit row is currently hidden.
    public func isHidden(_ limit: ClaudeUsageLimit) -> Bool { hiddenIDs.contains(limit.visibilityID) }

    /// Whether a limit row is currently visible (the default for a newly detected row).
    public func isVisible(_ limit: ClaudeUsageLimit) -> Bool { !isHidden(limit) }

    /// Set the hidden state for a stable id: hiding inserts it, showing removes it.
    public mutating func setHidden(_ hidden: Bool, id: String) {
        if hidden { hiddenIDs.insert(id) } else { hiddenIDs.remove(id) }
    }

    /// Set the hidden state for a limit row.
    public mutating func setHidden(_ hidden: Bool, for limit: ClaudeUsageLimit) {
        setHidden(hidden, id: limit.visibilityID)
    }

    /// Filter a snapshot's rows to those the user has not hidden, preserving the snapshot's order.
    public func visibleLimits(in snapshot: ClaudeUsageLimitSnapshot) -> [ClaudeUsageLimit] {
        snapshot.limits.filter(isVisible)
    }
}
