import Foundation

// Pure compose/uninstall logic for the opt-in one-click statusLine install
// (docs/decisions/0016-claude-usage-limits.md).
//
// VibeMenu's usage capture needs a Claude Code `statusLine` command that writes the whitelisted
// `rate_limits` to VibeMenu's file. There is only ONE statusLine slot in `~/.claude/settings.json`,
// so installing must **compose** with any existing status line rather than clobber it: VibeMenu's
// shim wraps the user's original command (base64-encoded into the shim's own `--wrap` argument, so
// no fragile quoting and no sidecar file) and re-emits its output, leaving the terminal status line
// unchanged. Uninstall is fully self-contained: the original command is recovered from the base64.
//
// This transform is pure and unit-tested. The app layer only reads/writes the file, shows the
// preview for confirmation, and writes a timestamped backup first (mirroring the existing
// `settings.json.vibemenu-backup-*` convention). Because it edits the user's Claude Code config, it
// is strictly opt-in, preview-gated, backed up, and reversible — a deliberate, narrow extension of
// VibeMenu's prior "never edits settings.json for you" stance (see the ADR).

public enum StatusLineInstaller {
    /// Substring that identifies VibeMenu's shim inside a `statusLine.command`, independent of the
    /// install path (so a moved .app is still recognised as "already installed").
    public static let marker = "vibemenu-usage-statusline"

    /// The current install state of VibeMenu's usage capture in a settings file.
    public enum InstallState: Equatable {
        /// No VibeMenu usage statusLine present (there may be an unrelated user statusLine).
        case notInstalled(existingCommand: String?)
        /// VibeMenu's shim is the statusLine command; `wrappedOriginal` is the user command it wraps.
        case installed(shimCommand: String, wrappedOriginal: String?)
    }

    /// The outcome of composing VibeMenu's shim into a settings file.
    public struct ComposeResult: Equatable {
        /// The full settings JSON to write (pretty-printed, sorted keys), with only `statusLine` changed.
        public let updatedJSON: Data
        /// The exact `statusLine.command` string that was set.
        public let newCommand: String
        /// The user's original command that is now wrapped, or `nil` if there was none.
        public let wrappedOriginal: String?
        /// Whether VibeMenu's shim was already installed before this compose (idempotent re-install).
        public let wasAlreadyInstalled: Bool
    }

    // MARK: - Command string helpers

    /// The `statusLine.command` VibeMenu sets: the shim path (single-quoted for the shell) plus, when
    /// wrapping an existing command, ` --wrap <base64>` so the original is preserved verbatim and can
    /// be restored on uninstall. Base64 has no shell metacharacters, so no further quoting is needed.
    /// Any single quote in the path is escaped with the POSIX `'\''` idiom, so a home dir / username
    /// containing an apostrophe cannot break the shell quoting.
    public static func command(shimPath: String, wrapping original: String?) -> String {
        let escaped = shimPath.replacingOccurrences(of: "'", with: "'\\''")
        let base = "'\(escaped)'"
        guard let original, !original.isEmpty else { return base }
        let encoded = Data(original.utf8).base64EncodedString()
        return "\(base) --wrap \(encoded)"
    }

    /// Whether it is safe for VibeMenu to modify the settings file. `true` when it is absent/empty (we
    /// create it fresh) or a parseable JSON **object**; `false` when it is non-empty but not a JSON
    /// object (a syntax error, or a top-level array/scalar). Composing over unparseable data would
    /// silently drop every other key, so the app must refuse and surface an error instead of writing.
    public static func canSafelyModify(settingsData: Data?) -> Bool {
        guard let data = settingsData, !data.isEmpty else { return true }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [String: Any]
    }

    /// Recover the original wrapped command from one of VibeMenu's commands, or `nil` if it wraps
    /// nothing / isn't decodable.
    public static func wrappedOriginal(inCommand commandString: String) -> String? {
        guard let range = commandString.range(of: " --wrap ") else { return nil }
        let token = commandString[range.upperBound...]
            .split(whereSeparator: { $0 == " " })
            .first
            .map(String.init) ?? ""
        guard
            !token.isEmpty,
            let data = Data(base64Encoded: token),
            let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        return decoded
    }

    /// Whether a `statusLine.command` string is VibeMenu's shim.
    public static func isVibeMenuCommand(_ commandString: String) -> Bool {
        commandString.contains(marker)
    }

    // MARK: - Detect

    /// Inspect a settings file (its raw bytes, or `nil`/empty if absent) and report the install state.
    public static func detect(settingsData: Data?, shimPath: String) -> InstallState {
        let existing = existingStatusLineCommand(in: parseObject(settingsData))
        guard let existing else { return .notInstalled(existingCommand: nil) }
        if isVibeMenuCommand(existing) {
            return .installed(shimCommand: existing, wrappedOriginal: wrappedOriginal(inCommand: existing))
        }
        return .notInstalled(existingCommand: existing)
    }

    // MARK: - Compose (install / re-install)

    /// Compose VibeMenu's shim into the settings, wrapping any existing non-VibeMenu command and
    /// preserving every other key. Idempotent: re-composing over VibeMenu's own shim keeps the same
    /// wrapped original and just refreshes the shim path.
    public static func compose(settingsData: Data?, shimPath: String) -> ComposeResult {
        var object = parseObject(settingsData) ?? [:]
        let existing = existingStatusLineCommand(in: object)

        let wrapped: String?
        let alreadyInstalled: Bool
        if let existing, isVibeMenuCommand(existing) {
            // Re-install: keep whatever the shim already wraps (avoid double-wrapping our own command).
            wrapped = wrappedOriginal(inCommand: existing)
            alreadyInstalled = true
        } else {
            // Fresh install: wrap the user's command (if any) so their status line keeps working.
            wrapped = existing
            alreadyInstalled = false
        }

        let newCommand = command(shimPath: shimPath, wrapping: wrapped)
        // Preserve any other statusLine sub-keys (e.g. Claude Code's `padding`); only set type+command.
        var statusLine = (object["statusLine"] as? [String: Any]) ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = newCommand
        object["statusLine"] = statusLine

        return ComposeResult(
            updatedJSON: serialize(object),
            newCommand: newCommand,
            wrappedOriginal: wrapped,
            wasAlreadyInstalled: alreadyInstalled
        )
    }

    // MARK: - Uninstall

    /// Remove VibeMenu's shim, restoring the wrapped original command if there was one, or removing
    /// the `statusLine` key entirely if VibeMenu added it fresh. A non-VibeMenu statusLine is left
    /// untouched. Returns the settings JSON to write.
    public static func uninstall(settingsData: Data, shimPath: String) -> Data {
        var object = parseObject(settingsData) ?? [:]
        guard let existing = existingStatusLineCommand(in: object), isVibeMenuCommand(existing) else {
            return serialize(object)   // nothing of ours to remove
        }
        if let original = wrappedOriginal(inCommand: existing) {
            // Restore the wrapped command, keeping any other statusLine sub-keys the user had.
            var statusLine = (object["statusLine"] as? [String: Any]) ?? [:]
            statusLine["type"] = "command"
            statusLine["command"] = original
            object["statusLine"] = statusLine
        } else {
            object.removeValue(forKey: "statusLine")
        }
        return serialize(object)
    }

    // MARK: - Preview

    /// A concise, human-readable description of what a compose will change, for the confirmation UI.
    public static func preview(settingsData: Data?, shimPath: String) -> String {
        guard canSafelyModify(settingsData: settingsData) else {
            return "Your ~/.claude/settings.json isn't valid JSON, so VibeMenu won't modify it. Fix it "
                + "(or remove it) and try again — your other settings will be left untouched."
        }
        switch detect(settingsData: settingsData, shimPath: shimPath) {
        case .installed:
            return "VibeMenu usage capture is already installed in ~/.claude/settings.json. "
                + "Re-installing just refreshes the path; your status line is unchanged."
        case let .notInstalled(existingCommand):
            if let existingCommand, !existingCommand.isEmpty {
                return "VibeMenu will wrap your existing status line so it keeps working, and add "
                    + "usage capture.\n\nYour command (preserved):\n\(existingCommand)\n\n"
                    + "A timestamped backup of settings.json is saved first. Reversible from Settings."
            }
            return "VibeMenu will add a status line command to ~/.claude/settings.json that captures "
                + "your Claude usage limits locally. Your terminal status line will show a small "
                + "VibeMenu line.\n\nA timestamped backup of settings.json is saved first. "
                + "Reversible from Settings."
        }
    }

    // MARK: - Internals

    /// The `statusLine.command` string in a settings object, or `nil` when absent / wrong shape.
    private static func existingStatusLineCommand(in object: [String: Any]?) -> String? {
        guard
            let statusLine = object?["statusLine"] as? [String: Any],
            let command = statusLine["command"] as? String,
            !command.isEmpty
        else { return nil }
        return command
    }

    /// Parse settings bytes into a mutable object, or `nil` for missing/empty/invalid JSON (callers
    /// treat that as "start from an empty object").
    private static func parseObject(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Serialize a settings object deterministically (sorted keys, pretty-printed) so the write is
    /// reviewable, diff-stable, and reproducible in tests. Claude Code reads any valid JSON, so the
    /// reformat is harmless; a backup is written first by the app layer.
    private static func serialize(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
    }
}
