import Foundation

// Safe Codex Desktop session **titles** (docs/decisions/0017-codex-session-support.md).
//
// The project folder name alone is a weak session label ("VibeMenu"). Codex Desktop keeps a much
// better human title for each thread, and there is exactly one *safe* place to read it:
//
//   `~/.codex/session_index.jsonl` — a small newline-delimited index whose every line is
//   `{ "id": <session id>, "thread_name": <short title>, "updated_at": <int> }`.
//
// Why this source and not the SQLite DB: `~/.codex/state_5.sqlite`'s `threads.title` is NOT reliably
// safe — on this machine ~1 in 8 user threads had `title` set to the **raw first user message**
// (multi-line, URLs, thousands of characters — it equals the `first_user_message`/`preview` columns),
// and every internal subagent thread's title was raw content. The `session_index.jsonl` `thread_name`,
// by contrast, is the *curated* short title (all ≤ ~35 chars, single-line, no URL/path in the observed
// data) and the index already excludes subagents. Using it also avoids adding a libsqlite3 dependency
// the package doesn't otherwise need, and reuses the same JSONL-parsing posture as the rollout reader.
//
// ## Two independent safety layers (defense in depth)
//
//  1. **Allowlist by construction.** `CodexSessionIndexParser` reads ONLY `id` and `thread_name` from
//     each line. It never touches any other field, so no path/URL/prompt/account can be extracted even
//     if Codex adds one to the index. The output is a `[sessionID: title]` map of strings.
//  2. **Sanitiser (`CodexTitleSanitizer`).** Because the index is an unofficial, version-fragile file,
//     every `thread_name` is still passed through a strict filter before it can ever be shown: a title
//     is rejected (→ fall back to the folder name) if it is empty/generic, multi-line, contains a URL,
//     or looks like a filesystem path; anything that survives is length-capped for display. So even if
//     a future Codex build starts dumping raw prompt text into `thread_name`, the multi-line / URL /
//     path / length checks drop it rather than surfacing it.
//
// Fallback order for a session's display name (see `CodexSession.displayName`): sanitised title →
// project folder basename → generic "Codex session". Pure/testable here; the file I/O is the thin
// `CodexSessionIndexReader` adapter. Display-only — never keeps the Mac awake.

// MARK: - Title sanitiser (pure)

public enum CodexTitleSanitizer {
    /// Display cap for a session title. Real curated titles are far shorter; this bounds a
    /// pathological value and is applied *after* the reject checks. The row view also tail-truncates
    /// visually, so this is a hard safety bound rather than the primary truncation.
    public static let maxDisplayLength = 48

    /// Generic/placeholder titles that carry no information and should defer to the folder name.
    /// Compared case-insensitively against the trimmed title.
    static let genericTitles: Set<String> = [
        "", "new thread", "untitled", "new chat", "new session", "new conversation",
        "new task", "conversation", "chat", "codex", "codex session",
    ]

    /// Scalars that disqualify a title as "a single clean line": every control/format character
    /// (Unicode Cc + Cf — tabs, zero-width, bidi overrides, BOM) **and** every newline. The newline
    /// set is unioned in explicitly because U+2028 / U+2029 (LINE / PARAGRAPH SEPARATOR) are line
    /// breaks of category Zl / Zp that `controlCharacters` does *not* include — without this, an
    /// interior one would let a multi-line title (e.g. a raw prompt) slip through the reject below.
    static let disallowedScalars = CharacterSet.controlCharacters.union(.newlines)

    /// Turn a raw `thread_name` into a safe, displayable title, or `nil` if it must not be shown.
    ///
    /// `nil` means "fall back to the folder name". A title is rejected when it is empty/whitespace,
    /// a known generic placeholder, multi-line / contains any control character, contains a URL, or
    /// looks like a filesystem path. A surviving title is trimmed and length-capped (with an ellipsis)
    /// for display. Pure and I/O-free.
    public static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Generic placeholder → prefer the folder name.
        if genericTitles.contains(trimmed.lowercased()) { return nil }

        // Reject any control/format character or newline (incl. U+2028/U+2029). A real one-line title
        // has none; the raw multi-line first-message blobs seen in state_5.sqlite all trip this.
        if trimmed.unicodeScalars.contains(where: { Self.disallowedScalars.contains($0) }) {
            return nil
        }

        // Reject anything that looks like a URL or git remote. Most have a slash (caught below), but a
        // few forms don't — a bare `www.host` or an `git@host` remote — so gate those by substring too.
        let lower = trimmed.lowercased()
        if lower.contains("://") || lower.contains("http") || lower.contains("www.")
            || lower.contains("git@") {
            return nil
        }

        // Reject any slash or backslash outright. A curated one-line session title never contains a
        // path separator, so treating every `/` or `\` as suspicious blocks the whole class of path and
        // URL-fragment leaks (absolute *and* relative — `/Users/bob/secret`, `Users/bob/secret`,
        // `src/app/secret.ts`, `C:\path`) with no false positives on real titles.
        if trimmed.contains("/") || trimmed.contains("\\") {
            return nil
        }

        return truncatedForDisplay(trimmed)
    }

    /// Cap a already-validated title to `maxDisplayLength`, appending an ellipsis. Grapheme-safe
    /// (`prefix` operates on Characters) and trims a trailing space before the ellipsis so the cut
    /// never reads as "word …".
    static func truncatedForDisplay(_ title: String) -> String {
        guard title.count > maxDisplayLength else { return title }
        let head = title.prefix(maxDisplayLength - 1)
            .description
            .trimmingCharacters(in: .whitespaces)
        return head + "…"
    }
}

// MARK: - session_index.jsonl parser (pure)

public enum CodexSessionIndexParser {
    /// Bound on lines scanned so a pathological index can't stall a tick. The real index is one line
    /// per recent thread (tens of lines); this is far beyond any real file.
    static let maxLinesScanned = 100_000

    /// Parse `~/.codex/session_index.jsonl` text into a `[sessionID: safeTitle]` map.
    ///
    /// Reads ONLY `id` (String) and `thread_name` (String) from each line — nothing else is ever
    /// touched. Each `thread_name` is passed through `CodexTitleSanitizer`; entries whose title is
    /// unsafe/empty/generic are dropped (so the session falls back to its folder name). Malformed
    /// lines are skipped. Pure and I/O-free.
    public static func parse(text: String) -> [String: String] {
        var titles: [String: String] = [:]
        var scanned = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            scanned += 1
            if scanned > maxLinesScanned { break }
            guard let data = rawLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let line = object as? [String: Any],
                  let id = line["id"] as? String, !id.isEmpty else { continue }
            // Only `thread_name` is read for the title; everything else on the line is ignored.
            guard let safe = CodexTitleSanitizer.sanitize(line["thread_name"] as? String) else { continue }
            titles[id] = safe
        }
        return titles
    }
}

// MARK: - File adapter

/// Reads the Codex session-title map. The seam lets the reader be driven by a fake in tests with no
/// real `~/.codex/session_index.jsonl`.
public protocol CodexSessionTitleReading: Sendable {
    /// A `[sessionID: safeTitle]` map (empty on any error / when the index is missing).
    func titles() -> [String: String]
}

/// The real reader over `~/.codex/session_index.jsonl`.
///
/// Concurrency: `@unchecked Sendable` — it holds only immutable configuration; each `titles()` call is
/// a self-contained read with no shared mutable state.
public final class CodexSessionIndexReader: CodexSessionTitleReading, @unchecked Sendable {
    /// `~/.codex/session_index.jsonl`.
    public static var defaultIndexURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl", isDirectory: false)
    }

    /// Upper bound on how much of the index to read. The real file is a few KB; this defends against a
    /// pathological size while comfortably covering any realistic index.
    public static let defaultMaxBytes = 4 * 1024 * 1024

    private let url: URL
    private let maxBytes: Int
    private let fileManager: FileManager

    public init(
        url: URL? = nil,
        maxBytes: Int = CodexSessionIndexReader.defaultMaxBytes,
        fileManager: FileManager = .default
    ) {
        self.url = url ?? Self.defaultIndexURL
        self.maxBytes = maxBytes
        self.fileManager = fileManager
    }

    public func titles() -> [String: String] {
        // Cheap stat gate: skip a missing or oversized file without opening it whole.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size, size >= 0 else { return [:] }
        let data: Data?
        if size <= maxBytes {
            data = try? Data(contentsOf: url)
        } else {
            // Read only the head under the cap — enough to cover the most recent entries.
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
            defer { try? handle.close() }
            data = (try? handle.read(upToCount: maxBytes)) ?? nil
        }
        guard let data else { return [:] }
        return CodexSessionIndexParser.parse(text: String(decoding: data, as: UTF8.self))
    }
}
