import Foundation

// The one adapter that opens a Claude transcript — narrowly, to read a session title
// (docs/decisions/0013-session-title-and-dismiss.md). It locates the single transcript file
// that matches a session id, reads it, and hands the bytes to the pure `ClaudeSessionTitle`
// parser (which keeps only the title record). Kept out of `ClaudeSessionStore` so the store
// and the pure parser stay I/O-free and unit-tested; this file is the untested-against-live
// edge, like `ClaudeActivityProvider`'s signal gathering.
//
// Privacy (docs/PRIVACY.md, AGENTS.md §6): this reads transcript bytes but the pure parser
// extracts ONLY the `custom-title` / `ai-title` title field — never prompt/response/
// `lastPrompt`/tool/message content, never `cwd`/`gitBranch`. No title, path, or session id
// is logged. Nothing leaves the Mac.

/// Real `SessionTitleResolving`: maps a session id to the title Claude Code shows for it, by
/// reading that session's transcript title record.
///
/// ### Locating the file
/// Claude Code names each transcript `<session_id>.jsonl` under
/// `~/.claude/projects/<encoded-cwd>/`. VibeMenu already has the session id (from its own
/// heartbeat) but — since the heartbeat schema stores only the project *folder name*, not the
/// full encoded cwd — it does **not** know which encoded project directory holds the file. So the
/// transcript is found by **scanning by session id**: for each project directory, test whether
/// `<dir>/<id>.jsonl` exists. This is a bounded, metadata-only lookup (the existing L1 walk already
/// enumerates these directories for mtime) — no directory *name* is parsed, decoded, or displayed.
/// In the rare case the same session id appears under more than one encoded directory (e.g. a
/// session resumed from a different cwd), the **most recently modified** match wins, so the live
/// transcript with the newest title is chosen deterministically rather than an arbitrary first hit.
///
/// ### Caching (so the ~2s tick stays cheap)
/// A title is cached per session id together with the transcript's modification time and its
/// resolved URL. On a later call the file is only re-read when its mtime changed (a title can
/// be renamed mid-session), so an unchanged transcript costs one `stat`, not a full re-scan.
///
/// Concurrency: `@unchecked Sendable` — the cache is guarded by `lock`; the provider calls
/// `title(forSessionID:)` from its private utility queue.
public final class TranscriptTitleResolver: SessionTitleResolving, @unchecked Sendable {
    /// One cached lookup: where the transcript is, when it was last modified, and the title we
    /// extracted at that mtime (`nil` = found the file but it has no title record yet).
    private struct Entry {
        let url: URL
        let mtime: Date
        let title: String?
    }

    /// Runaway backstop (AGENTS.md §10 lightweight budget). A title record is tiny and near the
    /// top/rename points of the file, but "last record wins" means a full scan. To avoid loading a
    /// pathologically large transcript on every mtime bump of a long, actively-appending session,
    /// a transcript larger than this is not (re-)read: we keep the last title we already resolved
    /// for it, or fall back to the folder name. Generous enough that normal sessions are unaffected.
    static let maxTranscriptBytes = 12 * 1024 * 1024   // 12 MB

    private let projectsDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]

    /// The default `~/.claude/projects` root that holds per-session transcripts.
    public static var defaultProjectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    public init(
        projectsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.projectsDirectory = projectsDirectory ?? Self.defaultProjectsDirectory
        self.fileManager = fileManager
    }

    public func title(forSessionID id: String) -> String? {
        // Reject anything that isn't a plain transcript-file stem, so a malformed id can never
        // build a traversing path (`..`, a slash, etc.). Heartbeat ids are already sanitised to
        // this set by the hook, but the resolver validates independently.
        guard Self.isSafeSessionID(id) else { return nil }

        lock.lock()
        let cached = cache[id]
        lock.unlock()

        // Fast path: we know the file. Re-read only if it changed since we cached the title.
        if let cached {
            guard let stat = fileStat(of: cached.url) else {
                // File vanished or became unreadable: drop the stale entry and fall through to a
                // fresh locate (the transcript may have moved).
                evict(id)
                return relocateAndRead(id: id)
            }
            if stat.mtime == cached.mtime { return cached.title }        // unchanged → one stat only
            guard stat.size <= Self.maxTranscriptBytes else {
                // Too big to re-scan cheaply: keep the last title we had rather than reading it.
                return cached.title
            }
            guard let data = try? Data(contentsOf: cached.url) else { return cached.title }
            let title = ClaudeSessionTitle.parse(transcript: data)
            store(Entry(url: cached.url, mtime: stat.mtime, title: title), for: id)
            return title
        }

        // Slow path: locate the transcript by session id, read it, cache the result.
        return relocateAndRead(id: id)
    }

    /// Locate a session's transcript and read its title, caching the result. Used for a
    /// first-ever lookup and after a cached file vanished. Returns `nil` if not found, too large
    /// on first sight, or unreadable.
    private func relocateAndRead(id: String) -> String? {
        guard let url = locateTranscript(sessionID: id),
              let stat = fileStat(of: url)
        else { return nil }
        guard stat.size <= Self.maxTranscriptBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }   // first sight already over the cap ⇒ no title (folder-name fallback)
        let title = ClaudeSessionTitle.parse(transcript: data)
        store(Entry(url: url, mtime: stat.mtime, title: title), for: id)
        return title
    }

    // MARK: - Locating

    /// Find `<projectsDirectory>/<any-project>/<id>.jsonl`. Shallow: one level of project
    /// directories, then a stat of the named file in each — no recursion, no name parsing. When
    /// the id matches in several project directories (rare — a session resumed from a different
    /// cwd), the **most recently modified** transcript wins so the choice is deterministic and
    /// picks the live file, not an arbitrary first hit. The single `fileStat` per candidate both
    /// confirms existence and yields the mtime used to compare.
    private func locateTranscript(sessionID id: String) -> URL? {
        let filename = "\(id).jsonl"
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (url: URL, mtime: Date)?
        for dir in projectDirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let candidate = dir.appendingPathComponent(filename)
            guard let mtime = fileStat(of: candidate)?.mtime else { continue }  // missing ⇒ skip
            if best == nil || mtime > best!.mtime {
                best = (candidate, mtime)
            }
        }
        return best?.url
    }

    // MARK: - Cache helpers

    private func store(_ entry: Entry, for id: String) {
        lock.lock(); defer { lock.unlock() }
        cache[id] = entry
    }

    private func evict(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        cache[id] = nil
    }

    /// Modification time + byte size for a URL (a single `stat`), or `nil` if it can't be read.
    /// Never opens the file's contents. Size gates the read against `maxTranscriptBytes`; mtime
    /// keys the cache.
    private func fileStat(of url: URL) -> (mtime: Date, size: Int)? {
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        ), let mtime = values.contentModificationDate else { return nil }
        return (mtime, values.fileSize ?? 0)
    }

    /// A session id is safe to turn into `<id>.jsonl` iff it is non-empty and every character
    /// is in the transcript-filename allowlist `[A-Za-z0-9._-]` — the same set the hook writes.
    /// This blocks `/`, `..`, and any other path-traversal or odd byte.
    static func isSafeSessionID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
