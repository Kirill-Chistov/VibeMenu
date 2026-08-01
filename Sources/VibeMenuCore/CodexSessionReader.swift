import Foundation
import CryptoKit

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
/// Concurrency: `@unchecked Sendable` — immutable configuration plus the summary cache and its
/// diagnostics are serialized by `cacheLock`, including concurrent `readSessions` calls.
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
    /// A growth-only update must reproduce this many bytes immediately before the previous EOF
    /// before it is trusted as an append. Small enough for one cheap read, large enough to make a
    /// same-path prefix rewrite fail validation without rereading the rollout.
    static let appendValidationBytes = 4 * 1024

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
    private let cacheLock = NSLock()
    private var summaryCache: [URL: CachedRollout] = [:]
    private var _cacheDiagnostics = CodexSessionCacheDiagnostics()

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
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let cutoff = now.addingTimeInterval(-recencyHorizon)
        let files = Self.recentRolloutFiles(
            in: directory, modifiedAfter: cutoff, limit: Self.maxFilesScanned, fileManager: fileManager
        )
        // The candidate list is the cache's complete authority: deleted files, files outside the
        // recency horizon, and files displaced by the existing scan cap are evicted immediately.
        let candidateURLs = Set(files.map(\.url))
        summaryCache = summaryCache.filter { candidateURLs.contains($0.key) }

        // Read the safe title map once per tick; empty when the index is missing/unreadable.
        let titles = titleReader.titles()

        var byID: [String: CodexSession] = [:]
        var cacheHits = 0
        var filesReparsed = 0
        var filesIncrementallyParsed = 0
        var fullBytesParsed = 0
        var appendedBytesParsed = 0
        for file in files {
            let summary: CodexRolloutSummary?
            if let cached = summaryCache[file.url], cached.identity == file.cacheIdentity {
                cacheHits += 1
                summary = cached.summary
            } else {
                let parsed: CachedRollout
                if let cached = summaryCache[file.url],
                   let incremental = incrementallyParse(file, after: cached) {
                    filesIncrementallyParsed += 1
                    appendedBytesParsed += incremental.appendedBytesParsed
                    parsed = incremental.entry
                } else {
                    filesReparsed += 1
                    let full = fullyParse(file)
                    fullBytesParsed += full.bytesParsed
                    parsed = full.entry
                }
                // Cache changed content even when reading/parsing failed. A negative entry replaces
                // the old summary, so a changed file can never retain obsolete active state.
                summaryCache[file.url] = parsed
                summary = parsed.summary
            }

            guard let summary,
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

        _cacheDiagnostics = CodexSessionCacheDiagnostics(
            candidateFiles: files.count,
            cacheHits: cacheHits,
            filesReparsed: filesReparsed,
            filesIncrementallyParsed: filesIncrementallyParsed,
            cachedFiles: summaryCache.count,
            fullBytesParsed: fullBytesParsed,
            appendedBytesParsed: appendedBytesParsed
        )

        let sorted = byID.values.sorted(by: Self.mostActiveFirst)
        return Array(sorted.prefix(maxSessions))
    }

    /// Count-only cache evidence for sanitized tests. It never exposes file URLs, ids, titles, or
    /// parsed metadata and is not logged by production code.
    var cacheDiagnostics: CodexSessionCacheDiagnostics {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return _cacheDiagnostics
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
    ) -> [CodexRolloutFileMetadata] {
        let keys: [URLResourceKey] = [
            .attributeModificationDateKey, .contentModificationDateKey, .fileSizeKey,
            .fileResourceIdentifierKey, .isRegularFileKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return [] }

        var result: [CodexRolloutFileMetadata] = []
        var examined = 0
        for case let url as URL in enumerator {
            examined += 1
            if examined > 50_000 { break }   // hard backstop on tree size
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate, mtime >= cutoff,
                  let size = values?.fileSize, size >= 0 else { continue }
            // The resource identifier distinguishes an atomically replaced file at the same URL even
            // if its byte size and content mtime happen to match. Attribute mtime catches permission
            // changes; when either value is unavailable, content mtime + size remain the fallback.
            result.append(CodexRolloutFileMetadata(
                url: url,
                modificationDate: mtime,
                attributeModificationDate: values?.attributeModificationDate,
                size: size,
                resourceIdentifier: values?.fileResourceIdentifier as? Data
            ))
        }
        // Newest first, then keep only the freshest `limit` files so parse work is bounded.
        result.sort { $0.modificationDate > $1.modificationDate }
        return Array(result.prefix(limit))
    }

    /// Read a rollout file under the byte cap. Small files are read whole; a file larger than
    /// `maxFileBytes` is read as head+tail (joined by a newline) so `session_meta` and the trailing
    /// completion/activity survive while the bulky middle is skipped.
    func readCapped(_ file: CodexRolloutFileMetadata) -> Data? {
        if file.size <= maxFileBytes {
            return try? Data(contentsOf: file.url)
        }
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headTailBytes)) ?? Data()
        if file.size > headTailBytes {
            try? handle.seek(toOffset: UInt64(file.size - headTailBytes))
        }
        let tail = (try? handle.readToEnd()) ?? Data()
        var combined = head
        combined.append(0x0A)   // newline so a split line can't merge head's tail with tail's head
        combined.append(tail)
        return combined
    }

    // MARK: - Incremental parsing

    /// Parse a changed rollout from the beginning. Files under the existing byte cap retain a safe
    /// resumable parser state and a small validation tail; oversized files keep the existing bounded
    /// head+tail behavior and are conservatively fully reparsed on later changes.
    private func fullyParse(_ file: CodexRolloutFileMetadata) -> (entry: CachedRollout, bytesParsed: Int) {
        guard let data = readCapped(file) else {
            return (.failed(identity: file.cacheIdentity), 0)
        }

        if file.size <= maxFileBytes {
            // A short read or a metadata change during the read is not a trustworthy snapshot.
            guard data.count == file.size,
                  currentIdentity(of: file.url) == file.cacheIdentity,
                  let chunk = CodexRolloutParser.parseIncrementalChunk(data),
                  chunk.incompleteTrailingBytes.count <= maxFileBytes
            else { return (.failed(identity: file.cacheIdentity), data.count) }

            let validationSize = min(data.count, Self.appendValidationBytes)
            let validationDigest = Self.validationDigest(for: data.suffix(validationSize))
            let summary = chunk.state.summary(fallbackActivity: file.modificationDate)
            return (CachedRollout(
                identity: file.cacheIdentity,
                summary: summary,
                parserState: chunk.state,
                consumedOffset: file.size - chunk.incompleteTrailingBytes.count,
                incompleteTrailingBytes: chunk.incompleteTrailingBytes,
                validationSize: validationSize,
                validationDigest: validationDigest
            ), data.count)
        }

        let text = String(decoding: data, as: UTF8.self)   // bad bytes → U+FFFD
        let summary = CodexRolloutParser.parse(text: text, fallbackActivity: file.modificationDate)
        return (CachedRollout(
            identity: file.cacheIdentity,
            summary: summary,
            parserState: nil,
            consumedOffset: 0,
            incompleteTrailingBytes: Data(),
            validationSize: 0,
            validationDigest: Data()
        ), data.count)
    }

    /// If `file` is provably the same file with an unchanged prefix and a bounded append, parse only
    /// the new suffix. Any uncertainty returns `nil`, causing a full reparse instead.
    private func incrementallyParse(
        _ file: CodexRolloutFileMetadata,
        after cached: CachedRollout
    ) -> (entry: CachedRollout, appendedBytesParsed: Int)? {
        guard let parserState = cached.parserState,
              file.size > cached.identity.size,
              file.size - cached.identity.size <= maxFileBytes,
              let oldResourceID = cached.identity.resourceIdentifier,
              let newResourceID = file.resourceIdentifier,
              oldResourceID == newResourceID,
              file.modificationDate >= cached.identity.modificationDate,
              metadataDidNotMoveBackward(
                old: cached.identity.attributeModificationDate,
                new: file.attributeModificationDate
              ),
              cached.consumedOffset == cached.identity.size - cached.incompleteTrailingBytes.count,
              cached.validationSize > 0,
              !cached.validationDigest.isEmpty
        else { return nil }

        let suffixCount = file.size - cached.identity.size
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }

        do {
            let validationOffset = cached.identity.size - cached.validationSize
            try handle.seek(toOffset: UInt64(validationOffset))
            guard let currentTail = try handle.read(upToCount: cached.validationSize),
                  currentTail.count == cached.validationSize,
                  Self.validationDigest(for: currentTail) == cached.validationDigest
            else { return nil }

            try handle.seek(toOffset: UInt64(cached.identity.size))
            guard let suffix = try handle.read(upToCount: suffixCount), suffix.count == suffixCount,
                  currentIdentity(of: file.url) == file.cacheIdentity
            else { return nil }

            var parseBytes = cached.incompleteTrailingBytes
            parseBytes.append(suffix)
            guard parseBytes.count <= maxFileBytes else {
                return (.failed(identity: file.cacheIdentity), suffix.count)
            }
            guard let chunk = CodexRolloutParser.parseIncrementalChunk(
                parseBytes, startingWith: parserState
            ), chunk.incompleteTrailingBytes.count <= maxFileBytes else {
                // A complete malformed appended line fails closed for the new identity. Returning a
                // negative entry (rather than falling back to the old summary) is essential here.
                return (
                    .failed(identity: file.cacheIdentity),
                    suffix.count
                )
            }

            let nextValidationSize = min(file.size, Self.appendValidationBytes)
            try handle.seek(toOffset: UInt64(file.size - nextValidationSize))
            guard let nextTail = try handle.read(upToCount: nextValidationSize),
                  nextTail.count == nextValidationSize,
                  currentIdentity(of: file.url) == file.cacheIdentity
            else { return nil }
            return (CachedRollout(
                identity: file.cacheIdentity,
                summary: chunk.state.summary(fallbackActivity: file.modificationDate),
                parserState: chunk.state,
                consumedOffset: file.size - chunk.incompleteTrailingBytes.count,
                incompleteTrailingBytes: chunk.incompleteTrailingBytes,
                validationSize: nextValidationSize,
                validationDigest: Self.validationDigest(for: nextTail)
            ), suffix.count)
        } catch {
            return nil
        }
    }

    private func currentIdentity(of url: URL) -> CodexRolloutCacheIdentity? {
        let keys: Set<URLResourceKey> = [
            .attributeModificationDateKey, .contentModificationDateKey, .fileSizeKey,
            .fileResourceIdentifierKey, .isRegularFileKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let modificationDate = values.contentModificationDate,
              let size = values.fileSize, size >= 0
        else { return nil }
        return CodexRolloutCacheIdentity(
            modificationDate: modificationDate,
            attributeModificationDate: values.attributeModificationDate,
            size: size,
            resourceIdentifier: values.fileResourceIdentifier as? Data
        )
    }

    private func metadataDidNotMoveBackward(old: Date?, new: Date?) -> Bool {
        guard let old, let new else { return old == nil && new == nil }
        return new >= old
    }

    private static func validationDigest<T: DataProtocol>(for bytes: T) -> Data {
        Data(SHA256.hash(data: Data(bytes)))
    }
}

/// Safe metadata collected during the existing stat-only candidate walk. Shared with the limits
/// reader so both adapters retain one bounded discovery implementation.
struct CodexRolloutFileMetadata: Sendable {
    let url: URL
    let modificationDate: Date
    let attributeModificationDate: Date?
    let size: Int
    let resourceIdentifier: Data?

    fileprivate var cacheIdentity: CodexRolloutCacheIdentity {
        CodexRolloutCacheIdentity(
            modificationDate: modificationDate,
            attributeModificationDate: attributeModificationDate,
            size: size,
            resourceIdentifier: resourceIdentifier
        )
    }
}

private struct CodexRolloutCacheIdentity: Equatable, Sendable {
    let modificationDate: Date
    let attributeModificationDate: Date?
    let size: Int
    let resourceIdentifier: Data?
}

private struct CachedRollout: Sendable {
    let identity: CodexRolloutCacheIdentity
    /// The allowlisted parsed summary, or nil for the current unreadable/malformed identity.
    let summary: CodexRolloutSummary?
    let parserState: CodexRolloutParsingState?
    /// Byte offset through the last complete JSONL line. The remaining bytes are held separately.
    let consumedOffset: Int
    let incompleteTrailingBytes: Data
    /// Length + SHA-256 of a small EOF window. Raw complete-line bytes are not retained; the digest
    /// exists solely to prove that a would-be append preserved the old prefix.
    let validationSize: Int
    let validationDigest: Data

    static func failed(identity: CodexRolloutCacheIdentity) -> CachedRollout {
        CachedRollout(
            identity: identity,
            summary: nil,
            parserState: nil,
            consumedOffset: 0,
            incompleteTrailingBytes: Data(),
            validationSize: 0,
            validationDigest: Data()
        )
    }
}

struct CodexSessionCacheDiagnostics: Equatable, Sendable {
    let candidateFiles: Int
    let cacheHits: Int
    let filesReparsed: Int
    let filesIncrementallyParsed: Int
    let cachedFiles: Int
    let fullBytesParsed: Int
    let appendedBytesParsed: Int

    init(
        candidateFiles: Int = 0,
        cacheHits: Int = 0,
        filesReparsed: Int = 0,
        filesIncrementallyParsed: Int = 0,
        cachedFiles: Int = 0,
        fullBytesParsed: Int = 0,
        appendedBytesParsed: Int = 0
    ) {
        self.candidateFiles = candidateFiles
        self.cacheHits = cacheHits
        self.filesReparsed = filesReparsed
        self.filesIncrementallyParsed = filesIncrementallyParsed
        self.cachedFiles = cachedFiles
        self.fullBytesParsed = fullBytesParsed
        self.appendedBytesParsed = appendedBytesParsed
    }
}
