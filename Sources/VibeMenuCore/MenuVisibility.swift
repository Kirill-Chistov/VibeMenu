import Foundation

/// Pure, I/O-free decision for which main-menu status rows (and their divider) are
/// shown, driven solely by the user's two visibility preferences.
///
/// The persisted preferences themselves live at the app/UI boundary
/// (`@AppStorage` / `UserDefaults`); this type only turns two booleans into the
/// three display decisions the menu needs, so the logic stays deterministic and
/// unit-testable without any SwiftUI or defaults access.
public struct MenuVisibility: Equatable, Sendable {
    /// Whether the user wants the **AI Agent sessions** section shown (the Claude + Codex session
    /// rows). Named `showClaudeStatus` for backward compatibility with the persisted preference key;
    /// there is no longer a textual status row, only the session list.
    public let showClaudeStatus: Bool

    /// Whether the user wants the "Thermal: …" status row shown.
    public let showThermalStatus: Bool

    /// Whether the **Claude Limits** section should render (docs/decisions/0016-claude-usage-limits.md).
    /// This is the *effective* flag the view passes in — i.e. the feature is enabled **and** there is
    /// either usage data or a meaningful unavailable/stale message to show. Defaults to `false` so
    /// every existing call site and its divider logic is byte-for-byte unchanged when the feature is off.
    public let showClaudeLimits: Bool

    /// Whether the **Codex Limits** section should render (docs/decisions/0017-codex-session-support.md).
    /// The *effective* flag: the feature is enabled **and** there is data or a meaningful message.
    /// Sits directly beneath Claude Limits. Defaults to `false` so callers/tests that don't use it are
    /// unaffected.
    public let showCodexLimits: Bool

    public init(
        showClaudeStatus: Bool,
        showThermalStatus: Bool,
        showClaudeLimits: Bool = false,
        showCodexLimits: Bool = false
    ) {
        self.showClaudeStatus = showClaudeStatus
        self.showThermalStatus = showThermalStatus
        self.showClaudeLimits = showClaudeLimits
        self.showCodexLimits = showCodexLimits
    }

    /// Whether the AI Agent sessions section should appear in the main menu.
    public var isClaudeRowVisible: Bool { showClaudeStatus }

    /// Whether the Claude Limits section should appear in the main menu.
    public var isClaudeLimitsRowVisible: Bool { showClaudeLimits }

    /// Whether the Codex Limits section should appear in the main menu.
    public var isCodexLimitsRowVisible: Bool { showCodexLimits }

    /// Whether the Thermal status row should appear in the main menu.
    public var isThermalRowVisible: Bool { showThermalStatus }

    // The four status sections render top-to-bottom in this fixed order:
    //   1. Claude Limits   2. Codex Limits   3. AI Agent sessions   4. Thermal pressure
    // (Section 3 is the session list shown directly — there is no aggregate agent-status row.)
    // A divider is drawn *above* each visible section that has another visible section above it —
    // i.e. between every pair of adjacent visible sections — and one divider below the last visible
    // section (before Sleep prevention). This "divider-before-each-visible-section-except-the-first"
    // rule makes doubled or stray separators impossible for any combination of toggles.

    /// Whether a divider sits **above** the Codex Limits section — between it and Claude Limits.
    /// Shown only when both Limits sections are visible (Claude Limits is the only section above it).
    public var isDividerAboveCodexLimitsRow: Bool {
        isCodexLimitsRowVisible && isClaudeLimitsRowVisible
    }

    /// Whether a divider sits **above** the AI Agent sessions section — between it and whichever
    /// Limits section is visible above it. Shown when the section is visible and at least one Limits
    /// section above it is too. (`isClaudeRowVisible` names the sessions section for compatibility.)
    public var isDividerAboveClaudeRow: Bool {
        isClaudeRowVisible && (isClaudeLimitsRowVisible || isCodexLimitsRowVisible)
    }

    /// Whether a divider sits **above** the Thermal row — between it and whichever section above it is
    /// visible. Shown when Thermal is visible and any of the three sections above it is too.
    public var isDividerAboveThermalRow: Bool {
        isThermalRowVisible && (isClaudeLimitsRowVisible || isCodexLimitsRowVisible || isClaudeRowVisible)
    }

    /// Whether the divider that separates the status sections from Sleep prevention should appear.
    /// Shown when at least one status section is visible, so hiding them all never leaves an empty
    /// section or a doubled separator.
    public var isStatusDividerVisible: Bool {
        isClaudeLimitsRowVisible || isCodexLimitsRowVisible || isClaudeRowVisible || isThermalRowVisible
    }
}
