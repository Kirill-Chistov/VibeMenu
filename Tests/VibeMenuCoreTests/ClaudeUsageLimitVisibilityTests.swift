import Foundation
import Testing
@testable import VibeMenuCore

// Per-row visibility tests for the Claude usage-limit menu section (docs/decisions/0016). Pure /
// synthetic — no real account data. We verify the stable normalized ids, the show-by-default posture,
// menu filtering, persistence round-trips, the "hide Fable while 5-hour + Weekly stay visible" case,
// survival across a row disappearing and returning, and the collapsed-header summary text.

private func snapshot(_ limits: [ClaudeUsageLimit]) -> ClaudeUsageLimitSnapshot {
    ClaudeUsageLimitSnapshot(limits: limits, capturedAt: nil, sessionID: nil, source: .desktopCache)
}

private let fiveHour = ClaudeUsageLimit(kind: .fiveHour, usedPercent: 10, resetsAt: nil)
private let weekly = ClaudeUsageLimit(kind: .sevenDay, usedPercent: 20, resetsAt: nil)
private let weeklyFable = ClaudeUsageLimit(kind: .sevenDay, usedPercent: 30, resetsAt: nil, group: "Fable")

// MARK: - Stable visibility ids

@Suite("ClaudeUsageLimit.visibilityID")
struct ClaudeUsageVisibilityIDTests {
    @Test func fiveHourIsStableAndIgnoresGroup() {
        #expect(fiveHour.visibilityID == "fiveHour")
        // The 5-hour window is always all-models; any group is ignored, so the id never varies.
        #expect(ClaudeUsageLimit(kind: .fiveHour, usedPercent: 10, resetsAt: nil, group: "Opus").visibilityID == "fiveHour")
    }

    @Test func weeklyAllModelsIsStable() {
        #expect(weekly.visibilityID == "sevenDay")
        // A generic weekly bucket collapses to the all-models id (never a "sevenDay#weekly" ghost).
        for generic in ["Weekly", "all models", "session", "overall"] {
            #expect(ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil, group: generic).visibilityID == "sevenDay")
        }
    }

    @Test func perModelWeeklyIsNormalized() {
        #expect(weeklyFable.visibilityID == "sevenDay#fable")
        // Case and surrounding/internal whitespace normalize to one stable id, so a source re-emitting
        // the model name with different casing keeps the same hide/show preference.
        #expect(ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil, group: "  Fable ").visibilityID == "sevenDay#fable")
        #expect(ClaudeUsageLimit(kind: .sevenDay, usedPercent: 10, resetsAt: nil, group: "Claude Opus").visibilityID == "sevenDay#claude opus")
    }
}

// MARK: - Visibility registry

@Suite("ClaudeUsageLimitVisibility")
struct ClaudeUsageVisibilityTests {
    @Test func newRowsAreShownByDefault() {
        let visibility = ClaudeUsageLimitVisibility()
        #expect(visibility.isEmpty)
        #expect(visibility.isVisible(fiveHour))
        #expect(visibility.isVisible(weekly))
        #expect(visibility.isVisible(weeklyFable))
        #expect(visibility.visibleLimits(in: snapshot([fiveHour, weekly, weeklyFable])).count == 3)
    }

    @Test func hidingFiltersFromTheMenuSnapshot() {
        var visibility = ClaudeUsageLimitVisibility()
        visibility.setHidden(true, for: weeklyFable)
        #expect(visibility.isHidden(weeklyFable))
        let visible = visibility.visibleLimits(in: snapshot([fiveHour, weekly, weeklyFable]))
        #expect(visible.map(\.displayLabel) == ["5-hour limit", "Weekly"])
    }

    @Test func hideFableKeepsFiveHourAndWeeklyVisible() {
        // The exact case the task calls out: hide "Weekly · Fable" while the other two stay shown.
        var visibility = ClaudeUsageLimitVisibility()
        visibility.setHidden(true, id: weeklyFable.visibilityID)
        #expect(visibility.isVisible(fiveHour))
        #expect(visibility.isVisible(weekly))
        #expect(!visibility.isVisible(weeklyFable))
    }

    @Test func showingRemovesFromHiddenSet() {
        var visibility = ClaudeUsageLimitVisibility(hiddenIDs: ["sevenDay#fable"])
        #expect(visibility.isHidden(weeklyFable))
        visibility.setHidden(false, for: weeklyFable)
        #expect(!visibility.isHidden(weeklyFable))
        #expect(visibility.isEmpty)
    }

    @Test func hiddenPreferencePersistsAcrossRoundTrip() {
        var visibility = ClaudeUsageLimitVisibility()
        visibility.setHidden(true, for: weeklyFable)
        visibility.setHidden(true, for: fiveHour)
        // Encode → decode simulates an app relaunch (the string is what @AppStorage persists).
        let reloaded = ClaudeUsageLimitVisibility(persisted: visibility.persisted)
        #expect(reloaded == visibility)
        #expect(reloaded.hiddenIdentifiers == ["fiveHour", "sevenDay#fable"])
        #expect(!reloaded.isVisible(weeklyFable))
        #expect(!reloaded.isVisible(fiveHour))
        #expect(reloaded.isVisible(weekly))
    }

    @Test func persistedIsDeterministicAndSorted() {
        let visibility = ClaudeUsageLimitVisibility(hiddenIDs: ["sevenDay#fable", "fiveHour", "sevenDay"])
        #expect(visibility.persisted == "fiveHour\nsevenDay\nsevenDay#fable")
    }

    @Test func decodeToleratesBlankAndWhitespaceLines() {
        let visibility = ClaudeUsageLimitVisibility(persisted: "\n  sevenDay#fable \n\n")
        #expect(visibility.hiddenIdentifiers == ["sevenDay#fable"])
        let empty = ClaudeUsageLimitVisibility(persisted: "")
        #expect(empty.isEmpty)
    }

    @Test func disappearingAndReappearingRowKeepsPreference() {
        // Hide Fable, then the source stops reporting it (a snapshot without the row). Nothing is
        // pruned, so when Fable returns it is still hidden.
        var visibility = ClaudeUsageLimitVisibility()
        visibility.setHidden(true, for: weeklyFable)

        // Row gone: filtering a snapshot that lacks it must not crash and must keep the preference.
        let withoutFable = visibility.visibleLimits(in: snapshot([fiveHour, weekly]))
        #expect(withoutFable.map(\.displayLabel) == ["5-hour limit", "Weekly"])
        #expect(visibility.isHidden(id: "sevenDay#fable"))

        // Row returns: still hidden (preference remembered).
        let withFable = visibility.visibleLimits(in: snapshot([fiveHour, weekly, weeklyFable]))
        #expect(withFable.map(\.displayLabel) == ["5-hour limit", "Weekly"])
    }

    @Test func allRowsHiddenYieldsEmptyVisibleList() {
        var visibility = ClaudeUsageLimitVisibility()
        for limit in [fiveHour, weekly, weeklyFable] { visibility.setHidden(true, for: limit) }
        #expect(visibility.visibleLimits(in: snapshot([fiveHour, weekly, weeklyFable])).isEmpty)
    }
}

// MARK: - Collapsed settings header summary

@Suite("ClaudeUsageLimitsSummary.collapsedHeader")
struct ClaudeUsageSummaryTests {
    @Test func offWhenDisabled() {
        #expect(ClaudeUsageLimitsSummary.collapsedHeader(enabled: false, sourceName: "Claude Desktop", freshness: "live") == "Off")
    }

    @Test func joinsOnSourceAndFreshness() {
        #expect(
            ClaudeUsageLimitsSummary.collapsedHeader(enabled: true, sourceName: "Claude Desktop", freshness: "live")
                == "On · Claude Desktop · live"
        )
    }

    @Test func toleratesMissingParts() {
        #expect(ClaudeUsageLimitsSummary.collapsedHeader(enabled: true, sourceName: nil, freshness: nil) == "On")
        #expect(ClaudeUsageLimitsSummary.collapsedHeader(enabled: true, sourceName: nil, freshness: "Waiting for data") == "On · Waiting for data")
        #expect(ClaudeUsageLimitsSummary.collapsedHeader(enabled: true, sourceName: "", freshness: "") == "On")
    }
}
