import Foundation
import Observation

// Observable surface for the Codex usage-limit section (docs/decisions/0017-codex-session-support.md).
//
// Mirrors `ClaudeUsageLimitModel`: a thin timer provider gathers the snapshot from the read-only
// rollout adapter and republishes it through an `@Observable` model the menu reads. **Display-only**
// — like the Claude usage section and unlike detection, it never touches the keep-awake loop, so a
// Codex reading can never keep the Mac awake. Gated by an injected `isEnabled` closure consulted
// **before any file access**, so with the feature off (the default) each tick is a single bool check
// touching no file.

// MARK: - Provider protocol

/// Observes the Codex usage-limit rollouts and reports snapshots. The seam lets the model be driven
/// by a fake in tests with no timer or real files.
public protocol CodexUsageLimitObserving: AnyObject {
    /// The most recently read snapshot (`.unavailable` before the first refresh / when disabled).
    var snapshot: CodexUsageLimitSnapshot { get }

    /// Begin observing. `onSnapshot` is called on the main queue with the first snapshot, then again
    /// whenever it changes. Calling `start` again re-subscribes.
    func start(onSnapshot: @escaping @Sendable (CodexUsageLimitSnapshot) -> Void)

    /// Stop observing and release the timer.
    func stop()
}

// MARK: - Real provider

/// Coarse periodic refresh that reads the Codex usage snapshot via `CodexUsageLimitReading` and
/// publishes it on change. Off (the default) ⇒ zero file I/O per tick.
///
/// Concurrency: `@unchecked Sendable` — mutable state is guarded by `lock`; the timer fires on a
/// private utility queue and delivers `onSnapshot` on the main queue.
public final class CodexUsageLimitProvider: CodexUsageLimitObserving, @unchecked Sendable {
    /// Display-only refresh cadence. The reading changes at most once per ChatGPT turn; 30 s avoids
    /// repeatedly scanning rollouts while keeping this planning-only surface reasonably current.
    public static let refreshInterval: TimeInterval = 30
    public static let refreshLeeway: TimeInterval = 1

    private let reader: CodexUsageLimitReading
    private let isEnabled: @Sendable () -> Bool
    private let interval: TimeInterval
    private let leeway: TimeInterval
    private let queue = DispatchQueue(
        label: "com.kirillchistov.VibeMenu.codex-usage", qos: .utility
    )
    private let lock = NSLock()
    private var _snapshot: CodexUsageLimitSnapshot = .unavailable
    private var onSnapshot: (@Sendable (CodexUsageLimitSnapshot) -> Void)?
    private var didEmit = false
    private var timer: DispatchSourceTimer?

    /// `interval`/`leeway` default to the display-only production cadence; they are injectable only so a
    /// test can drive several ticks quickly (they are never varied in the app).
    public init(
        reader: CodexUsageLimitReading = CodexUsageLimitReader(),
        isEnabled: @escaping @Sendable () -> Bool,
        interval: TimeInterval = CodexUsageLimitProvider.refreshInterval,
        leeway: TimeInterval = CodexUsageLimitProvider.refreshLeeway
    ) {
        self.reader = reader
        self.isEnabled = isEnabled
        self.interval = interval
        self.leeway = leeway
    }

    public var snapshot: CodexUsageLimitSnapshot {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    public func start(onSnapshot: @escaping @Sendable (CodexUsageLimitSnapshot) -> Void) {
        stop()
        lock.lock()
        self.onSnapshot = onSnapshot
        self.didEmit = false
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: interval,
            leeway: .milliseconds(Int(leeway * 1000))
        )
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        onSnapshot = nil
        lock.unlock()
    }

    deinit { stop() }

    /// One refresh tick: when disabled, publish `.unavailable` without touching the filesystem; when
    /// enabled, read the snapshot. Emits the first value once, then only on change.
    private func refresh() {
        let newSnapshot = isEnabled() ? reader.readSnapshot() : .unavailable

        lock.lock()
        let shouldEmit = !didEmit || newSnapshot != _snapshot
        didEmit = true
        _snapshot = newSnapshot
        let callback = onSnapshot
        lock.unlock()

        if shouldEmit, let callback {
            DispatchQueue.main.async { callback(newSnapshot) }
        }
    }
}

// MARK: - Observable model

/// Observable app-state object that feeds the menu the current Codex usage-limit snapshot.
///
/// `@MainActor` because it backs SwiftUI; `@Observable` so the `MenuBarExtra` re-renders when the
/// snapshot changes. Observation is started once at app launch; the view's `TimelineView` re-derives
/// the reset countdowns + staleness from the absolute timestamps as time passes.
@MainActor
@Observable
public final class CodexUsageLimitModel {
    /// The current snapshot (`.unavailable` until the first refresh, or whenever the feature is off /
    /// no data exists).
    public private(set) var snapshot: CodexUsageLimitSnapshot

    @ObservationIgnored private let provider: CodexUsageLimitObserving
    @ObservationIgnored private var isObserving = false

    public init(provider: CodexUsageLimitObserving) {
        self.provider = provider
        self.snapshot = provider.snapshot
    }

    /// Start observing. Idempotent, so it is safe to call unconditionally at app launch.
    public func start() {
        guard !isObserving else { return }
        isObserving = true
        provider.start(onSnapshot: { [weak self] newValue in
            MainActor.assumeIsolated {
                self?.snapshot = newValue
            }
        })
    }

    /// Stop observing. A later `start()` re-subscribes.
    public func stop() {
        isObserving = false
        provider.stop()
    }
}
