import Foundation
import Testing
@testable import VibeMenuCore

// Pure statusLine compose/uninstall tests (docs/decisions/0016-claude-usage-limits.md). These cover
// the one risky operation — editing ~/.claude/settings.json — entirely in pure logic against
// synthetic settings blobs, so the app adapter only has to do the (trivial) file I/O + backup.

private let shim = "/Applications/VibeMenu.app/Contents/Resources/vibemenu-usage-statusline.sh"

/// Parse a composed settings blob and return `statusLine.command` (or nil).
private func statusLineCommand(_ data: Data) -> String? {
    guard
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let statusLine = object["statusLine"] as? [String: Any]
    else { return nil }
    return statusLine["command"] as? String
}

/// Parse a composed settings blob into a dictionary for asserting preserved keys.
private func object(_ data: Data) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
}

private func settingsData(_ json: String) -> Data { Data(json.utf8) }

@Suite("StatusLineInstaller command encoding")
struct StatusLineCommandTests {
    @Test func bareCommandWhenNothingWrapped() {
        #expect(StatusLineInstaller.command(shimPath: shim, wrapping: nil) == "'\(shim)'")
        #expect(StatusLineInstaller.command(shimPath: shim, wrapping: "") == "'\(shim)'")
    }

    @Test func wrapsWithBase64AndRoundTrips() {
        let original = "my-statusline --flag 'quoted arg'"
        let command = StatusLineInstaller.command(shimPath: shim, wrapping: original)
        #expect(command.hasPrefix("'\(shim)' --wrap "))
        #expect(StatusLineInstaller.wrappedOriginal(inCommand: command) == original)
    }

    @Test func recognisesOurCommand() {
        let command = StatusLineInstaller.command(shimPath: shim, wrapping: nil)
        #expect(StatusLineInstaller.isVibeMenuCommand(command))
        #expect(!StatusLineInstaller.isVibeMenuCommand("some-other-statusline.sh"))
    }

    @Test func wrappedOriginalNilWhenNotWrapping() {
        #expect(StatusLineInstaller.wrappedOriginal(inCommand: "'\(shim)'") == nil)
    }
}

@Suite("StatusLineInstaller.detect")
struct StatusLineDetectTests {
    @Test func notInstalledWhenNoSettings() {
        #expect(StatusLineInstaller.detect(settingsData: nil, shimPath: shim) == .notInstalled(existingCommand: nil))
        #expect(StatusLineInstaller.detect(settingsData: Data(), shimPath: shim) == .notInstalled(existingCommand: nil))
    }

    @Test func notInstalledButReportsForeignCommand() {
        let data = settingsData(#"{"statusLine":{"type":"command","command":"powerline.sh"}}"#)
        #expect(StatusLineInstaller.detect(settingsData: data, shimPath: shim) == .notInstalled(existingCommand: "powerline.sh"))
    }

    @Test func installedWhenOurShimPresent() {
        let command = StatusLineInstaller.command(shimPath: shim, wrapping: "powerline.sh")
        let data = settingsData(#"{"statusLine":{"type":"command","command":"\#(command)"}}"#)
        #expect(
            StatusLineInstaller.detect(settingsData: data, shimPath: shim)
                == .installed(shimCommand: command, wrappedOriginal: "powerline.sh")
        )
    }
}

@Suite("StatusLineInstaller.compose")
struct StatusLineComposeTests {
    @Test func freshInstallWhenNoSettings() {
        let result = StatusLineInstaller.compose(settingsData: nil, shimPath: shim)
        #expect(result.wasAlreadyInstalled == false)
        #expect(result.wrappedOriginal == nil)
        #expect(statusLineCommand(result.updatedJSON) == "'\(shim)'")
    }

    @Test func wrapsExistingCommandAndPreservesOtherKeys() {
        let data = settingsData(#"""
        {"model":"opus","hooks":{"Stop":[{"x":1}]},"statusLine":{"type":"command","command":"powerline.sh --theme dark"}}
        """#)
        let result = StatusLineInstaller.compose(settingsData: data, shimPath: shim)
        #expect(result.wasAlreadyInstalled == false)
        #expect(result.wrappedOriginal == "powerline.sh --theme dark")
        // Our shim is now the command, wrapping the original (recoverable).
        let command = statusLineCommand(result.updatedJSON)!
        #expect(StatusLineInstaller.isVibeMenuCommand(command))
        #expect(StatusLineInstaller.wrappedOriginal(inCommand: command) == "powerline.sh --theme dark")
        // Unrelated keys are preserved verbatim.
        let obj = object(result.updatedJSON)
        #expect(obj["model"] as? String == "opus")
        #expect(obj["hooks"] != nil)
    }

    @Test func reinstallIsIdempotentAndDoesNotDoubleWrap() {
        // Start from an already-installed state that wraps "powerline.sh".
        let first = StatusLineInstaller.compose(
            settingsData: settingsData(#"{"statusLine":{"type":"command","command":"powerline.sh"}}"#),
            shimPath: shim
        )
        // Re-compose over our own command.
        let second = StatusLineInstaller.compose(settingsData: first.updatedJSON, shimPath: shim)
        #expect(second.wasAlreadyInstalled == true)
        #expect(second.wrappedOriginal == "powerline.sh")   // preserved, not our own command
        let command = statusLineCommand(second.updatedJSON)!
        #expect(StatusLineInstaller.wrappedOriginal(inCommand: command) == "powerline.sh")
    }
}

@Suite("StatusLineInstaller.uninstall")
struct StatusLineUninstallTests {
    @Test func restoresWrappedOriginal() {
        let installed = StatusLineInstaller.compose(
            settingsData: settingsData(#"{"statusLine":{"type":"command","command":"powerline.sh"}}"#),
            shimPath: shim
        )
        let removed = StatusLineInstaller.uninstall(settingsData: installed.updatedJSON, shimPath: shim)
        #expect(statusLineCommand(removed) == "powerline.sh")
    }

    @Test func removesStatusLineWhenNothingWasWrapped() {
        let installed = StatusLineInstaller.compose(settingsData: nil, shimPath: shim)
        let removed = StatusLineInstaller.uninstall(settingsData: installed.updatedJSON, shimPath: shim)
        #expect(object(removed)["statusLine"] == nil)
    }

    @Test func leavesForeignStatusLineUntouched() {
        let data = settingsData(#"{"statusLine":{"type":"command","command":"powerline.sh"}}"#)
        let removed = StatusLineInstaller.uninstall(settingsData: data, shimPath: shim)
        #expect(statusLineCommand(removed) == "powerline.sh")
    }

    @Test func preservesOtherKeysOnUninstall() {
        let installed = StatusLineInstaller.compose(
            settingsData: settingsData(#"{"model":"opus","statusLine":{"type":"command","command":"powerline.sh"}}"#),
            shimPath: shim
        )
        let removed = StatusLineInstaller.uninstall(settingsData: installed.updatedJSON, shimPath: shim)
        #expect(object(removed)["model"] as? String == "opus")
    }
}

@Suite("StatusLineInstaller.preview")
struct StatusLinePreviewTests {
    @Test func previewMentionsWrappingWhenExistingCommand() {
        let data = settingsData(#"{"statusLine":{"type":"command","command":"powerline.sh"}}"#)
        let preview = StatusLineInstaller.preview(settingsData: data, shimPath: shim)
        #expect(preview.contains("wrap"))
        #expect(preview.contains("powerline.sh"))
    }

    @Test func previewMentionsFreshAddWhenNone() {
        let preview = StatusLineInstaller.preview(settingsData: nil, shimPath: shim)
        #expect(preview.contains("add"))
        #expect(preview.contains("backup"))
    }

    @Test func previewMentionsAlreadyInstalled() {
        let installed = StatusLineInstaller.compose(settingsData: nil, shimPath: shim)
        let preview = StatusLineInstaller.preview(settingsData: installed.updatedJSON, shimPath: shim)
        #expect(preview.contains("already installed"))
    }
}

// Regression tests for the adversarial-review findings (config-safety of the settings.json edit).
@Suite("StatusLineInstaller safety")
struct StatusLineSafetyTests {
    @Test func canSafelyModifyGuardsUnparseableSettings() {
        // Absent / empty / valid object → safe to edit (we create or merge).
        #expect(StatusLineInstaller.canSafelyModify(settingsData: nil))
        #expect(StatusLineInstaller.canSafelyModify(settingsData: Data()))
        #expect(StatusLineInstaller.canSafelyModify(settingsData: settingsData(#"{"model":"opus"}"#)))
        // Present but NOT a JSON object → refuse (composing would drop every other key).
        #expect(!StatusLineInstaller.canSafelyModify(settingsData: settingsData("{ truncated")))       // syntax error
        #expect(!StatusLineInstaller.canSafelyModify(settingsData: settingsData(#"{"a": 1 "b": 2}"#)))  // missing comma
        #expect(!StatusLineInstaller.canSafelyModify(settingsData: settingsData("[1,2,3]")))            // array
        #expect(!StatusLineInstaller.canSafelyModify(settingsData: settingsData("42")))                 // scalar
        #expect(!StatusLineInstaller.canSafelyModify(settingsData: settingsData("not json")))
    }

    @Test func composePreservesOtherStatusLineSubKeys() {
        // e.g. Claude Code's `statusLine.padding` must survive an install.
        let data = settingsData(#"{"statusLine":{"type":"command","command":"powerline.sh","padding":0}}"#)
        let result = StatusLineInstaller.compose(settingsData: data, shimPath: shim)
        let statusLine = object(result.updatedJSON)["statusLine"] as? [String: Any]
        #expect(statusLine?["padding"] as? Int == 0)
        #expect(StatusLineInstaller.isVibeMenuCommand(statusLine?["command"] as? String ?? ""))
    }

    @Test func uninstallPreservesOtherStatusLineSubKeys() {
        let installed = StatusLineInstaller.compose(
            settingsData: settingsData(#"{"statusLine":{"type":"command","command":"powerline.sh","padding":0}}"#),
            shimPath: shim
        )
        let removed = StatusLineInstaller.uninstall(settingsData: installed.updatedJSON, shimPath: shim)
        let statusLine = object(removed)["statusLine"] as? [String: Any]
        #expect(statusLine?["padding"] as? Int == 0)
        #expect(statusLine?["command"] as? String == "powerline.sh")
    }

    @Test func commandEscapesSingleQuotesInPath() {
        // A username / home dir containing an apostrophe must not break the shell quoting.
        let weird = "/Users/o'brien/VibeMenu/shim.sh"
        #expect(StatusLineInstaller.command(shimPath: weird, wrapping: nil) == "'/Users/o'\\''brien/VibeMenu/shim.sh'")
        // And a normal path is unchanged (no stray escaping).
        #expect(StatusLineInstaller.command(shimPath: shim, wrapping: nil) == "'\(shim)'")
    }

    @Test func previewWarnsOnUnparseableSettings() {
        let preview = StatusLineInstaller.preview(settingsData: settingsData("{ oops,, }"), shimPath: shim)
        #expect(preview.contains("isn't valid JSON"))
    }
}
