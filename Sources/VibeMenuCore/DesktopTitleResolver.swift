import Foundation

// Adapters that turn the pure title parsers into `SessionTitleResolving`s the provider can use
// (docs/decisions/0014-enhanced-desktop-titles.md).
//
// `DesktopTitleResolver` is the untested-against-live edge that reads the Claude Desktop app's
// private session index; `CompositeTitleResolver` chains resolvers so the Desktop source can sit
// in front of the transcript source without either knowing about the other. The pure decoding is
// in `ClaudeDesktopTitleIndex`; this file is the file-I/O + caching + opt-in gate.

/// Real `SessionTitleResolving` backed by the Claude Desktop app's local session index
/// (`ClaudeDesktopTitleIndex`). Maps a CLI session id to the title Claude Code shows in its own
/// UI — the titles the transcript often never records.
///
/// ### Opt-in gate (privacy)
/// This reads **another app's** private, undocumented cache, so it is disabled by default and only
/// runs when the injected `isEnabled` closure returns `true`. The closure is consulted **before any
/// file access**: when the setting is off, `title(forSessionID:)` returns `nil` immediately and the
/// index directory is never opened, read, or stat-ed. The app wires `isEnabled` to the
/// "Use Claude Desktop session titles" preference; tests inject a constant.
///
/// ### What it reads
/// It globs `~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json` — both
/// UUID levels are enumerated, never assumed — and hands each file to `ClaudeDesktopTitleIndex`,
/// which keeps only the whitelisted title fields. A missing directory or schema change yields an
/// empty map (fail-closed): the composite chain then falls back to the transcript title.
///
/// ### Caching (so the ~2s tick stays cheap)
/// The `cliSessionID → title` map is cached together with a signature of the index files (their
/// paths + modification times + sizes). On each rebuild request the files are enumerated and
/// stat-ed (metadata only); the map is re-read and rebuilt **only when the signature changed**, so
/// an unchanged index costs a directory walk plus one `stat` per file — no file contents are read.
///
/// Concurrency: `@unchecked Sendable` — cache + signature are guarded by `lock`; the provider calls
/// `title(forSessionID:)` from its private utility queue.
public final class DesktopTitleResolver: SessionTitleResolving, @unchecked Sendable {
    private let sessionsDirectory: URL
    private let fileManager: FileManager
    private let isEnabled: @Sendable () -> Bool
    private let lock = NSLock()
    /// Last-built title map and the file signature it was built from (`nil` = never built or the
    /// directory was absent). Rebuilt only when the signature changes.
    private var cachedMap: [String: String] = [:]
    private var cachedSignature: String?

    /// The default Claude Desktop session-index root. This is **not** under `~/.claude` (the CLI
    /// store) — it lives in the Desktop app's Application Support container.
    public static var defaultSessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
    }

    /// - Parameters:
    ///   - isEnabled: consulted before every lookup; when it returns `false` nothing on disk is
    ///     touched. Defaults to always-off so a resolver constructed without wiring reads nothing.
    ///   - sessionsDirectory: index root (defaults to the real Desktop location; tests inject a temp
    ///     directory).
    public init(
        isEnabled: @escaping @Sendable () -> Bool = { false },
        sessionsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.isEnabled = isEnabled
        self.sessionsDirectory = sessionsDirectory ?? Self.defaultSessionsDirectory
        self.fileManager = fileManager
    }

    public func title(forSessionID id: String) -> String? {
        // Opt-in gate FIRST: when the setting is off we touch no Claude Desktop files at all.
        guard isEnabled() else { return nil }
        return currentMap()[id]
    }

    /// The current `cliSessionID → title` map, rebuilt from disk only when the index files changed
    /// since the last build. Enumerates `*/*/local_*.json` under the index root.
    private func currentMap() -> [String: String] {
        let files = indexFiles()
        let signature = Self.signature(of: files, fileManager: fileManager)

        lock.lock()
        if signature == cachedSignature {
            defer { lock.unlock() }
            return cachedMap
        }
        lock.unlock()

        // Signature changed (or first build): read + parse the whitelisted fields from each file.
        var records: [DesktopSessionRecord] = []
        records.reserveCapacity(files.count)
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            if let record = ClaudeDesktopTitleIndex.parse(record: data) {
                records.append(record)
            }
        }
        let map = ClaudeDesktopTitleIndex.buildTitleMap(from: records)

        lock.lock()
        cachedMap = map
        cachedSignature = signature
        lock.unlock()
        return map
    }

    /// Enumerate `<root>/<account>/<workspace>/local_*.json`. Both UUID levels are listed rather
    /// than assumed; only files named `local_*.json` are returned. A missing root (Desktop app not
    /// installed, or schema moved) yields an empty list — fail-closed. Metadata-only: no file
    /// contents are read here.
    private func indexFiles() -> [URL] {
        let accounts = subdirectories(of: sessionsDirectory)
        var files: [URL] = []
        for account in accounts {
            for workspace in subdirectories(of: account) {
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: workspace,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for entry in entries
                where entry.pathExtension == "json" && entry.lastPathComponent.hasPrefix("local_") {
                    files.append(entry)
                }
            }
        }
        return files
    }

    /// Immediate subdirectories of `url`, or `[]` if it can't be listed. Used to walk the two UUID
    /// levels without hardcoding their names.
    private func subdirectories(of url: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
    }

    /// A cheap change-signature over the index files: each file's path + mtime + size, sorted so
    /// the result is order-independent. Rebuilds happen only when this string changes, so an
    /// unchanged index costs stats, not reads.
    private static func signature(of files: [URL], fileManager: FileManager) -> String {
        files.map { url -> String in
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? 0
            return "\(url.path):\(mtime):\(size)"
        }
        .sorted()
        .joined(separator: "|")
    }
}

/// A `SessionTitleResolving` that consults an ordered list of resolvers and returns the first
/// non-`nil` title. Lets VibeMenu place the opt-in Desktop source ahead of the transcript source
/// without either resolver knowing about the other (docs/decisions/0014-enhanced-desktop-titles.md).
/// When the Desktop resolver is disabled (setting off) it returns `nil`, so the chain transparently
/// falls through to the transcript title — i.e. exactly today's behavior.
///
/// Concurrency: `Sendable` — holds only its immutable resolver list; each resolver manages its own
/// synchronization.
public final class CompositeTitleResolver: SessionTitleResolving, @unchecked Sendable {
    private let resolvers: [SessionTitleResolving]

    /// - Parameter resolvers: consulted in order; the first non-`nil` title wins.
    public init(_ resolvers: [SessionTitleResolving]) {
        self.resolvers = resolvers
    }

    public func title(forSessionID id: String) -> String? {
        for resolver in resolvers {
            if let title = resolver.title(forSessionID: id) { return title }
        }
        return nil
    }
}
