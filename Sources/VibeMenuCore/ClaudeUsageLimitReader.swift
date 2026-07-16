import Foundation

// Reading VibeMenu's own usage-limit file (docs/decisions/0016-claude-usage-limits.md).
//
// The opt-in statusLine shim (Support/ClaudeUsage/vibemenu-usage-statusline.sh) writes a tiny,
// whitelisted JSON file that carries ONLY: a schema version, a capture timestamp, the opaque
// session id, the Claude CLI version string, and the two usage windows (each a used-percent +
// a reset epoch). This file is VibeMenu's own — like the heartbeat files, NOT a Claude
// transcript — and it never contains prompts, responses, tool I/O, cwd/paths, cost, spend, or
// billing (the shim's structural parser extracts only `rate_limits.{five_hour,seven_day}`,
// `session_id`, `version`). Reading it is therefore safe under the privacy contract.
//
// This file is split like the heartbeat: a pure, malformed-safe `parse` (unit-tested against
// synthetic bytes) plus a thin, read-only file adapter. A missing file, a half-written file, a
// non-JSON file, or a schema change all yield `.unavailable` rather than a crash.

/// Reads the current usage-limit snapshot from wherever the shim writes it. The seam lets the
/// observable model be driven by a fake in tests without touching the real file.
public protocol ClaudeUsageLimitReading: AnyObject, Sendable {
    /// The latest snapshot, or `.unavailable` when no usable file exists.
    func readSnapshot() -> ClaudeUsageLimitSnapshot
}

/// Pure decoding of the VibeMenu usage file + the default on-disk location. No I/O here beyond
/// what the adapter passes in.
public enum ClaudeUsageLimitFile {
    /// The schema VibeMenu's shim writes. Bumped only on a breaking layout change; the reader
    /// tolerates unknown future versions best-effort.
    public static let currentSchemaVersion = 1

    /// The whitelisted on-disk shape. `JSONDecoder` ignores any key without a matching property
    /// here, so even if a future shim wrote extra fields they could never reach the model — the
    /// DTO is the load-bearing privacy boundary, exactly as in `ClaudeHeartbeatRecord`.
    private struct FileDTO: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let resetsAt: Double?   // epoch seconds
        }
        let schemaVersion: Int?
        let capturedAt: Double?     // epoch seconds
        let sessionID: String?
        let cliVersion: String?
        let fiveHour: Window?
        let sevenDay: Window?
    }

    /// Parse the usage file's raw bytes into a snapshot, or `nil` if the bytes are not a usage
    /// object. A window contributes a row only when it carries a numeric `usedPercent`
    /// (`resetsAt` is optional). Returns a snapshot with an empty `limits` array (not `nil`) when
    /// the file is a valid object but carries no usable window, so callers can distinguish
    /// "parsed but empty" from "unparseable".
    public static func parse(
        fileData: Data,
        source: ClaudeUsageLimitSource = .statusLine
    ) -> ClaudeUsageLimitSnapshot? {
        guard let dto = try? JSONDecoder().decode(FileDTO.self, from: fileData) else { return nil }

        var limits: [ClaudeUsageLimit] = []
        if let row = row(from: dto.fiveHour, kind: .fiveHour) { limits.append(row) }
        if let row = row(from: dto.sevenDay, kind: .sevenDay) { limits.append(row) }

        let sessionID = dto.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeUsageLimitSnapshot(
            limits: limits,
            capturedAt: dto.capturedAt.map { Date(timeIntervalSince1970: $0) },
            sessionID: (sessionID?.isEmpty == false) ? sessionID : nil,
            source: source
        )
    }

    /// Build one row from a window DTO, or `nil` when the window is absent or has no percentage.
    private static func row(from window: FileDTO.Window?, kind: ClaudeUsageLimitKind) -> ClaudeUsageLimit? {
        guard let window, let used = window.usedPercent, used.isFinite else { return nil }
        return ClaudeUsageLimit(
            kind: kind,
            usedPercent: used,
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// The VibeMenu-owned usage file the shim writes:
    /// `~/Library/Application Support/VibeMenu/ClaudeUsage/usage.json`. Mirrors how the heartbeat
    /// directory is derived — VibeMenu's own Application Support subtree, never `~/.claude`.
    public static var defaultURL: URL {
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
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)
    }
}

/// Real read-only adapter: loads the usage file and decodes it via the pure parser. Any read or
/// decode failure collapses to `.unavailable`; it never throws and never crashes on a partial or
/// corrupt file (the classic half-written-file race is just a failed decode → `.unavailable`).
public final class FileClaudeUsageLimitReader: ClaudeUsageLimitReading, @unchecked Sendable {
    private let url: URL

    public init(url: URL = ClaudeUsageLimitFile.defaultURL) {
        self.url = url
    }

    public func readSnapshot() -> ClaudeUsageLimitSnapshot {
        guard
            let data = try? Data(contentsOf: url),
            let snapshot = ClaudeUsageLimitFile.parse(fileData: data)
        else {
            return .unavailable
        }
        return snapshot
    }
}
