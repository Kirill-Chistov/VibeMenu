import Foundation

// Source selection + last-known-good persistence for the Claude usage-limit section
// (docs/decisions/0016-claude-usage-limits.md).
//
// Two local sources feed the same normalised model:
//   * Claude **Code** — the opt-in statusLine capture (`FileClaudeUsageLimitReader`), always all-models.
//   * Claude **Desktop** — the local HTTP cache (`ClaudeDesktopUsageCacheReader`), may add per-model rows.
//
// The user picks a mode in Settings; `CompositeClaudeUsageLimitReader` applies it. Because the Desktop
// cache body is intermittent — Chromium serves a 200 with the full body, then revalidates with empty
// 304 bodies until the next refresh — a naive Desktop reader would blink between data and "unavailable".
// So we persist the last good Desktop decode to a VibeMenu-owned file and fall back to it (aged, shown
// as "stale") when a live scan finds no body. Only normalised rows are persisted: no org UUID, no raw
// cache bytes, no cost.

// MARK: - Last-known-good store

/// Persists the most recent Desktop snapshot to VibeMenu's own Application Support subtree so a later
/// launch (or an empty-cache tick) can still show the last real numbers, aged and flagged stale.
/// Thread-safe and fail-closed: any read/write/decoding error is swallowed.
public final class ClaudeUsageLimitSnapshotStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    /// The last snapshot written, so repeated saves of an unchanged value skip the disk write. The
    /// composite reader calls `save` on every poll tick while Desktop data is live; without this it
    /// would rewrite the identical file every few seconds.
    private var lastSaved: ClaudeUsageLimitSnapshot?

    public init(url: URL = ClaudeUsageLimitSnapshotStore.defaultURL) {
        self.url = url
    }

    /// `~/Library/Application Support/VibeMenu/ClaudeUsage/desktop-snapshot.json`.
    public static var defaultURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("VibeMenu/ClaudeUsage", isDirectory: true)
            .appendingPathComponent("desktop-snapshot.json", isDirectory: false)
    }

    public func save(_ snapshot: ClaudeUsageLimitSnapshot) {
        guard snapshot.hasData else { return }
        lock.lock(); defer { lock.unlock() }
        guard snapshot != lastSaved else { return }   // skip the write when nothing changed
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        lastSaved = snapshot
    }

    public func load() -> ClaudeUsageLimitSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ClaudeUsageLimitSnapshot.self, from: data),
              snapshot.hasData
        else { return nil }
        return snapshot
    }
}

// MARK: - Composite reader

/// Applies the user's source mode over the two readers, with Desktop last-known-good fallback and the
/// "Auto" preference (fresh Desktop → fresh Claude Code → whichever stale snapshot is newer).
public final class CompositeClaudeUsageLimitReader: ClaudeUsageLimitReading, @unchecked Sendable {
    private let mode: @Sendable () -> ClaudeUsageLimitSourceMode
    private let desktop: ClaudeUsageLimitReading
    private let statusLine: ClaudeUsageLimitReading
    private let store: ClaudeUsageLimitSnapshotStore?
    private let now: @Sendable () -> Date

    public init(
        mode: @escaping @Sendable () -> ClaudeUsageLimitSourceMode,
        desktop: ClaudeUsageLimitReading = ClaudeDesktopUsageCacheReader(),
        statusLine: ClaudeUsageLimitReading = FileClaudeUsageLimitReader(),
        store: ClaudeUsageLimitSnapshotStore? = ClaudeUsageLimitSnapshotStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.mode = mode
        self.desktop = desktop
        self.statusLine = statusLine
        self.store = store
        self.now = now
    }

    public func readSnapshot() -> ClaudeUsageLimitSnapshot {
        switch mode() {
        case .claudeCode: return statusLine.readSnapshot()
        case .desktopCache: return desktopWithFallback()
        case .auto: return auto()
        }
    }

    /// Live Desktop scan when it has a body (persisted as last-good), else the stored last-good.
    private func desktopWithFallback() -> ClaudeUsageLimitSnapshot {
        let live = desktop.readSnapshot()
        if live.hasData {
            store?.save(live)
            return live
        }
        return store?.load() ?? .unavailable
    }

    /// Auto: prefer a fresh Desktop snapshot (richer — may carry per-model rows); otherwise a fresh
    /// Claude Code snapshot; if neither is fresh, show whichever has data and the newer capture.
    private func auto() -> ClaudeUsageLimitSnapshot {
        let current = now()
        let desktopSnapshot = desktopWithFallback()
        let claudeCode = statusLine.readSnapshot()

        if isFresh(desktopSnapshot, at: current) { return desktopSnapshot }
        if isFresh(claudeCode, at: current) { return claudeCode }
        return newerWithData(desktopSnapshot, claudeCode)
    }

    private func isFresh(_ snapshot: ClaudeUsageLimitSnapshot, at date: Date) -> Bool {
        if case .fresh = snapshot.status(now: date) { return true }
        return false
    }

    /// Pick the snapshot with data and the newer capture; ties (and both-nil timestamps) favour the
    /// richer Desktop snapshot.
    private func newerWithData(
        _ desktopSnapshot: ClaudeUsageLimitSnapshot, _ claudeCode: ClaudeUsageLimitSnapshot
    ) -> ClaudeUsageLimitSnapshot {
        switch (desktopSnapshot.hasData, claudeCode.hasData) {
        case (true, false): return desktopSnapshot
        case (false, true): return claudeCode
        case (false, false): return .unavailable
        case (true, true):
            let desktopTime = desktopSnapshot.capturedAt ?? .distantPast
            let claudeCodeTime = claudeCode.capturedAt ?? .distantPast
            return claudeCodeTime > desktopTime ? claudeCode : desktopSnapshot
        }
    }
}
