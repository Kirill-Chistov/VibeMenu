import Foundation

// Session title extraction (docs/decisions/0013-session-title-and-dismiss.md).
//
// The Session Radar leads each row with a human-readable name. Until now that name was, at
// best, the project *folder name* the hook captured from cwd (docs/decisions/0012) — which
// cannot tell two sessions in the same repo apart and never matches the title Claude Code
// itself shows in its session list. The product requirement (owner-approved, 2026-07-05) is
// to display **Claude Code's own human-readable session title** when it can be read safely.
//
// Claude Code stores that title inside the session transcript
// (`~/.claude/projects/<encoded-cwd>/<session_id>.jsonl`) as dedicated one-field records:
//   * `{"type":"custom-title","customTitle":"…","sessionId":"…"}` — the title the user set
//     by renaming the session (may appear several times; the last one wins).
//   * `{"type":"ai-title","aiTitle":"…","sessionId":"…"}` — the title Claude Code
//     auto-generates (what un-renamed sessions like "Greeting" show).
// Claude Code displays the custom title if present, else the AI title — so the radar mirrors
// that: prefer the last `custom-title`, else the last `ai-title`.
//
// **Hard privacy narrowing (docs/PRIVACY.md, AGENTS.md §6, ADR 0013).** This is the *only*
// place VibeMenu ever opens a Claude transcript, and it reads a deliberately tiny slice:
//   * It decodes a line **only if that line is literally a title record** — a cheap substring
//     pre-filter (`"custom-title"` / `"ai-title"`) means prompt, response, tool, attachment,
//     and `last-prompt` lines are never even JSON-parsed.
//   * From a decoded title record it keeps **only** the `customTitle` / `aiTitle` string.
//   * It never reads, stores, or logs prompt text, assistant responses, `lastPrompt`, tool
//     input/output, `cwd`, `gitBranch`, or any other field — and nothing ever leaves the Mac.
// This file is pure and I/O-free so the whole extraction is unit-tested with synthetic
// fixtures containing fake, non-sensitive data. The file reading + caching lives in the
// `TranscriptTitleResolver` adapter (below), mirroring how the heartbeat reader is split from
// its pure decoder.

// MARK: - Pure parser

/// Pure extraction of a Claude Code session's human-readable title from its transcript bytes.
/// Reads only `custom-title` / `ai-title` records and only their title field (see the file
/// note) — never prompt/response/`lastPrompt`/message content.
public enum ClaudeSessionTitle {
    /// The transcript record `type` values that carry a title. Nothing else is decoded.
    static let customTitleType = "custom-title"
    static let aiTitleType = "ai-title"

    /// Upper bound on a displayed title's length, so a pathological title can't blow up the
    /// menu row. Titles Claude Code generates are short; this is only a backstop.
    static let maxTitleLength = 80

    /// The only fields ever pulled from a transcript line. A title record has exactly one of
    /// `customTitle` / `aiTitle`; every other record type decodes all-`nil` and is ignored.
    private struct TitleDTO: Decodable {
        let type: String?
        let customTitle: String?
        let aiTitle: String?
    }

    /// Extract the title from a transcript's raw bytes. Splits into lines and delegates to the
    /// line parser. Returns `nil` for non-UTF8 data or a transcript with no title record.
    public static func parse(transcript data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // `split` over the whole string keeps this allocation-light; empty lines are dropped.
        return parse(lines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    /// Extract the title from already-split transcript lines. Prefers the **last** custom title
    /// (user rename) over the **last** AI title, matching what Claude Code displays. Pure.
    ///
    /// The substring pre-filter is load-bearing for privacy, not just speed: a line that is not
    /// a title record is never handed to `JSONDecoder`, so prompt/response/tool bodies are never
    /// parsed. A message body that merely happens to contain the literal text `"custom-title"`
    /// would be decoded, but its `type` is `assistant`/`user` (not a title type) so it is
    /// discarded — no title, no other field kept.
    public static func parse(lines: [String]) -> String? {
        var lastCustom: String?
        var lastAI: String?
        for line in lines {
            let looksCustom = line.contains("\"\(customTitleType)\"")
            let looksAI = line.contains("\"\(aiTitleType)\"")
            guard looksCustom || looksAI else { continue }
            guard
                let data = line.data(using: .utf8),
                let dto = try? JSONDecoder().decode(TitleDTO.self, from: data),
                let type = dto.type
            else { continue }
            switch type {
            case customTitleType:
                if let title = normalize(dto.customTitle) { lastCustom = title }
            case aiTitleType:
                if let title = normalize(dto.aiTitle) { lastAI = title }
            default:
                continue   // a non-title record that merely contained the marker text
            }
        }
        return lastCustom ?? lastAI
    }

    /// Trim whitespace/newlines, reject empty, and cap length. A title that is empty or all
    /// whitespace normalises to `nil` so the caller falls back to the folder name.
    private static func normalize(_ raw: String?) -> String? {
        guard
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return String(trimmed.prefix(maxTitleLength))
    }
}

// MARK: - Resolver seam

/// Resolves the human-readable title for a Claude Code session id. The seam lets the provider
/// attach titles without the pure `ClaudeSessionStore` knowing anything about transcripts, and
/// lets tests inject a fake (or `nil`) instead of touching `~/.claude`.
public protocol SessionTitleResolving: AnyObject, Sendable {
    /// The title for a session, or `nil` if none is safely available (no transcript found, no
    /// title record yet, or any read error). Must never throw and never block the radar.
    func title(forSessionID id: String) -> String?
}
