import Foundation
import Testing
@testable import VibeMenuCore

// Uses Swift Testing (see ThermalStatusTests). `MenuVisibility` is a pure, I/O-free
// value type, so these tests need no fakes, defaults, or SwiftUI — they just assert
// the deterministic mapping from the visibility preferences to the row/divider display
// decisions. The status sections render top-to-bottom as: Claude Limits, Session Radar /
// Claude status, Thermal pressure (docs/decisions/0016 put Limits on top), with a divider
// above each visible section that has another visible section above it, plus one divider
// below the last visible section (before Sleep prevention).

@Suite("MenuVisibility row visibility")
struct MenuVisibilityRowTests {

    @Test("Defaults (both on) show Claude and Thermal rows")
    func defaultsShowBothRows() {
        let v = MenuVisibility(showClaudeStatus: true, showThermalStatus: true)
        #expect(v.isClaudeRowVisible)
        #expect(v.isThermalRowVisible)
    }

    @Test("Hiding Claude keeps Thermal visible")
    func hidingClaudeKeepsThermal() {
        let v = MenuVisibility(showClaudeStatus: false, showThermalStatus: true)
        #expect(!v.isClaudeRowVisible)
        #expect(v.isThermalRowVisible)
    }

    @Test("Hiding Thermal keeps Claude visible")
    func hidingThermalKeepsClaude() {
        let v = MenuVisibility(showClaudeStatus: true, showThermalStatus: false)
        #expect(v.isClaudeRowVisible)
        #expect(!v.isThermalRowVisible)
    }

    @Test("Hiding both hides both status rows")
    func hidingBothHidesBoth() {
        let v = MenuVisibility(showClaudeStatus: false, showThermalStatus: false)
        #expect(!v.isClaudeRowVisible)
        #expect(!v.isThermalRowVisible)
    }
}

@Suite("MenuVisibility status divider")
struct MenuVisibilityDividerTests {

    @Test("Divider is visible when both status rows are visible")
    func dividerVisibleWithBoth() {
        #expect(MenuVisibility(showClaudeStatus: true, showThermalStatus: true).isStatusDividerVisible)
    }

    @Test("Divider is visible when only Claude is visible")
    func dividerVisibleWithClaudeOnly() {
        #expect(MenuVisibility(showClaudeStatus: true, showThermalStatus: false).isStatusDividerVisible)
    }

    @Test("Divider is visible when only Thermal is visible")
    func dividerVisibleWithThermalOnly() {
        #expect(MenuVisibility(showClaudeStatus: false, showThermalStatus: true).isStatusDividerVisible)
    }

    @Test("Divider is hidden when all status sections are hidden")
    func dividerHiddenWithNeither() {
        #expect(!MenuVisibility(showClaudeStatus: false, showThermalStatus: false, showClaudeLimits: false).isStatusDividerVisible)
    }

    /// Fix 2: when the user hides every session row the app folds the AI Agent section's effective
    /// visibility to `false` (via `agentSessionsHasContent`), i.e. `showClaudeStatus: false` here. The
    /// section and its dividers must vanish cleanly, leaving the remaining sections' dividers correct —
    /// no empty box, no stray/doubled separator.
    @Test("Session section with no visible rows: its dividers vanish, neighbours stay correct")
    func sessionSectionCollapsedWhenAllRowsHidden() {
        // All rows hidden, but Thermal still on: the only inner divider is the one above Sleep.
        let onlyThermal = MenuVisibility(showClaudeStatus: false, showThermalStatus: true)
        #expect(!onlyThermal.isClaudeRowVisible)
        #expect(!onlyThermal.isDividerAboveClaudeRow)
        #expect(!onlyThermal.isDividerAboveThermalRow)   // nothing above Thermal → no stray divider
        #expect(onlyThermal.isStatusDividerVisible)

        // All rows hidden AND Thermal off, Claude Limits still on: Limits stands alone, no session gap.
        let onlyLimits = MenuVisibility(showClaudeStatus: false, showThermalStatus: false, showClaudeLimits: true)
        #expect(!onlyLimits.isDividerAboveClaudeRow)
        #expect(!onlyLimits.isDividerAboveThermalRow)
        #expect(onlyLimits.isStatusDividerVisible)

        // Everything gone (rows hidden, nothing else on): no dividers at all.
        let none = MenuVisibility(showClaudeStatus: false, showThermalStatus: false, showClaudeLimits: false, showCodexLimits: false)
        #expect(!none.isStatusDividerVisible)
    }
}

@Suite("MenuVisibility divider above Thermal")
struct MenuVisibilityThermalDividerTests {

    @Test("Divider above Thermal is visible when Claude (above it) and Thermal are visible")
    func dividerVisibleWithClaudeAndThermal() {
        #expect(MenuVisibility(showClaudeStatus: true, showThermalStatus: true).isDividerAboveThermalRow)
    }

    @Test("Hidden when only Claude is visible (nothing below to separate)")
    func hiddenWithClaudeOnly() {
        #expect(!MenuVisibility(showClaudeStatus: true, showThermalStatus: false).isDividerAboveThermalRow)
    }

    @Test("Hidden when Thermal is the only visible section (nothing above it)")
    func hiddenWithThermalOnly() {
        #expect(!MenuVisibility(showClaudeStatus: false, showThermalStatus: true, showClaudeLimits: false).isDividerAboveThermalRow)
    }

    @Test("Hidden when both status rows are hidden")
    func hiddenWithNeither() {
        #expect(!MenuVisibility(showClaudeStatus: false, showThermalStatus: false).isDividerAboveThermalRow)
    }

    @Test("Visible when Limits (above it) and Thermal are visible, even with Claude hidden")
    func visibleWithLimitsAndThermalNoClaude() {
        let v = MenuVisibility(showClaudeStatus: false, showThermalStatus: true, showClaudeLimits: true)
        #expect(v.isDividerAboveThermalRow)
    }
}

@Suite("MenuVisibility Claude Limits section (top of the stack)")
struct MenuVisibilityClaudeLimitsTests {

    @Test("Off by default: no limits row, no divider above the Claude row")
    func offByDefault() {
        let v = MenuVisibility(showClaudeStatus: true, showThermalStatus: true)   // showClaudeLimits defaults false
        #expect(!v.isClaudeLimitsRowVisible)
        #expect(!v.isDividerAboveClaudeRow)
        // Claude and Thermal both visible → the divider above Thermal separates them.
        #expect(v.isDividerAboveThermalRow)
    }

    @Test("All three visible: a divider above Claude and above Thermal, none doubled")
    func allThreeVisible() {
        let v = MenuVisibility(showClaudeStatus: true, showThermalStatus: true, showClaudeLimits: true)
        #expect(v.isClaudeLimitsRowVisible)
        #expect(v.isDividerAboveClaudeRow)       // Limits → Claude
        #expect(v.isDividerAboveThermalRow)      // Claude → Thermal
        #expect(v.isStatusDividerVisible)        // divider above Sleep
    }

    @Test("Limits visible while Claude hidden: no divider above the Claude row")
    func limitsWithoutClaude() {
        let v = MenuVisibility(showClaudeStatus: false, showThermalStatus: true, showClaudeLimits: true)
        #expect(!v.isDividerAboveClaudeRow)      // Claude row not shown
        #expect(v.isDividerAboveThermalRow)      // Limits → Thermal
        #expect(v.isStatusDividerVisible)
    }

    @Test("Limits the only visible section: no inner dividers, still a divider above Sleep")
    func limitsOnly() {
        let v = MenuVisibility(showClaudeStatus: false, showThermalStatus: false, showClaudeLimits: true)
        #expect(v.isClaudeLimitsRowVisible)
        #expect(!v.isDividerAboveClaudeRow)
        #expect(!v.isDividerAboveThermalRow)
        #expect(v.isStatusDividerVisible)
    }

    @Test("Everything hidden: no dividers at all")
    func allHidden() {
        let v = MenuVisibility(showClaudeStatus: false, showThermalStatus: false, showClaudeLimits: false)
        #expect(!v.isStatusDividerVisible)
        #expect(!v.isDividerAboveClaudeRow)
        #expect(!v.isDividerAboveThermalRow)
    }
}

@Suite("MenuVisibility — Codex Limits section")
struct MenuVisibilityCodexLimitsTests {

    @Test("Codex Limits section shows only when enabled")
    func codexLimitsVisibility() {
        #expect(MenuVisibility(showClaudeStatus: true, showThermalStatus: true, showCodexLimits: true).isCodexLimitsRowVisible)
        #expect(!MenuVisibility(showClaudeStatus: true, showThermalStatus: true, showCodexLimits: false).isCodexLimitsRowVisible)
    }

    @Test("Divider above Codex Limits only when Claude Limits sits above it")
    func dividerAboveCodex() {
        // Both Limits sections visible → divider between them.
        #expect(MenuVisibility(showClaudeStatus: false, showThermalStatus: false, showClaudeLimits: true, showCodexLimits: true).isDividerAboveCodexLimitsRow)
        // Codex Limits alone (top of stack) → no divider above it.
        #expect(!MenuVisibility(showClaudeStatus: false, showThermalStatus: false, showClaudeLimits: false, showCodexLimits: true).isDividerAboveCodexLimitsRow)
    }

    @Test("Divider above the AI Agent row appears when either Limits section is above it")
    func dividerAboveClaudeRowFromEitherLimits() {
        // Only Codex Limits above the AI Agent row → still a divider.
        #expect(MenuVisibility(showClaudeStatus: true, showThermalStatus: false, showClaudeLimits: false, showCodexLimits: true).isDividerAboveClaudeRow)
        // Neither Limits section → no divider above the AI Agent row.
        #expect(!MenuVisibility(showClaudeStatus: true, showThermalStatus: false, showClaudeLimits: false, showCodexLimits: false).isDividerAboveClaudeRow)
    }

    @Test("Codex Limits as the only visible section still draws the status divider (no empty section)")
    func codexLimitsOnlyStatusDivider() {
        let v = MenuVisibility(showClaudeStatus: false, showThermalStatus: false, showClaudeLimits: false, showCodexLimits: true)
        #expect(v.isStatusDividerVisible)
        #expect(!v.isDividerAboveCodexLimitsRow)   // nothing above it → no stray divider
        #expect(!v.isDividerAboveThermalRow)
    }

    @Test("Thermal divider counts Codex Limits as a section above it")
    func thermalDividerSeesCodexLimits() {
        #expect(MenuVisibility(showClaudeStatus: false, showThermalStatus: true, showClaudeLimits: false, showCodexLimits: true).isDividerAboveThermalRow)
    }

    /// The exact reported layout: Claude Limits + Codex Limits on, the AI Agent sessions section has no
    /// visible rows (so `agentSessionsHasContent` folds `showClaudeStatus` to false), Thermal on. The
    /// session section and its dividers must vanish so Codex Limits is followed closely by Thermal with
    /// only the normal single divider — no empty band where the sessions used to be.
    @Test("Reported gap: both Limits on, sessions with no visible rows, Thermal on → tight dividers")
    func reportedGapScenarioCollapsesSessionSection() {
        let v = MenuVisibility(showClaudeStatus: false, showThermalStatus: true, showClaudeLimits: true, showCodexLimits: true)
        #expect(!v.isClaudeRowVisible)            // no session section instantiated
        #expect(!v.isDividerAboveClaudeRow)       // no divider above the absent section
        #expect(v.isDividerAboveCodexLimitsRow)   // Claude Limits → Codex Limits divider stays
        #expect(v.isDividerAboveThermalRow)       // Codex Limits → Thermal: the one normal divider
        #expect(v.isStatusDividerVisible)         // divider above Sleep prevention
    }
}

@Suite("MenuVisibility determinism")
struct MenuVisibilityDeterminismTests {

    /// The visibility logic is pure: identical inputs always yield identical outputs,
    /// and evaluating the same instance repeatedly never changes it.
    @Test("Visibility logic is deterministic and pure")
    func deterministicAndPure() {
        for limits in [true, false] {
            for claude in [true, false] {
                for thermal in [true, false] {
                    let a = MenuVisibility(showClaudeStatus: claude, showThermalStatus: thermal, showClaudeLimits: limits)
                    let b = MenuVisibility(showClaudeStatus: claude, showThermalStatus: thermal, showClaudeLimits: limits)
                    #expect(a == b)
                    #expect(a.isClaudeRowVisible == b.isClaudeRowVisible)
                    #expect(a.isThermalRowVisible == b.isThermalRowVisible)
                    #expect(a.isStatusDividerVisible == b.isStatusDividerVisible)
                    #expect(a.isDividerAboveClaudeRow == b.isDividerAboveClaudeRow)
                    #expect(a.isDividerAboveThermalRow == b.isDividerAboveThermalRow)
                    // Re-reading the same instance is stable.
                    #expect(a.isStatusDividerVisible == a.isStatusDividerVisible)
                }
            }
        }
    }
}
