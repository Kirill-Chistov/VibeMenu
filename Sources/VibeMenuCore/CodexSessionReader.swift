import Foundation

// Read-only adapter that turns Codex Desktop rollout files into the shared session list
// (docs/decisions/0017-codex-session-support.md). All the risky *decisions* (what's allowlisted,
// how state is derived) live in the pure `CodexRolloutParser` / `CodexSessionState`; this adapter
// only does the file I/O the pure code can't, under strict bounds:
//
//   * it walks `~/.codex/sessions/**/rollout-*.jsonl` and opens ONLY files whose mtime is within
//     `recencyHorizon` (a cheap stat), so old sessions are never read — bounding work and keeping
//     the list to genuinely recent sessions;
//   * it reads at most `maxFileBytes` per file (whole file when small; head+tail when large) so a
//     pathological file can't be slurped whole;
//   * it decodes leniently and skips anything malformed — a missing directory, unreadable file, or
//     bad line never throws;
//   * it keeps only Codex **Desktop** summaries (case-insensitive `originator` gate; the shared CLI
//     is ignored) and drops internal **subagent** rollouts (Codex's own guardian/tool runs);
//   * it dedupes by session id (keeping the newest activity), sorts most-active-first, and caps;
//   * it resolves each session's safe display **title** from `~/.codex/session_index.jsonl` via
//     `CodexSessionIndexReader` (allowlist: `id` + sanitised `thread_name` only), falling back to the
//     folder name when no safe title exists (see CodexSessionTitle.swift).
//
// Reads nothing but the allowlisted metadata the parser + index reader extract. Power side effects
// remain outside the reader; the model maps only the resulting `.active` state into automation.

/// Reads the current Codex Desktop session list. The seam lets the observable model be driven by a
/// fake in tests with no real `~/.codex` directory.
public protocol CodexSessionReading: Sendable {
    /// The recent Codex Desktop sessions at `now`, most-active-first (empty on any error / when
    /// none are found).
    func readSessions(now: Date) -> [CodexSession]
}

/// The real reader over `~/.codex/sessions`.
///
/// Concurrency: `@unchecked Sendable` — it holds only immutable configuration; each `readSessions`
/// call is a self-contained read with no shared mutable state.
public final class CodexSessionReader: CodexSessionReading, @unchecked Sendable {
    /// `~/.codex/sessions` — shared by the Codex Desktop app and the CLI; the originator gate keeps
    /// only Desktop sessions.
    public static var defaultSessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Only rollout files modified within this window are opened. 60 min keeps the list to recent
    /// sessions and means the vast majority of historical files are skipped by a cheap stat.
    public static let defaultRecencyHorizon: TimeInterval = 60 * 60

    /// Upper bound on sessions the reader returns (the menu presenter caps *visible* rows tighter).
    public static let defaultMaxSessions = 8

    /// Never open more than this many candidate files per tick (defensive against a huge tree).
    public static let maxFilesScanned = 400

    /// Per-file read cap. Real rollouts are well under this; larger files fall back to a head+tail
    /// read so `session_meta` (head) and the completion marker + newest timestamp (tail) survive.
    public static let defaultMaxFileBytes = 4 * 1024 * 1024
    public static let defaultHeadTailBytes = 64 * 1024

    private let directory: URL
    private let recencyHorizon: TimeInterval
    private let maxSessions: Int
    private let activeWindow: TimeInterval
    private let idleWindow: TimeInterval
    private let doneWindow: TimeInterval
    private let maxFileBytes: Int
    private let headTailBytes: Int
    private let fileManager: FileManager
    /// Resolves safe per-session titles from `~/.codex/session_index.jsonl` (see CodexSessionTitle.swift).
    /// Defaults to the index sibling of `directory`, so a test directory never reaches the real index.
    private let titleReader: CodexSessionTitleReading

    public init(
        directory: URL? = nil,
        recencyHorizon: TimeInterval = CodexSessionReader.defaultRecencyHorizon,
        maxSessions: Int = CodexSessionReader.defaultMaxSessions,
        activeWindow: TimeInterval = CodexSessionState.defaultActiveWindow,
        idleWindow: TimeInterval = CodexSessionState.defaultIdleWindow,
        doneWindow: TimeInterval = CodexSessionState.defaultDoneWindow,
        maxFileBytes: Int = CodexSessionReader.defaultMaxFileBytes,
        headTailBytes: Int = CodexSessionReader.defaultHeadTailBytes,
        fileManager: FileManager = .default,
        titleReader: CodexSessionTitleReading? = nil
    ) {
        let resolvedDirectory = directory ?? Self.defaultSessionsDirectory
        self.directory = resolvedDirectory
        self.recencyHorizon = recencyHorizon
        self.maxSessions = maxSessions
        self.activeWindow = activeWindow
        self.idleWindow = idleWindow
        self.doneWindow = doneWindow
        self.maxFileBytes = maxFileBytes
        self.headTailBytes = headTailBytes
        self.fileManager = fileManager
        // The index lives beside the `sessions/` directory (`~/.codex/session_index.jsonl`). Deriving
        // it from `directory` means a test's temp `directory` resolves to an absent temp index rather
        // than the user's real one — no real data is ever read in tests.
        self.titleReader = titleReader ?? CodexSessionIndexReader(
            url: resolvedDirectory.deletingLastPathComponent()
                .appendingPathComponent("session_index.jsonl", isDirectory: false),
            fileManager: fileManager
        )
    }

    public func readSessions(now: Date) -> [CodexSession] {
        let cutoff = now.addingTimeInterval(-recencyHorizon)
        let files = Self.recentRolloutFiles(
            in: directory, modifiedAfter: cutoff, limit: Self.maxFilesScanned, fileManager: fileManager
        )
        // Read the safe title map once per tick; empty when the index is missing/unreadable.
        let titles = titleReader.titles()

        var byID: [String: CodexSession] = [:]
        for (url, mtime) in files {
            guard let data = readCapped(url) else { continue }
            let text = String(decoding: data, as: UTF8.self)   // lenient: bad bytes → U+FFFD
            guard let summary = CodexRolloutParser.parse(text: text, fallbackActivity: mtime),
                  CodexRolloutParser.isDesktopOriginator(summary.originator),
                  // Drop internal subagent rollouts (Codex's own guardian/tool subagents): they are
                  // not user-facing Desktop sessions and would otherwise surface as phantom rows.
                  !summary.isSubagent else { continue }

            let age = now.timeIntervalSince(summary.lastActivity)
            // Defensive: drop anything whose *content* activity is older than the horizon even if
            // the file mtime was fresh (e.g. touched without a new event).
            if age > recencyHorizon { continue }

            let session = CodexSession(
                id: summary.sessionID,
                state: CodexSessionState.derive(
                    age: age,
                    endedWithCompletion: summary.endedWithCompletion,
                    activeWindow: activeWindow, idleWindow: idleWindow, doneWindow: doneWindow
                ),
                folderName: summary.folderName,
                startedAt: summary.startedAt,
                lastActivity: summary.lastActivity,
                // Safe curated title from session_index.jsonl (already sanitised); nil ⇒ folder fallback.
                title: titles[summary.sessionID],
                endedWithCompletion: summary.endedWithCompletion,
                // Derive the Work/Codex row pill here, at the one place the originator is known, so
                // the raw originator string is dropped immediately and never reaches the UI.
                mode: CodexSessionMode.derive(originator: summary.originator)
            )
            // A session id can appear in more than one rollout file (thread forking); keep the row
            // with the newest activity.
            if let existing = byID[summary.sessionID], existing.lastActivity >= session.lastActivity {
                continue
            }
            byID[summary.sessionID] = session
        }

        let sorted = byID.values.sorted(by: Self.mostActiveFirst)
        return Array(sorted.prefix(maxSessions))
    }

    /// Sort most-active-first: by state priority, then newest activity, then id for determinism.
    static func mostActiveFirst(_ lhs: CodexSession, _ rhs: CodexSession) -> Bool {
        if lhs.state.sortPriority != rhs.state.sortPriority {
            return lhs.state.sortPriority < rhs.state.sortPriority
        }
        if lhs.lastActivity != rhs.lastActivity {
            return lhs.lastActivity > rhs.lastActivity
        }
        return lhs.id < rhs.id
    }

    // MARK: - File discovery (metadata only)

    /// Candidate rollout files modified after `cutoff`, newest first, capped at `limit`. Walks the
    /// `sessions/YYYY/MM/DD` tree with a stat-only enumerator; a missing tree yields `[]`.
    static func recentRolloutFiles(
        in directory: URL, modifiedAfter cutoff: Date, limit: Int, fileManager: FileManager
    ) -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return [] }

        var result: [(URL, Date)] = []
        var examined = 0
        for case let url as URL in enumerator {
            examined += 1
            if examined > 50_000 { break }   // hard backstop on tree size
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate, mtime >= cutoff else { continue }
            result.append((url, mtime))
        }
        // Newest first, then keep only the freshest `limit` files so parse work is bounded.
        result.sort { $0.1 > $1.1 }
        return Array(result.prefix(limit))
    }

    /// Read a rollout file under the byte cap. Small files are read whole; a file larger than
    /// `maxFileBytes` is read as head+tail (joined by a newline) so `session_meta` and the trailing
    /// completion/activity survive while the bulky middle is skipped.
    func readCapped(_ url: URL) -> Data? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size <= maxFileBytes {
            return try? Data(contentsOf: url)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headTailBytes)) ?? Data()
        if size > headTailBytes {
            try? handle.seek(toOffset: UInt64(size - headTailBytes))
        }
        let tail = (try? handle.readToEnd()) ?? Data()
        var combined = head
        combined.append(0x0A)   // newline so a split line can't merge head's tail with tail's head
        combined.append(tail)
        return combined
    }
}
