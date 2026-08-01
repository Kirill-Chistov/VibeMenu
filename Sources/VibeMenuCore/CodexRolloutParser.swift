import Foundation

// Pure, allowlist-only parser for Codex Desktop rollout files
// (docs/decisions/0017-codex-session-support.md).
//
// A Codex rollout is newline-delimited JSON (`~/.codex/sessions/**/rollout-*.jsonl`). Each line is
// an envelope `{ "timestamp": ISO8601, "type": String, "payload": {...} }`. This parser reads a
// **strict allowlist** of metadata and nothing else:
//
//   ALLOWED (the only fields ever touched):
//     • line `timestamp`                              → activity recency
//     • `type == "session_meta"` payload:
//         - `session_id` / `id`                       → opaque row id (never shown)
//         - `originator`                              → gate: keep "Codex Desktop", drop CLI
//         - `cwd`  → **basename only**                → project folder name
//         - `timestamp`                               → session start
//     • `type == "event_msg"` payload `type`          → event *category* only, to spot the
//                                                       `task_complete` completion marker
//
//   NEVER READ: any message/user_message/agent_message/reasoning payload body, tool input/output,
//   command text, the full `cwd` path, `git.*` (repo URL/branch/sha), `base_instructions`,
//   account ids, tokens, or auth. Reading `payload.type == "user_message"` reads only the *label*
//   of the event, never its text. The output struct structurally cannot hold any content field.
//
// Malformed lines are skipped; a file with no `session_meta`, or one whose originator isn't the
// Desktop app, yields `nil` (ignored). Pure and I/O-free — the `CodexSessionReader` adapter owns
// the file access and size/recency bounds.

/// The safe, allowlisted summary of one Codex rollout file. Contains only metadata — no content,
/// no path, no repo, no account.
public struct CodexRolloutSummary: Equatable, Sendable {
    /// The Codex session id (opaque). Row identity + dedup; never displayed.
    public let sessionID: String

    /// The `originator` string verbatim (e.g. `"Codex Desktop"`). The reader gates on this to keep
    /// only Desktop sessions and ignore the shared CLI.
    public let originator: String

    /// The project **folder name** — basename of `cwd` — or `nil` if unavailable. Never a path.
    public let folderName: String?

    /// When Codex started the session (`session_meta.timestamp`, else the first line's timestamp).
    public let startedAt: Date

    /// The newest line timestamp seen — the session's last activity.
    public let lastActivity: Date

    /// Whether the latest turn ended with a `task_complete` event (the reliable "done" marker).
    public let endedWithCompletion: Bool

    /// Whether this rollout is an **internal subagent** run (`session_meta.source` is an object with a
    /// `subagent` key, e.g. Codex's own `guardian`/tool subagents). These are not user-facing Desktop
    /// sessions — the reader drops them so they never surface as a phantom/duplicate row. Only the
    /// *category* of `source` is inspected (subagent vs not); its contents are never read or stored.
    public let isSubagent: Bool

    public init(
        sessionID: String,
        originator: String,
        folderName: String?,
        startedAt: Date,
        lastActivity: Date,
        endedWithCompletion: Bool,
        isSubagent: Bool = false
    ) {
        self.sessionID = sessionID
        self.originator = originator
        self.folderName = folderName
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.endedWithCompletion = endedWithCompletion
        self.isSubagent = isSubagent
    }
}

/// Safe, resumable parser state for one rollout. Every field is already part of the allowlisted
/// summary (or is the minimum bookkeeping needed to derive it); no message, tool, reasoning, path,
/// repository, or account content can be retained here.
struct CodexRolloutParsingState: Equatable, Sendable {
    var sessionID: String?
    var originator: String?
    var folderName: String?
    var startedAt: Date?
    var newestLine: Date?
    /// `nil` until an `event_msg` category is seen; afterward records only whether the latest one
    /// was `task_complete`, never the category string itself.
    var lastEventWasCompletion: Bool?
    var isSubagent = false
    var scannedLines = 0

    func summary(fallbackActivity: Date?) -> CodexRolloutSummary? {
        guard let sessionID, let originator else { return nil }
        let resolvedStart = startedAt ?? newestLine ?? fallbackActivity
        let resolvedActivity = newestLine ?? fallbackActivity ?? resolvedStart
        guard let resolvedStart, let resolvedActivity else { return nil }

        return CodexRolloutSummary(
            sessionID: sessionID,
            originator: originator,
            folderName: folderName,
            startedAt: Swift.min(resolvedStart, resolvedActivity),
            lastActivity: resolvedActivity,
            endedWithCompletion: lastEventWasCompletion == true,
            isSubagent: isSubagent
        )
    }
}

struct CodexRolloutChunkParse: Sendable {
    let state: CodexRolloutParsingState
    /// Bytes after the final newline. They may be a JSON object split across polling ticks and are
    /// intentionally not decoded until a later append completes the line.
    let incompleteTrailingBytes: Data
}

public enum CodexRolloutParser {
    /// The one `event_msg` category treated as a completion marker.
    public static let completionEventType = "task_complete"

    /// The canonical originator string that identifies the Codex **Desktop** app (as opposed to the
    /// CLI). Sessions with any other originator are ignored by the reader.
    public static let desktopOriginator = "Codex Desktop"

    /// Whether an `originator` names the Codex **Desktop** app (keep) rather than the shared CLI
    /// (drop). Used by both the session reader and the usage-limits reader as the single Desktop gate.
    ///
    /// Two forms are accepted, both **narrowly allowlisted** — never a plain `contains`:
    ///   1. the canonical spaced form `"Codex Desktop"` (case-insensitive, whitespace-trimmed);
    ///   2. the anchored underscore family `codex_<segment…>_desktop` — e.g. `codex_work_desktop`,
    ///      the id newer Codex Desktop builds emit. It must start `codex_`, end `_desktop`, and have a
    ///      non-empty middle of only word characters.
    ///
    /// Real local data carries both `Codex Desktop` and `codex_work_desktop`, so an exact match hides
    /// legitimate Desktop rollouts (their sessions and usage limits). The family form stays anchored at
    /// both ends so the CLI (`codex_cli_rs`) and anything merely *containing* "desktop" are still
    /// rejected. Verified against approved local rollouts (see docs/DEVELOPMENT_LOG.md, ADR 0017).
    public static func isDesktopOriginator(_ originator: String) -> Bool {
        let trimmed = originator.trimmingCharacters(in: .whitespacesAndNewlines)
        // 1) Canonical spaced form.
        if trimmed.caseInsensitiveCompare(desktopOriginator) == .orderedSame { return true }
        // 2) Anchored `codex_<middle>_desktop` family.
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("codex_"), lower.hasSuffix("_desktop") else { return false }
        let middle = lower.dropFirst("codex_".count).dropLast("_desktop".count)
        guard !middle.isEmpty else { return false }   // reject the bare "codex__desktop" / overlaps
        return middle.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Parse one rollout file's text into a safe summary, or `nil` if it isn't a usable
    /// Codex Desktop rollout (no `session_meta`, no id, or no usable timestamp).
    ///
    /// `fallbackActivity` (the file's mtime, supplied by the reader) is used only if the file
    /// carries no parseable line timestamp at all — so a valid session with an odd body still gets
    /// an honest last-activity time rather than being dropped.
    public static func parse(text: String, fallbackActivity: Date? = nil) -> CodexRolloutSummary? {
        var state = CodexRolloutParsingState()

        // Two ISO8601 formatters built once per file (not per line): fractional-seconds first, then
        // plain. Kept local — `ISO8601DateFormatter` isn't `Sendable`, so a shared static would be a
        // concurrency hazard (matches `ClaudeDesktopUsageCacheReader.parseISO`).
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        func parseTimestamp(_ string: String) -> Date? {
            isoFractional.date(from: string) ?? isoPlain.date(from: string)
        }

        // Bound the number of lines scanned so a pathologically long file can't stall a tick; the
        // reader also caps bytes read. 200k lines is far beyond any real rollout.
        var scanned = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            scanned += 1
            if scanned > 200_000 { break }
            guard let data = rawLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let line = object as? [String: Any] else { continue }
            state.scannedLines = scanned
            consume(line: line, into: &state, parseTimestamp: parseTimestamp)
        }
        return state.summary(fallbackActivity: fallbackActivity)
    }

    /// Strict incremental JSONL parsing used by `CodexSessionReader`. Only newline-terminated lines
    /// are decoded; an incomplete tail is returned for the next polling tick. A malformed *complete*
    /// line fails the chunk so changed content cannot inherit an obsolete active summary. The public
    /// one-shot parser above remains lenient for compatibility with its existing pure-parser API.
    static func parseIncrementalChunk(
        _ data: Data,
        startingWith initialState: CodexRolloutParsingState = CodexRolloutParsingState()
    ) -> CodexRolloutChunkParse? {
        var state = initialState
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        func parseTimestamp(_ string: String) -> Date? {
            isoFractional.date(from: string) ?? isoPlain.date(from: string)
        }

        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            var line = data[lineStart..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            lineStart = data.index(after: newline)

            // Match the one-shot parser's empty-line tolerance. JSON whitespace-only separators are
            // equally harmless and do not carry any metadata.
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            state.scannedLines += 1
            if state.scannedLines > 200_000 { continue }

            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let envelope = object as? [String: Any]
            else { return nil }
            consume(line: envelope, into: &state, parseTimestamp: parseTimestamp)
        }

        return CodexRolloutChunkParse(
            state: state,
            incompleteTrailingBytes: Data(data[lineStart...])
        )
    }

    // MARK: - Helpers

    /// The final path component of `cwd`, or `nil` if it's empty / the root. Deliberately discards
    /// the rest of the path immediately — the full path is never returned or stored.
    static func folderName(fromCwd cwd: String) -> String? {
        let name = (cwd as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return name
    }

    private static func max(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return Swift.max(lhs, rhs)
    }

    private static func consume(
        line: [String: Any],
        into state: inout CodexRolloutParsingState,
        parseTimestamp: (String) -> Date?
    ) {
        // Line timestamp (activity recency) — allowlisted.
        if let ts = line["timestamp"] as? String, let date = parseTimestamp(ts) {
            state.newestLine = Self.max(state.newestLine, date)
        }

        guard let type = line["type"] as? String,
              let payload = line["payload"] as? [String: Any] else { return }

        switch type {
        case "session_meta":
            // Only these four payload fields are ever read.
            if state.sessionID == nil {
                state.sessionID = (payload["session_id"] as? String) ?? (payload["id"] as? String)
            }
            if state.originator == nil { state.originator = payload["originator"] as? String }
            if state.folderName == nil, let cwd = payload["cwd"] as? String {
                state.folderName = Self.folderName(fromCwd: cwd)
            }
            // Read ONLY whether `source` is a subagent object — never its contents.
            if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                state.isSubagent = true
            }
            if state.startedAt == nil, let ts = payload["timestamp"] as? String {
                state.startedAt = parseTimestamp(ts)
            }
        case "event_msg":
            // Retain one bit only: whether the newest event category is the completion marker.
            if let category = payload["type"] as? String {
                state.lastEventWasCompletion = category == completionEventType
            }
        default:
            break   // response_item / world_state / turn_context etc. — nothing safe to add
        }
    }
}
