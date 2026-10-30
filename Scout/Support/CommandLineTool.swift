import AppKit

/// The `scout` shell command, like VS Code’s `code`: a script inside the app, linked from /usr/local/bin.
enum CommandLineTool {
    static let linkPath = "/usr/local/bin/scout"

    static var scriptPath: String? { Bundle.main.path(forResource: "scout", ofType: nil) }

    /// Whether /usr/local/bin/scout is a link to this copy of Scout’s script.
    static var isInstalled: Bool {
        guard let scriptPath, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else { return false }
        return target == scriptPath
    }

    static func toggle() {
        isInstalled ? uninstall() : install()
    }

    static func install() {
        guard let scriptPath else { return alert("Scout’s copy of the command is missing.", "Reinstall Scout and try again.") }
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            return alert("Move Scout to Applications first.",
                         "macOS is running Scout from a temporary location, so the command would stop working. Quit Scout, move it to Applications and open it from there.")
        }
        // Something other than a link to a Scout.app is in the way: ask before replacing it.
        let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        if FileManager.default.fileExists(atPath: linkPath) || existing != nil,
           existing?.hasSuffix(".app/Contents/Resources/scout") != true {
            let confirm = NSAlert()
            confirm.messageText = "Replace the existing “scout” command?"
            confirm.informativeText = "There’s already a file at \(linkPath)."
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }
        let command = "mkdir -p /usr/local/bin && ln -sfn \(shq(scriptPath)) \(shq(linkPath))"
        guard run(command) else { return }
        alert("The “scout” command is installed.",
              "In a terminal, type scout . to show the current folder in Scout, or scout followed by any path. If you move Scout, install the command again.",
              style: .informational)
    }

    static func uninstall() {
        guard run("rm -f \(shq(linkPath))") else { return }
        alert("The “scout” command was removed.", "", style: .informational)
    }

    /// Runs a shell command, asking for an administrator password if /usr/local/bin isn’t writable.
    private static func run(_ command: String) -> Bool {
        let plain = ProcessRunner.runSync("/bin/sh", ["-c", command])
        if plain.ok { return true }
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard let error else { return true }
        // -128: the user cancelled the password prompt.
        if error[NSAppleScript.errorNumber] as? Int != -128 {
            alert("The “scout” command couldn’t be changed.", error[NSAppleScript.errorMessage] as? String ?? plain.stderrString)
        }
        return false
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func alert(_ message: String, _ info: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
