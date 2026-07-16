import Foundation

// Per-row visibility preference for the Codex usage-limit menu section
// (docs/decisions/0017-codex-session-support.md).
//
// A VibeMenu-only *view* control, kept **fully separate from Claude's** visibility (its own storage
// key, `codexLimitsHiddenIDs`): hiding the 5-hour or Weekly row removes it from the popover and
// nothing else. It never deletes source data and never stops parsing — the snapshot still holds
// every parsed row; this only filters what the menu draws. Rows are keyed by
// `CodexUsageLimit.visibilityID`, so a preference survives a relaunch and a row briefly disappearing.
//
// Stored as the *hidden* set, so a newly detected row is shown by default — the user opts a row out,
// never in. The set is tiny (two windows) and is deliberately not pruned when a row disappears, so a
// hidden row that later returns stays hidden.

/// Tracks which Codex usage-limit rows the user has hidden from the menu, keyed by stable id.
public struct CodexUsageLimitVisibility: Equatable, Sendable {
    private var hiddenIDs: Set<String>

    public init(hiddenIDs: Set<String> = []) {
        self.hiddenIDs = hiddenIDs
    }

    /// Decode from the persisted newline-joined string (empty/blank ⇒ nothing hidden). Tolerant of
    /// stray whitespace and blank lines.
    public init(persisted: String) {
        let ids = persisted
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.hiddenIDs = Set(ids)
    }

    /// The persisted representation: sorted, newline-joined stable ids. Empty when nothing is hidden.
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
    public func isHidden(_ limit: CodexUsageLimit) -> Bool { hiddenIDs.contains(limit.visibilityID) }

    /// Whether a limit row is currently visible (the default for a newly detected row).
    public func isVisible(_ limit: CodexUsageLimit) -> Bool { !isHidden(limit) }

    /// Set the hidden state for a stable id: hiding inserts it, showing removes it.
    public mutating func setHidden(_ hidden: Bool, id: String) {
        if hidden { hiddenIDs.insert(id) } else { hiddenIDs.remove(id) }
    }

    /// Set the hidden state for a limit row.
    public mutating func setHidden(_ hidden: Bool, for limit: CodexUsageLimit) {
        setHidden(hidden, id: limit.visibilityID)
    }

    /// Filter a snapshot's rows to those the user has not hidden, preserving the snapshot's order.
    public func visibleLimits(in snapshot: CodexUsageLimitSnapshot) -> [CodexUsageLimit] {
        snapshot.limits.filter(isVisible)
    }
}
