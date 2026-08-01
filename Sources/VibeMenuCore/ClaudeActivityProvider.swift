import Foundation
import Darwin
import os

// Claude detection L1 + L2, v0.1 (docs/decisions/0005-v0-1-scope.md item 2,
// docs/decisions/0008-claude-heartbeat-detection.md). This adapter only gathers metadata and
// computes state; the app-level power model consumes `.active` as the automation trigger.
//
// Layering (mirrors the thermal/power slices): the *decision* logic is pure and lives in
// ClaudeActivityState.evaluate(heartbeats:signals:...); this file is a **thin adapter**
// that gathers the inputs from the real system and feeds them to that pure function.
// Inputs, in the order the L2 decision prefers them:
//   1. VibeMenu-owned hook heartbeat files (L2) — read first.
//   2. Process presence (a `claude`-named process) — existence/crash cross-check.
//   3. Session-file *mtime* under ~/.claude (L1) — fallback when no heartbeat exists.
// The adapter itself is intentionally not unit tested against the live machine — the
// tested surface is the pure evaluator, the malformed-safe reader, and the observable
// model with a fake provider.
//
// Hard privacy rule (docs/PRIVACY.md, AGENTS.md §6): the heartbeat files are VibeMenu's own
// and carry only {schemaVersion, updatedAt, event, sessionID, project}; ~/.claude is read for
// *mtime* only in the detection walk. The one narrow exception is the Session Radar title:
// `TranscriptTitleResolver` opens the matching `<session>.jsonl` to read ONLY its
// `custom-title`/`ai-title` record — never prompt/response/`lastPrompt`/tool/message content
// (docs/decisions/0013-session-title-and-dismiss.md). No paths, ids, titles, or contents are
// logged; nothing leaves the Mac.

// MARK: - Protocol

/// Observes Claude Code detection state and reports it as a `ClaudeActivityState`.
///
/// The seam exists so the observable model can be driven by a fake in tests without a
/// real `claude` process or `~/.claude` directory.
public protocol ClaudeActivityObserving: AnyObject {
    /// The most recently computed detection state (`.unknown` before the first refresh).
    var state: ClaudeActivityState { get }

    /// Begin observing. `onChange` is invoked on the main queue with the first computed
    /// value, then again whenever the state changes. `onAutomation` is invoked on the main
    /// queue with the first computed keep-awake intent, then again whenever the intent
    /// changes — it is a **separate** stream from `onChange` because the automation intent
    /// (hold vs release) can change at a different time than the display state (e.g. the
    /// quiet-hold cap elapsing while the display already reads Idle). `onSessions` is invoked
    /// on the main queue with the first computed Session Radar list, then again whenever it
    /// changes — the per-session breakdown for the radar UI, a display-only view of the same
    /// heartbeats (docs/decisions/0011-session-radar.md). `onDiagnostics` receives a
    /// privacy-safe, path-free debug summary (see `ClaudeActivityDiagnostics.summary`) on the
    /// main queue; in Release builds it is never called (DEBUG-only plumbing), so it is safe
    /// to pass a no-op. Calling `start` again re-subscribes.
    func start(
        onChange: @escaping @Sendable (ClaudeActivityState) -> Void,
        onAutomation: @escaping @Sendable (ClaudeAutomationIntent) -> Void,
        onSessions: @escaping @Sendable ([ClaudeSession]) -> Void,
        onDiagnostics: @escaping @Sendable (String) -> Void
    )

    /// Stop observing and release any timer.
    func stop()
}

// MARK: - Real provider

/// Real L1 + L2 provider: a **coarse periodic refresh** that reads the VibeMenu-owned hook
/// heartbeat files (L2), gathers process presence and session-file mtimes (L1), then maps
/// them via `ClaudeActivityState.evaluate(heartbeats:signals:…)`.
///
/// ### Why a timer (and why it's still temporary)
///
/// The reliable working/waiting signal (the opt-in hook heartbeat, L2) is now implemented
/// and read here each tick. What remains for a fully event-driven design is retiring this
/// timer in favour of FSEvents / `DispatchSource` append tracking on the heartbeat +
/// `~/.claude` trees plus process-lifecycle observation (docs/ARCHITECTURE.md, docs/decisions/0006 &
/// 0008). Wiring that across an unknown-shaped `~/.claude/projects` tree *and* process
/// lifecycle would over-complicate this slice, so detection still uses a single coarse
/// `DispatchSourceTimer`. It is a *scheduled, coalesced wakeup with generous leeway*, not a
/// busy loop: it sleeps between fires and does bounded work each tick (one process-table read plus
/// cached heartbeat metadata checks). The wider project/session stat walk runs only while a Claude
/// process is present, when L1 can actually hold. The interval (`refreshInterval`) is a short ~2s
/// refresh so active/idle/waiting transitions feel responsive.
///
/// TODO(event-driven): replace this timer with FSEvents/`DispatchSource` append events plus
/// process-lifecycle observation so idle CPU returns to truly zero.
///
/// Concurrency: `@unchecked Sendable` — provider state is guarded by `lock`, whole refreshes by
/// `refreshLock`, and the heartbeat cache by its own lock; callbacks are delivered on the main queue.
public final class ClaudeActivityProvider: ClaudeActivityObserving, @unchecked Sendable {
    /// Temporary detection refresh interval (see the type doc). ~2s: responsive enough that
    /// `active` ⇄ `idle`/`waiting`/`notDetected` transitions feel prompt, while still a coarse,
    /// coalesced scheduled wakeup doing negligible work per tick (not a busy loop).
    /// (Was 8s; tightened for snappier detection.)
    public static let refreshInterval: TimeInterval = 2

    /// Timer leeway granted to the OS so it can coalesce the periodic wakeup with other
    /// timers (lightweight-budget friendly; docs/decisions/0006). ~0.5s keeps the refresh
    /// responsive while still allowing coalescing. (Was 2s.)
    public static let refreshLeeway: TimeInterval = 0.5
    /// Defensive bound on VibeMenu-owned heartbeat files considered per tick. The radar already
    /// prunes at 30 minutes; 400 distinct sessions inside that horizon is far beyond its UI bounds.
    static let maxHeartbeatFiles = 400

    private let recencyThreshold: TimeInterval
    private let heartbeatActiveThreshold: TimeInterval
    private let heartbeatStaleThreshold: TimeInterval
    private let quietHoldCap: TimeInterval
    private let heartbeatDirectory: URL
    private let heartbeatReader: ClaudeHeartbeatReader
    private let processChecker: @Sendable () -> Bool
    private let sessionActivityReader: @Sendable () -> Date?
    /// Resolves each session's human-readable title from its transcript title record — the one
    /// place VibeMenu opens a Claude transcript, and only for the title field
    /// (docs/decisions/0013-session-title-and-dismiss.md). Injectable; `nil` disables titles
    /// (used by tests, which never touch `~/.claude`), leaving the radar on folder-name naming.
    private let titleResolver: SessionTitleResolving?
    private let queue = DispatchQueue(
        label: "com.kirillchistov.VibeMenu.claude-detect", qos: .utility
    )
    private let refreshLock = NSLock()
    private let lock = NSLock()
    private var _state: ClaudeActivityState = .unknown
    private var _intent: ClaudeAutomationIntent = .release
    /// The Session Radar store, folded forward each tick under `lock` (it tracks per-session
    /// first-observed times across ticks). Display-only; never feeds the power loop.
    private var _sessionStore: ClaudeSessionStore
    private var _sessions: [ClaudeSession] = []
    private var onChange: (@Sendable (ClaudeActivityState) -> Void)?
    private var onAutomation: (@Sendable (ClaudeAutomationIntent) -> Void)?
    private var onSessions: (@Sendable ([ClaudeSession]) -> Void)?
    private var onDiagnostics: (@Sendable (String) -> Void)?
    private var didEmit = false
    private var didEmitIntent = false
    private var didEmitSessions = false
    private var timer: DispatchSourceTimer?

    #if DEBUG
    /// DEBUG-only diagnostics log. Emits the privacy-safe, path-free summary each tick so
    /// the newest-mtime *age* can be watched climbing (aging out) vs. resetting (still
    /// being written) in Console.app. Compiled out of Release builds entirely.
    private static let debugLogger = Logger(
        subsystem: "com.kirillchistov.VibeMenu", category: "claude-detect"
    )
    #endif

    /// The VibeMenu-owned heartbeat directory the hook script writes per-session files
    /// into: `~/Library/Application Support/VibeMenu/ClaudeHeartbeat/sessions`. These are
    /// *our* files (privacy-constrained), not Claude transcripts.
    public static var defaultHeartbeatDirectory: URL {
        let base: URL
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) {
            base = appSupport
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return base
            .appendingPathComponent("VibeMenu", isDirectory: true)
            .appendingPathComponent("ClaudeHeartbeat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public convenience init(
        recencyThreshold: TimeInterval = ClaudeActivityState.defaultRecencyThreshold,
        heartbeatActiveThreshold: TimeInterval = ClaudeActivityState.defaultHeartbeatActiveThreshold,
        heartbeatStaleThreshold: TimeInterval = ClaudeActivityState.defaultHeartbeatStaleThreshold,
        quietHoldCap: TimeInterval = ClaudeActivityState.defaultQuietHoldCap,
        heartbeatDirectory: URL? = nil,
        titleResolver: SessionTitleResolving? = TranscriptTitleResolver()
    ) {
        self.init(
            recencyThreshold: recencyThreshold,
            heartbeatActiveThreshold: heartbeatActiveThreshold,
            heartbeatStaleThreshold: heartbeatStaleThreshold,
            quietHoldCap: quietHoldCap,
            heartbeatDirectory: heartbeatDirectory,
            titleResolver: titleResolver,
            processChecker: { claudeProcessPresent() },
            sessionActivityReader: { mostRecentSessionActivity(fileManager: .default) }
        )
    }

    /// Injectable I/O seams for deterministic provider-tick tests. Internal so production callers
    /// keep the small public initializer above and cannot replace the privacy-constrained adapters.
    init(
        recencyThreshold: TimeInterval = ClaudeActivityState.defaultRecencyThreshold,
        heartbeatActiveThreshold: TimeInterval = ClaudeActivityState.defaultHeartbeatActiveThreshold,
        heartbeatStaleThreshold: TimeInterval = ClaudeActivityState.defaultHeartbeatStaleThreshold,
        quietHoldCap: TimeInterval = ClaudeActivityState.defaultQuietHoldCap,
        heartbeatDirectory: URL? = nil,
        titleResolver: SessionTitleResolving? = nil,
        processChecker: @escaping @Sendable () -> Bool,
        sessionActivityReader: @escaping @Sendable () -> Date?
    ) {
        self.recencyThreshold = recencyThreshold
        self.heartbeatActiveThreshold = heartbeatActiveThreshold
        self.heartbeatStaleThreshold = heartbeatStaleThreshold
        self.quietHoldCap = quietHoldCap
        self.heartbeatDirectory = heartbeatDirectory ?? Self.defaultHeartbeatDirectory
        self.heartbeatReader = ClaudeHeartbeatReader(
            retentionHorizon: ClaudeSessionStore.defaultPruneHorizon,
            maxFiles: Self.maxHeartbeatFiles
        )
        self.processChecker = processChecker
        self.sessionActivityReader = sessionActivityReader
        self.titleResolver = titleResolver
        // The radar store shares the detection thresholds so per-session states line up with
        // the active window and quiet-hold cap the automation path uses.
        self._sessionStore = ClaudeSessionStore(
            activeWindow: heartbeatActiveThreshold,
            quietHoldCap: quietHoldCap
        )
    }

    public var state: ClaudeActivityState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public func start(
        onChange: @escaping @Sendable (ClaudeActivityState) -> Void,
        onAutomation: @escaping @Sendable (ClaudeAutomationIntent) -> Void,
        onSessions: @escaping @Sendable ([ClaudeSession]) -> Void,
        onDiagnostics: @escaping @Sendable (String) -> Void
    ) {
        stop()
        lock.lock()
        self.onChange = onChange
        self.onAutomation = onAutomation
        self.onSessions = onSessions
        self.onDiagnostics = onDiagnostics
        self.didEmit = false
        self.didEmitIntent = false
        self.didEmitSessions = false
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // First fire immediately, then every `refreshInterval` with `refreshLeeway` so the
        // OS can coalesce the wakeup (lightweight-budget friendly; docs/decisions/0006).
        timer.schedule(
            deadline: .now(),
            repeating: Self.refreshInterval,
            leeway: .milliseconds(Int(Self.refreshLeeway * 1000))
        )
        timer.setEventHandler { [weak self] in self?.refresh(now: Date()) }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        onChange = nil
        onAutomation = nil
        onSessions = nil
        onDiagnostics = nil
        lock.unlock()
    }

    deinit { stop() }

    /// One refresh tick: read the hook heartbeat files + gather metadata-only signals,
    /// evaluate (L2), publish on change. Runs on the private utility queue.
    func refresh(now: Date) {
        refreshLock.lock()
        defer { refreshLock.unlock() }

        // L1 cannot hold without a visible process. Keep its cheap process-table check and the L2
        // heartbeat metadata walk every two seconds, but avoid the expensive ~/.claude project walk
        // entirely while the process is absent. A process appearance re-enables it on this same tick.
        let processPresent = processChecker()
        let heartbeats = heartbeatReader.readRecords(in: heartbeatDirectory, now: now)
        let signals = ClaudeActivitySignals(
            processPresent: processPresent,
            mostRecentSessionActivity: processPresent ? sessionActivityReader() : nil
        )
        let newState = ClaudeActivityState.evaluate(
            heartbeats: heartbeats,
            signals: signals,
            now: now,
            heartbeatActiveThreshold: heartbeatActiveThreshold,
            heartbeatStaleThreshold: heartbeatStaleThreshold,
            l1RecencyThreshold: recencyThreshold
        )
        // The keep-awake automation intent is computed independently of the display state
        // (docs/decisions/0010): an active heartbeat aging past the display window stays a
        // `.hold` (quiet-but-still-running) until the bounded cap, not a `.release`. With no
        // *recent* heartbeat record it degrades to the bounded L1 fallback, which is why the same
        // `heartbeatStaleThreshold` and `recencyThreshold` the display uses are passed here
        // (0010 amendment) — stale leftover files must not suppress the fallback.
        let newIntent = ClaudeActivityState.automationIntent(
            heartbeats: heartbeats,
            signals: signals,
            now: now,
            quietHoldCap: quietHoldCap,
            heartbeatStaleThreshold: heartbeatStaleThreshold,
            l1RecencyThreshold: recencyThreshold
        )

        lock.lock()
        // Fold this tick's records into the Session Radar store (display-only; it tracks
        // per-session first-observed times across ticks, so it must live behind the lock).
        _sessionStore.update(
            records: heartbeats,
            processPresent: signals.processPresent,
            now: now
        )
        let baseSessions = _sessionStore.sessions
        lock.unlock()

        // Attach each session's human-readable title (the one transcript read, title field
        // only) — done OUTSIDE our lock because the resolver performs I/O behind its own lock
        // and cache. Bounded: `baseSessions` is already pruned to the 30-min horizon, and a
        // resolved title is cached per session until its transcript's mtime changes, so an
        // unchanged transcript costs one `stat`. A `nil` resolver (tests) leaves titles unset.
        let newSessions: [ClaudeSession]
        if let titleResolver {
            newSessions = baseSessions.map { session in
                if let title = titleResolver.title(forSessionID: session.id) {
                    return session.withTitle(title)
                }
                return session
            }
        } else {
            newSessions = baseSessions
        }

        lock.lock()
        let shouldEmit = !didEmit || newState != _state
        let shouldEmitIntent = !didEmitIntent || newIntent != _intent
        let shouldEmitSessions = !didEmitSessions || newSessions != _sessions
        didEmit = true
        didEmitIntent = true
        didEmitSessions = true
        _state = newState
        _intent = newIntent
        _sessions = newSessions
        let callback = onChange
        let automationCallback = onAutomation
        let sessionsCallback = onSessions
        let diagnosticsCallback = onDiagnostics
        lock.unlock()

        // Emit the first computed value once, then only on change (avoids needless UI
        // churn every tick). Deliver on main so the @MainActor model can consume it.
        if shouldEmit, let callback {
            DispatchQueue.main.async { callback(newState) }
        }
        // Emit the automation intent on the same first-then-on-change basis. This is what
        // enforces the bounded cap: when the cap elapses the intent flips `.hold`→`.release`
        // on a later tick and is delivered here even though the display state may be
        // unchanged (still Idle).
        if shouldEmitIntent, let automationCallback {
            DispatchQueue.main.async { automationCallback(newIntent) }
        }
        // Emit the Session Radar list first-then-on-change (avoids per-tick UI churn when the
        // per-session breakdown is unchanged). Display-only; independent of the power loop.
        if shouldEmitSessions, let sessionsCallback {
            DispatchQueue.main.async { sessionsCallback(newSessions) }
        }

        #if DEBUG
        // DEBUG-only: every tick, surface the raw signals behind the decision (path-free,
        // metadata-only). Logging lets the newest-mtime age be watched climb (aging out)
        // or reset (still being written) in Console.app; the main-queue callback drives the
        // debug-only model field. Compiled out of Release, so idle Release cost is
        // unchanged (no per-tick main-queue hop).
        let diagnostics = ClaudeActivityState.diagnostics(
            heartbeats: heartbeats,
            signals: signals,
            now: now,
            heartbeatActiveThreshold: heartbeatActiveThreshold,
            heartbeatStaleThreshold: heartbeatStaleThreshold,
            l1RecencyThreshold: recencyThreshold
        )
        Self.debugLogger.debug("Claude debug: \(diagnostics.summary, privacy: .public)")
        // Also surface the keep-awake automation intent so a long silent tool/subagent
        // phase can be watched holding (quiet-but-running) vs releasing at the cap. Metadata
        // only — a single hold/release label, no paths, ids, or contents.
        Self.debugLogger.debug("Claude automation: intent=\(newIntent.rawValue, privacy: .public)")
        if let diagnosticsCallback {
            DispatchQueue.main.async { diagnosticsCallback(diagnostics.summary) }
        }
        #endif
    }

    /// Count-only cache evidence for deterministic tests and temporary local measurement. Nothing is
    /// logged in production, and no path, id, title, record, or timestamp is exposed.
    var heartbeatCacheDiagnostics: ClaudeHeartbeatCacheDiagnostics {
        heartbeatReader.cacheDiagnostics
    }

    var automationIntent: ClaudeAutomationIntent {
        lock.lock(); defer { lock.unlock() }
        return _intent
    }

    var sessions: [ClaudeSession] {
        lock.lock(); defer { lock.unlock() }
        return _sessions
    }
}

// MARK: - Heartbeat reading (L2, VibeMenu-owned files only)

extension ClaudeActivityProvider {
    /// Read the per-session heartbeat files VibeMenu's hook script wrote, decoding each via
    /// the pure, malformed-safe `ClaudeHeartbeatRecord.decode`. Reads only `*.json` files
    /// in the sessions directory; a missing directory, an unreadable file, or a malformed
    /// file is silently skipped (never a crash). These are VibeMenu's own privacy-safe
    /// files ({schemaVersion, updatedAt, event, sessionID}) — **not** Claude transcripts.
    static func readHeartbeatRecords(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [ClaudeHeartbeatRecord] {
        ClaudeHeartbeatReader(
            fileManager: fileManager, retentionHorizon: nil, maxFiles: .max
        ).readRecords(in: directory, now: Date())
    }
}

// MARK: - Signal gathering (thin, metadata-only)

extension ClaudeActivityProvider {
    /// Gather the two L1 signals from the real system. Metadata only. The project/session mtime
    /// walk is unnecessary when the process is absent because L1 cannot hold without that process.
    static func gatherSignals() -> ClaudeActivitySignals {
        let processPresent = claudeProcessPresent()
        return ClaudeActivitySignals(
            processPresent: processPresent,
            mostRecentSessionActivity: processPresent
                ? mostRecentSessionActivity(fileManager: .default)
                : nil
        )
    }
}

// MARK: - Bounded heartbeat cache (L2, VibeMenu-owned allowlisted records only)

private struct ClaudeHeartbeatCacheIdentity: Equatable, Sendable {
    let modificationDate: Date
    let attributeModificationDate: Date?
    let size: Int
    let resourceIdentifier: Data?
}

private struct ClaudeHeartbeatFileMetadata: Sendable {
    let url: URL
    let identity: ClaudeHeartbeatCacheIdentity
}

private struct CachedClaudeHeartbeat: Sendable {
    let identity: ClaudeHeartbeatCacheIdentity
    /// The existing allowlisted record, or nil for the current malformed/unreadable identity.
    let record: ClaudeHeartbeatRecord?
}

struct ClaudeHeartbeatCacheDiagnostics: Equatable, Sendable {
    let candidateFiles: Int
    let cacheHits: Int
    let filesDecoded: Int
    let cachedFiles: Int

    init(candidateFiles: Int = 0, cacheHits: Int = 0, filesDecoded: Int = 0, cachedFiles: Int = 0) {
        self.candidateFiles = candidateFiles
        self.cacheHits = cacheHits
        self.filesDecoded = filesDecoded
        self.cachedFiles = cachedFiles
    }
}

/// Lock-serialized because the provider is `@unchecked Sendable` and direct deterministic tests may
/// call ticks from outside its timer queue. Cache entries structurally cannot retain heartbeat bytes.
private final class ClaudeHeartbeatReader: @unchecked Sendable {
    private let fileManager: FileManager
    private let retentionHorizon: TimeInterval?
    private let maxFiles: Int
    private let lock = NSLock()
    private var cache: [URL: CachedClaudeHeartbeat] = [:]
    private var _cacheDiagnostics = ClaudeHeartbeatCacheDiagnostics()

    init(
        fileManager: FileManager = .default,
        retentionHorizon: TimeInterval?,
        maxFiles: Int
    ) {
        self.fileManager = fileManager
        self.retentionHorizon = retentionHorizon
        self.maxFiles = maxFiles
    }

    func readRecords(in directory: URL, now: Date) -> [ClaudeHeartbeatRecord] {
        lock.lock()
        defer { lock.unlock() }

        let files = recentFiles(in: directory, now: now)
        let candidates = Set(files.map(\.url))
        cache = cache.filter { candidates.contains($0.key) }

        var hits = 0
        var decoded = 0
        var records: [ClaudeHeartbeatRecord] = []
        for file in files {
            let record: ClaudeHeartbeatRecord?
            if let cached = cache[file.url], cached.identity == file.identity {
                hits += 1
                record = cached.record
            } else {
                decoded += 1
                if let data = try? Data(contentsOf: file.url),
                   data.count == file.identity.size,
                   currentIdentity(of: file.url) == file.identity {
                    record = ClaudeHeartbeatRecord.decode(from: data)
                } else {
                    record = nil
                }
                // Negative caching is deliberate: a changed malformed/unreadable file replaces the
                // old record and cannot keep an obsolete hold alive.
                cache[file.url] = CachedClaudeHeartbeat(identity: file.identity, record: record)
            }
            if let record { records.append(record) }
        }

        _cacheDiagnostics = ClaudeHeartbeatCacheDiagnostics(
            candidateFiles: files.count,
            cacheHits: hits,
            filesDecoded: decoded,
            cachedFiles: cache.count
        )
        return records
    }

    var cacheDiagnostics: ClaudeHeartbeatCacheDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return _cacheDiagnostics
    }

    private func recentFiles(in directory: URL, now: Date) -> [ClaudeHeartbeatFileMetadata] {
        let keys: Set<URLResourceKey> = [
            .attributeModificationDateKey, .contentModificationDateKey, .fileSizeKey,
            .fileResourceIdentifierKey, .isRegularFileKey,
        ]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = retentionHorizon.map { now.addingTimeInterval(-$0) }
        var files: [ClaudeHeartbeatFileMetadata] = []
        for url in urls where url.pathExtension == "json" {
            guard let identity = identity(of: url, keys: keys),
                  cutoff == nil || identity.modificationDate >= cutoff!
            else { continue }
            files.append(ClaudeHeartbeatFileMetadata(url: url, identity: identity))
        }
        files.sort { lhs, rhs in
            if lhs.identity.modificationDate != rhs.identity.modificationDate {
                return lhs.identity.modificationDate > rhs.identity.modificationDate
            }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        return Array(files.prefix(maxFiles))
    }

    private func currentIdentity(of url: URL) -> ClaudeHeartbeatCacheIdentity? {
        identity(of: url, keys: [
            .attributeModificationDateKey, .contentModificationDateKey, .fileSizeKey,
            .fileResourceIdentifierKey, .isRegularFileKey,
        ])
    }

    private func identity(
        of url: URL,
        keys: Set<URLResourceKey>
    ) -> ClaudeHeartbeatCacheIdentity? {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let modificationDate = values.contentModificationDate,
              let size = values.fileSize, size >= 0
        else { return nil }
        return ClaudeHeartbeatCacheIdentity(
            modificationDate: modificationDate,
            attributeModificationDate: values.attributeModificationDate,
            size: size,
            resourceIdentifier: values.fileResourceIdentifier as? Data
        )
    }
}

/// Whether a process named `claude` appears to be running.
///
/// Uses public `libproc` inspection of the current user's process table. We read only
/// the short process *name* (`comm`, ≤16 chars) — never arguments, never the full
/// executable path — and match it exactly against `claude`. No entitlement or root is
/// needed for the current user's own processes.
///
/// Honest limitation: this matches the process *name* only. A Claude Code CLI hosted by
/// a differently-named process (e.g. `node`) will not match — a deliberate false
/// negative rather than a broad, false-positive-prone heuristic. L2 can refine this.
private func claudeProcessPresent() -> Bool {
    let maxPids = 8192
    var pids = [pid_t](repeating: 0, count: maxPids)
    let count: Int = pids.withUnsafeMutableBytes { raw in
        let byteCount = proc_listallpids(raw.baseAddress, Int32(raw.count))
        return byteCount > 0 ? Int(byteCount) / MemoryLayout<pid_t>.size : 0
    }
    guard count > 0 else { return false }

    var nameBuffer = [CChar](repeating: 0, count: 256)
    for index in 0..<min(count, maxPids) {
        let pid = pids[index]
        guard pid > 0 else { continue }
        let name: String = nameBuffer.withUnsafeMutableBytes { raw -> String in
            let written = proc_name(pid, raw.baseAddress, UInt32(raw.count))
            guard written > 0, let base = raw.baseAddress else { return "" }
            // `proc_name` writes a null-terminated C string; read it via the
            // (non-deprecated) pointer overload.
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        if name == "claude" { return true }
    }
    return false
}

/// The newest modification time across the watched Claude Code session-metadata paths,
/// or `nil` if none exist. **Reads mtime via `stat`/`resourceValues` only — never file
/// contents.**
///
/// Watched, bounded to keep the tick cheap (docs/decisions/0006):
///   - `~/.claude/history.jsonl` (if present) — its own mtime.
///   - `~/.claude/projects` — the directory's own mtime plus a shallow two-level walk of
///     `projects/<project>/<session-file>` mtimes (appends to a live session file bump
///     that file's mtime; directory mtime alone would miss in-place appends).
private func mostRecentSessionActivity(fileManager: FileManager) -> Date? {
    let claudeDir = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
    let historyURL = claudeDir.appendingPathComponent("history.jsonl")
    let projectsURL = claudeDir.appendingPathComponent("projects", isDirectory: true)

    var newest: Date? = modificationDate(of: historyURL)
    newest = maxDate(newest, modificationDate(of: projectsURL))

    // Shallow two-level walk of projects/<project>/<session-file>. Stat-only.
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
    if let projectDirs = try? fileManager.contentsOfDirectory(
        at: projectsURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
    ) {
        for projectDir in projectDirs {
            newest = maxDate(newest, modificationDate(of: projectDir))
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            guard isDir else { continue }
            if let sessionFiles = try? fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for file in sessionFiles {
                    newest = maxDate(newest, modificationDate(of: file))
                }
            }
        }
    }
    return newest
}

/// Modification-time metadata for a URL (a `stat`), or `nil` if it doesn't exist / can't
/// be read. Never opens or reads the file's contents.
private func modificationDate(of url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}

private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
    switch (lhs, rhs) {
    case let (l?, r?): return max(l, r)
    case let (l?, nil): return l
    case let (nil, r?): return r
    case (nil, nil): return nil
    }
}
