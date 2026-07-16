import Foundation
import Testing
@testable import VibeMenuCore

// Source-selection + last-known-good persistence tests (docs/decisions/0016-claude-usage-limits.md).
// All synthetic: fake readers return fixed snapshots so the selection logic (mode routing, Auto's
// fresh-Desktop-then-Claude-Code preference, and the Desktop empty-cache fallback) is verified
// deterministically with an injected clock, no files or real cache involved.

private let now = Date(timeIntervalSince1970: 2_000_000)

private func snap(
    source: ClaudeUsageLimitSource, ageSeconds: TimeInterval, percent: Double = 20
) -> ClaudeUsageLimitSnapshot {
    ClaudeUsageLimitSnapshot(
        limits: [ClaudeUsageLimit(kind: .fiveHour, usedPercent: percent, resetsAt: nil)],
        capturedAt: now.addingTimeInterval(-ageSeconds), sessionID: nil, source: source
    )
}

private final class FakeReader: ClaudeUsageLimitReading, @unchecked Sendable {
    let snapshot: ClaudeUsageLimitSnapshot
    init(_ snapshot: ClaudeUsageLimitSnapshot) { self.snapshot = snapshot }
    func readSnapshot() -> ClaudeUsageLimitSnapshot { snapshot }
}

private func tempStore() -> ClaudeUsageLimitSnapshotStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("vm-store-\(UUID().uuidString).json")
    return ClaudeUsageLimitSnapshotStore(url: url)
}

// MARK: - Store

@Suite("ClaudeUsageLimitSnapshotStore")
struct SnapshotStoreTests {
    @Test func savesAndLoadsRoundTrip() {
        let store = tempStore()
        let snapshot = snap(source: .desktopCache, ageSeconds: 60, percent: 33)
        store.save(snapshot)
        #expect(store.load() == snapshot)
    }

    @Test func loadNilWhenMissing() {
        #expect(tempStore().load() == nil)
    }

    @Test func doesNotPersistEmptySnapshot() {
        let store = tempStore()
        store.save(.unavailable)
        #expect(store.load() == nil)
    }

    /// A full Desktop snapshot (5-hour + weekly all-models + per-model) must round-trip through the
    /// last-known-good store without dropping the 5-hour row, so an empty-cache (304) tick can still
    /// show it aged/stale rather than losing it.
    @Test func multiRowSnapshotRoundTripsKeepingFiveHour() {
        let store = tempStore()
        let full = ClaudeUsageLimitSnapshot(
            limits: [
                ClaudeUsageLimit(kind: .fiveHour, usedPercent: 14, resetsAt: now),
                ClaudeUsageLimit(kind: .sevenDay, usedPercent: 50, resetsAt: now),
                ClaudeUsageLimit(kind: .sevenDay, usedPercent: 59, resetsAt: now, group: "Fable"),
            ],
            capturedAt: now, sessionID: nil, source: .desktopCache
        )
        store.save(full)
        let loaded = store.load()
        #expect(loaded == full)
        #expect(loaded?.limits.contains { $0.kind == .fiveHour } == true)
        #expect(loaded?.limits.map(\.displayLabel) == ["5-hour limit", "Weekly", "Weekly · Fable"])
    }
}

// MARK: - Composite selection

@Suite("CompositeClaudeUsageLimitReader")
struct CompositeReaderTests {
    private func reader(
        mode: ClaudeUsageLimitSourceMode,
        desktop: ClaudeUsageLimitSnapshot,
        claudeCode: ClaudeUsageLimitSnapshot,
        store: ClaudeUsageLimitSnapshotStore? = nil
    ) -> CompositeClaudeUsageLimitReader {
        CompositeClaudeUsageLimitReader(
            mode: { mode },
            desktop: FakeReader(desktop),
            statusLine: FakeReader(claudeCode),
            store: store,
            now: { now }
        )
    }

    @Test func claudeCodeModeIgnoresDesktop() {
        let result = reader(
            mode: .claudeCode,
            desktop: snap(source: .desktopCache, ageSeconds: 10),
            claudeCode: snap(source: .statusLine, ageSeconds: 10, percent: 77)
        ).readSnapshot()
        #expect(result.source == .statusLine)
        #expect(result.limits.first?.usedPercent == 77)
    }

    @Test func desktopModePersistsLiveSnapshot() {
        let store = tempStore()
        let result = reader(
            mode: .desktopCache,
            desktop: snap(source: .desktopCache, ageSeconds: 5, percent: 42),
            claudeCode: .unavailable,
            store: store
        ).readSnapshot()
        #expect(result.source == .desktopCache)
        #expect(store.load()?.limits.first?.usedPercent == 42)   // persisted as last-good
    }

    @Test func desktopModeFallsBackToStoredLastGood() {
        let store = tempStore()
        store.save(snap(source: .desktopCache, ageSeconds: 3600, percent: 55))   // old last-good
        let result = reader(
            mode: .desktopCache,
            desktop: .unavailable,   // cache is empty (304)
            claudeCode: .unavailable,
            store: store
        ).readSnapshot()
        #expect(result.source == .desktopCache)
        #expect(result.limits.first?.usedPercent == 55)
        // It is honestly stale, not presented as live.
        if case .stale = result.status(now: now) {} else { Issue.record("expected stale") }
    }

    @Test func desktopModeUnavailableWithNoLiveOrStored() {
        let result = reader(
            mode: .desktopCache, desktop: .unavailable, claudeCode: .unavailable, store: tempStore()
        ).readSnapshot()
        #expect(result == .unavailable)
    }

    @Test func autoPrefersFreshDesktopOverFreshClaudeCode() {
        let result = reader(
            mode: .auto,
            desktop: snap(source: .desktopCache, ageSeconds: 30, percent: 11),
            claudeCode: snap(source: .statusLine, ageSeconds: 5, percent: 99),
            store: tempStore()
        ).readSnapshot()
        #expect(result.source == .desktopCache)   // richer source wins when both fresh
    }

    @Test func autoUsesClaudeCodeWhenDesktopStale() {
        let result = reader(
            mode: .auto,
            desktop: snap(source: .desktopCache, ageSeconds: 3600),   // stale
            claudeCode: snap(source: .statusLine, ageSeconds: 30, percent: 66),   // fresh
            store: tempStore()
        ).readSnapshot()
        #expect(result.source == .statusLine)
        #expect(result.limits.first?.usedPercent == 66)
    }

    @Test func autoPicksNewerWhenBothStale() {
        let result = reader(
            mode: .auto,
            desktop: snap(source: .desktopCache, ageSeconds: 3600),        // older
            claudeCode: snap(source: .statusLine, ageSeconds: 1200, percent: 5),   // newer, still stale
            store: tempStore()
        ).readSnapshot()
        #expect(result.source == .statusLine)   // newer capture wins
    }

    @Test func autoUsesWhicheverHasDataWhenOnlyOneDoes() {
        let result = reader(
            mode: .auto,
            desktop: .unavailable,
            claudeCode: snap(source: .statusLine, ageSeconds: 3600, percent: 8),
            store: tempStore()
        ).readSnapshot()
        #expect(result.source == .statusLine)
    }

    @Test func autoUnavailableWhenNeitherHasData() {
        let result = reader(
            mode: .auto, desktop: .unavailable, claudeCode: .unavailable, store: tempStore()
        ).readSnapshot()
        #expect(result == .unavailable)
    }
}
