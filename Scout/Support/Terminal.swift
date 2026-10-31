import AppKit

/// Open in Terminal, using the app or command chosen in the config file (`terminal`, `terminalCommand`).
enum Terminal {
    struct Preset {
        let title: String
        let bundleID: String
        /// Shell commands run by /bin/sh with the SCOUT_* variables set, plus SCOUT_APP, the app’s path.
        let local: String
        /// nil when the app can’t be told to run a command, so it can’t open SSH folders.
        let remote: String?
    }

    static let presets: [String: Preset] = [
        "terminal": Preset(title: "Terminal", bundleID: "com.apple.Terminal",
                           local: #"open -a "$SCOUT_APP" "$SCOUT_DIR""#,
                           remote: appleScript(#"tell application id "com.apple.Terminal" to do script (item 1 of argv)"#,
                                               #"tell application id "com.apple.Terminal" to activate"#)),
        "iterm": Preset(title: "iTerm", bundleID: "com.googlecode.iterm2",
                        local: #"open -a "$SCOUT_APP" "$SCOUT_DIR""#,
                        remote: appleScript(#"tell application id "com.googlecode.iterm2""#, "activate",
                                            "tell current session of (create window with default profile) to write text (item 1 of argv)",
                                            "end tell")),
        "ghostty": Preset(title: "Ghostty", bundleID: "com.mitchellh.ghostty",
                          local: #"open -a "$SCOUT_APP" "$SCOUT_DIR""#,
                          remote: #"open -na "$SCOUT_APP" --args -e /bin/sh -c "$SCOUT_COMMAND""#),
        "warp": Preset(title: "Warp", bundleID: "dev.warp.Warp-Stable",
                       local: #"open -a "$SCOUT_APP" "$SCOUT_DIR""#,
                       remote: nil),
        "kitty": Preset(title: "kitty", bundleID: "net.kovidgoyal.kitty",
                        local: #"open -na "$SCOUT_APP" --args --single-instance --directory "$SCOUT_DIR""#,
                        remote: #"open -na "$SCOUT_APP" --args --single-instance /bin/sh -c "$SCOUT_COMMAND""#),
        "wezterm": Preset(title: "WezTerm", bundleID: "com.github.wez.wezterm",
                          local: #"open -na "$SCOUT_APP" --args start --cwd "$SCOUT_DIR""#,
                          remote: #"open -na "$SCOUT_APP" --args start -- /bin/sh -c "$SCOUT_COMMAND""#),
        "alacritty": Preset(title: "Alacritty", bundleID: "org.alacritty",
                            local: #"open -na "$SCOUT_APP" --args --working-directory "$SCOUT_DIR""#,
                            remote: #"open -na "$SCOUT_APP" --args -e /bin/sh -c "$SCOUT_COMMAND""#),
        "cmux": Preset(title: "cmux", bundleID: "com.cmuxterm.app",
                       local: #""$SCOUT_APP/Contents/Resources/bin/cmux" "$SCOUT_DIR""#,
                       remote: #""$SCOUT_APP/Contents/Resources/bin/cmux" new-workspace --name "$SCOUT_HOST" --command "$SCOUT_COMMAND" --focus true && open -a "$SCOUT_APP""#),
    ]

    /// An osascript call that gets $SCOUT_COMMAND as `item 1 of argv`.
    private static func appleScript(_ lines: String...) -> String {
        let args = (["on run argv"] + lines + ["end run"]).map { "-e \(shq($0))" }
        return "osascript \(args.joined(separator: " ")) \"$SCOUT_COMMAND\""
    }

    static func open(_ ref: ItemRef) {
        var env: [String: String] = [:]
        switch ref {
        case .local(let url):
            env["SCOUT_DIR"] = url.path
            env["SCOUT_HOST"] = ""
            env["SCOUT_PATH"] = url.path
            env["SCOUT_COMMAND"] = "cd \(shq(url.path)) && exec \"$SHELL\" -l"
        case .remote(let host, let path):
            let cd = path.isEmpty ? "" : "cd \(shq(path)) 2>/dev/null; "
            env["SCOUT_DIR"] = ""
            env["SCOUT_HOST"] = host
            env["SCOUT_PATH"] = path
            env["SCOUT_COMMAND"] = "ssh -t \(shq(host)) \(shq(cd + "exec \"$SHELL\" -l"))"
        }
        let isRemote = ref.isRemote
        let config = Config.shared

        if let command = config.string("terminalCommand") {
            run(loginShell, ["-l", "-c", command], env: env, title: "terminalCommand")
            return
        }

        let name = config.string("terminal") ?? "terminal"
        if let preset = presets[name.lowercased()] {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preset.bundleID) else {
                Config.alert("\(preset.title) isn’t installed.", "Change `terminal` in \(Config.displayPath), or install \(preset.title).")
                return
            }
            guard let command = isRemote ? preset.remote : preset.local else {
                Config.alert("\(preset.title) can’t open SSH folders.",
                             "Scout can’t ask \(preset.title) to run ssh. Use another terminal, or set `terminalCommand` in \(Config.displayPath).")
                return
            }
            env["SCOUT_APP"] = app.path
            run("/bin/sh", ["-c", command], env: env, title: preset.title)
        } else {
            guard !isRemote else {
                Config.alert("Scout doesn’t know how to open SSH folders in \(name).",
                             "Set `terminalCommand` in \(Config.displayPath) to say how.")
                return
            }
            env["SCOUT_APP"] = name
            run("/bin/sh", ["-c", #"open -a "$SCOUT_APP" "$SCOUT_DIR""#], env: env, title: name)
        }
    }

    /// The user’s shell, so `terminalCommand` sees the same PATH as in a terminal.
    private static var loginShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    private static func run(_ executable: String, _ arguments: [String], env: [String: String], title: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProcessRunner.runSync(executable, arguments, environment: env)
            guard !result.ok else { return }
            DispatchQueue.main.async {
                let output = [result.stderrString, result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                Config.alert("Couldn’t open the folder with \(title).",
                             (output.isEmpty ? "The command exited with status \(result.status)." : output)
                                + "\n\nYou can change how Open in Terminal works in \(Config.displayPath).")
            }
        }
    }
}
