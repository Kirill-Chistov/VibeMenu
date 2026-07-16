import Foundation

// Enhanced (opt-in) session-title source: the Claude Desktop app's local session index
// (docs/decisions/0014-enhanced-desktop-titles.md).
//
// Claude Code does NOT reliably write its visible session title into the transcript, so the
// transcript-only `ClaudeSessionTitle` path leaves many sessions on their folder-name fallback.
// The title Claude Code shows in its own UI is stored instead by the **Claude Desktop app** in
// a private, undocumented on-disk index:
//   ~/Library/Application Support/Claude/claude-code-sessions/<account>/<workspace>/local_<uuid>.json
// One JSON object per session. VibeMenu can read the visible title from there, but only behind
// an explicit opt-in setting because this is another app's internal cache (see the adapter
// `DesktopTitleResolver`).
//
// **Hard privacy narrowing (docs/PRIVACY.md, AGENTS.md §6, ADR 0014).** This parser is the only
// place VibeMenu decodes a Claude Desktop index file, and it keeps a deliberately tiny slice:
//   * The `Decodable` DTO declares ONLY the whitelisted keys — `cliSessionId`, `title`,
//     `titleSource`, `lastActivityAt`, `isArchived`. Every other field in the file
//     (`promptSuggestion`, `alwaysAllowedReasons`, `cwd`, `model`, …) is never decoded, never
//     read, never stored. `JSONDecoder` silently ignores keys absent from the DTO.
//   * A record with no `cliSessionId` or no non-empty `title` is dropped (returns `nil`).
//   * No title, id, or path is ever logged (only synthetic test fixtures print titles).
// This file is pure and I/O-free so the whole extraction is unit-tested with synthetic fixtures
// containing fake, non-sensitive data. The file globbing + caching lives in the
// `DesktopTitleResolver` adapter, mirroring how `TranscriptTitleResolver` wraps
// `ClaudeSessionTitle`.

/// One whitelisted record parsed from a Claude Desktop `local_<uuid>.json` session-index file.
/// Carries only the fields needed to map a CLI session id to its visible title and to break ties
/// between duplicates — nothing else from the file is retained.
public struct DesktopSessionRecord: Equatable, Sendable {
    /// The Claude CLI session id (= VibeMenu's session id, = the transcript `<id>.jsonl` stem).
    /// This is the join key against a `ClaudeSession.id`.
    public let cliSessionID: String
    /// The visible, human-readable title Claude Code shows for the session (trimmed, length-capped).
    public let title: String
    /// How the title was produced (`"auto"` for AI-generated, or a user-set source). Kept only for
    /// diagnostics/future use; not currently displayed.
    public let titleSource: String?
    /// Last-activity timestamp (epoch milliseconds) used to pick the freshest of several records
    /// that share a `cliSessionID`. `nil` when the file omits it (treated as oldest).
    public let lastActivityAt: Double?
    /// Whether the session is archived in the Desktop app. An archived title is used only when no
    /// non-archived record exists for the same `cliSessionID`.
    public let isArchived: Bool

    public init(
        cliSessionID: String,
        title: String,
        titleSource: String? = nil,
        lastActivityAt: Double? = nil,
        isArchived: Bool = false
    ) {
        self.cliSessionID = cliSessionID
        self.title = title
        self.titleSource = titleSource
        self.lastActivityAt = lastActivityAt
        self.isArchived = isArchived
    }
}

/// Pure decoding + reduction of Claude Desktop session-index files into a `cliSessionID → title`
/// map. Reads only the whitelisted fields (see the file note) — never prompts, responses, tool
/// output, `promptSuggestion`, `alwaysAllowedReasons`, `cwd`, or any other field.
public enum ClaudeDesktopTitleIndex {
    /// The only fields ever pulled from an index file. Any other key present in the JSON is
    /// ignored by `JSONDecoder` because it has no matching property here — this is the load-bearing
    /// privacy boundary, not just convenience.
    private struct RecordDTO: Decodable {
        let cliSessionId: String?
        let title: String?
        let titleSource: String?
        let lastActivityAt: Double?
        let isArchived: Bool?
    }

    /// Parse one index file's raw bytes into a whitelisted record, or `nil` if the bytes are not
    /// UTF-8/JSON, carry no `cliSessionId`, or carry no non-empty `title`. Malformed or unexpected
    /// JSON never throws out of here.
    public static func parse(record data: Data) -> DesktopSessionRecord? {
        guard let dto = try? JSONDecoder().decode(RecordDTO.self, from: data) else { return nil }
        guard
            let id = dto.cliSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty,
            let title = normalize(dto.title)
        else { return nil }
        return DesktopSessionRecord(
            cliSessionID: id,
            title: title,
            titleSource: dto.titleSource,
            lastActivityAt: dto.lastActivityAt,
            isArchived: dto.isArchived ?? false
        )
    }

    /// Reduce a set of parsed records to the single best title per `cliSessionID`:
    ///   * a **non-archived** record always beats an archived one (archived titles are used only
    ///     when there is no non-archived record for that id);
    ///   * among records with the same archived-ness, the one with the **latest** `lastActivityAt`
    ///     wins (a missing timestamp sorts oldest). Ties keep the first record seen, so the result
    ///     is deterministic for a given input.
    public static func buildTitleMap(from records: [DesktopSessionRecord]) -> [String: String] {
        var best: [String: DesktopSessionRecord] = [:]
        for record in records {
            if let existing = best[record.cliSessionID] {
                best[record.cliSessionID] = preferred(existing, record)
            } else {
                best[record.cliSessionID] = record
            }
        }
        return best.mapValues { $0.title }
    }

    /// Which of two records for the same id should supply the title. See `buildTitleMap` rules.
    /// `keep` is the incumbent (kept on an exact activity tie).
    private static func preferred(
        _ keep: DesktopSessionRecord, _ candidate: DesktopSessionRecord
    ) -> DesktopSessionRecord {
        if keep.isArchived != candidate.isArchived {
            return keep.isArchived ? candidate : keep     // non-archived always wins
        }
        let keepAt = keep.lastActivityAt ?? -.greatestFiniteMagnitude
        let candidateAt = candidate.lastActivityAt ?? -.greatestFiniteMagnitude
        return candidateAt > keepAt ? candidate : keep    // freshest wins; tie keeps incumbent
    }

    /// Trim whitespace/newlines, reject empty, and cap length (shared with `ClaudeSessionTitle`).
    private static func normalize(_ raw: String?) -> String? {
        guard
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return String(trimmed.prefix(ClaudeSessionTitle.maxTitleLength))
    }
}
