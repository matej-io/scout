import AppKit
import UniformTypeIdentifiers

/// One SSH destination (an alias from ~/.ssh/config or a user@host string).
/// All traffic goes through the system `ssh` binary so ~/.ssh/config, keys,
/// the agent, ProxyJump and known_hosts all work exactly like in Terminal.
final class SSHHost {
    enum State: Equatable {
        case idle, connecting, connected, failed(String)
    }

    static let stateChanged = Notification.Name("ScoutSSHHostStateChanged")

    let destination: String
    let entry: SSHHostEntry?
    private(set) var state: State = .idle {
        didSet { NotificationCenter.default.post(name: SSHHost.stateChanged, object: self) }
    }
    private(set) var home = "/"
    private var waiters: [(Result<Void, Error>) -> Void] = []

    init(destination: String, entry: SSHHostEntry?) {
        self.destination = destination
        self.entry = entry
    }

    var displayName: String {
        if destination.hasPrefix("ssh://"), let url = URL(string: destination), let host = url.host {
            return host
        }
        return destination
    }

    var rootRef: ItemRef { .remote(host: destination, path: home) }

    var isConnected: Bool { state == .connected }

    // MARK: Arguments

    private var controlPath: String { "/tmp/scout-ssh-\(getuid())-%C" }

    func sshArguments(_ extra: [String] = []) -> [String] {
        ["-o", "ControlMaster=auto",
         "-o", "ControlPath=\(controlPath)",
         "-o", "ControlPersist=600",
         "-o", "ConnectTimeout=20",
         "-o", "ServerAliveInterval=30",
         "-T", "-x"] + extra
    }

    static var environment: [String: String] {
        var env = ["SSH_ASKPASS": AskPass.scriptPath, "SSH_ASKPASS_REQUIRE": "force"]
        if ProcessInfo.processInfo.environment["DISPLAY"] == nil { env["DISPLAY"] = ":0" }
        return env
    }

    // MARK: Connection

    func connect(_ completion: @escaping (Result<Void, Error>) -> Void) {
        if state == .connected { completion(.success(())); return }
        waiters.append(completion)
        guard state != .connecting else { return }
        state = .connecting
        let args = sshArguments([destination, "printf '%s' \"$HOME\""])
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProcessRunner.runSync("/usr/bin/ssh", args, environment: SSHHost.environment)
            DispatchQueue.main.async {
                let waiters = self.waiters
                self.waiters = []
                if result.ok {
                    let home = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.home = home.hasPrefix("/") ? home : "/"
                    self.state = .connected
                    waiters.forEach { $0(.success(())) }
                } else {
                    let message = SSHHost.cleanError(result.stderrString, fallback: "Could not connect to “\(self.displayName)”.")
                    self.state = .failed(message)
                    waiters.forEach { $0(.failure(ScoutError(message))) }
                }
            }
        }
    }

    func disconnect() {
        let args = sshArguments(["-O", "exit", destination])
        state = .idle
        DispatchQueue.global().async {
            _ = ProcessRunner.runSync("/usr/bin/ssh", args, environment: SSHHost.environment)
        }
    }

    static func cleanError(_ stderr: String, fallback: String) -> String {
        let lines = stderr.components(separatedBy: .newlines).filter {
            !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added")
        }
        return lines.isEmpty ? fallback : lines.joined(separator: "\n")
    }

    // MARK: Commands

    /// Runs a shell command on the host. Call from a background queue.
    func runSync(_ command: String, input: Any? = nil, output: Any? = nil, started: ((Process) -> Void)? = nil) -> ProcessResult {
        ProcessRunner.runSync("/usr/bin/ssh", sshArguments([destination, command]),
                              environment: SSHHost.environment, input: input, output: output, started: started)
    }

    func run(_ command: String, completion: @escaping (Result<Data, Error>) -> Void) {
        connect { result in
            if case .failure(let error) = result { completion(.failure(error)); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runSync(command)
                DispatchQueue.main.async {
                    if result.ok {
                        completion(.success(result.stdout))
                    } else {
                        completion(.failure(ScoutError(SSHHost.cleanError(result.stderrString, fallback: "The command failed on “\(self.displayName)”."))))
                    }
                }
            }
        }
    }

    // MARK: Listing

    private static func listCommand(_ path: String) -> String {
        """
        cd -- \(shq(path)) || exit 3
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
          find . -mindepth 1 -maxdepth 1 -printf '%y\\t%Y\\t%s\\t%T@\\t%f\\0'
        else
          for f in .* *; do
            case "$f" in .|..) continue;; esac
            [ -e "$f" ] || [ -L "$f" ] || continue
            if [ -L "$f" ]; then y=l; elif [ -d "$f" ]; then y=d; else y=f; fi
            if [ -d "$f" ]; then Y=d; else Y=f; fi
            printf '%s\\t%s\\t%s\\t%s\\t%s\\0' "$y" "$Y" "$(stat -f %z "$f")" "$(stat -f %m "$f")" "$f"
          done
        fi
        """
    }

    func list(_ path: String, command: String? = nil, completion: @escaping (Result<[FileItem], Error>) -> Void) {
        run(command ?? SSHHost.listCommand(path)) { result in
            completion(result.map { self.parseListing($0, directory: path) })
        }
    }

    func listSync(_ path: String) -> Result<[FileItem], Error> {
        let result = runSync(SSHHost.listCommand(path))
        guard result.ok else { return .failure(ScoutError(SSHHost.cleanError(result.stderrString, fallback: "Could not list “\(path)”."))) }
        return .success(parseListing(result.stdout, directory: path))
    }

    private func parseListing(_ data: Data, directory: String) -> [FileItem] {
        var items: [FileItem] = []
        for record in data.split(separator: 0) {
            let fields = record.split(separator: UInt8(ascii: "\t"), maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5 else { continue }
            let type = String(decoding: fields[0], as: UTF8.self)
            let target = String(decoding: fields[1], as: UTF8.self)
            let size = Int64(String(decoding: fields[2], as: UTF8.self))
            let mtime = Double(String(decoding: fields[3], as: UTF8.self))
            var name = String(decoding: fields[4], as: UTF8.self)
            let fullPath = name.hasPrefix("/") ? name : (directory as NSString).appendingPathComponent(name)
            if name.hasPrefix("/") { name = (name as NSString).lastPathComponent }
            let isDir = type == "d" || (type == "l" && target == "d")
            let ext = (name as NSString).pathExtension
            let kind: String
            if isDir {
                kind = "Folder"
            } else if let utType = ext.isEmpty ? nil : UTType(filenameExtension: ext), let desc = utType.localizedDescription {
                kind = desc.prefix(1).uppercased() + desc.dropFirst()
            } else {
                kind = "Document"
            }
            items.append(FileItem(ref: .remote(host: destination, path: fullPath),
                                  name: name,
                                  isDirectory: isDir,
                                  isHidden: name.hasPrefix("."),
                                  isSymlink: type == "l",
                                  size: isDir ? nil : size,
                                  modified: mtime.map { Date(timeIntervalSince1970: $0) },
                                  kind: kind))
        }
        return items
    }

    /// Free space of the filesystem containing `path`, in bytes.
    func availableSpace(_ path: String, completion: @escaping (Int64?) -> Void) {
        run("df -Pk -- \(shq(path)) | tail -1") { result in
            guard case .success(let data) = result else { completion(nil); return }
            let parts = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 4, let kb = Int64(parts[3]) { completion(kb * 1024) } else { completion(nil) }
        }
    }
}

// MARK: - Manager

final class SSHManager {
    static let shared = SSHManager()
    static let hostsChanged = Notification.Name("ScoutSSHHostsChanged")

    private(set) var hosts: [SSHHost] = []
    private var byDestination: [String: SSHHost] = [:]

    private init() {
        reload()
    }

    func reload() {
        let entries = SSHConfig.load()
        var list: [SSHHost] = []
        let hidden = Set(Prefs.shared.hiddenHosts)
        for entry in entries where !hidden.contains(entry.alias) {
            list.append(existing(entry.alias) ?? SSHHost(destination: entry.alias, entry: entry))
        }
        for destination in Prefs.shared.customHosts where !hidden.contains(destination) && !list.contains(where: { $0.destination == destination }) {
            list.append(existing(destination) ?? SSHHost(destination: destination, entry: nil))
        }
        // Keep connected hosts around even if they were removed from the list.
        for host in hosts where host.isConnected && !list.contains(where: { $0 === host }) {
            list.append(host)
        }
        hosts = list
        for host in list { byDestination[host.destination] = host }
        NotificationCenter.default.post(name: SSHManager.hostsChanged, object: nil)
    }

    private func existing(_ destination: String) -> SSHHost? { byDestination[destination] }

    func host(_ destination: String) -> SSHHost {
        if let host = byDestination[destination] { return host }
        let host = SSHHost(destination: destination, entry: nil)
        byDestination[destination] = host
        return host
    }

    func addCustomHost(_ destination: String) {
        var hidden = Prefs.shared.hiddenHosts
        hidden.removeAll { $0 == destination }
        Prefs.shared.hiddenHosts = hidden
        if !hosts.contains(where: { $0.destination == destination }) {
            Prefs.shared.customHosts.append(destination)
        }
        reload()
    }

    func removeFromSidebar(_ destination: String) {
        if Prefs.shared.customHosts.contains(destination) {
            Prefs.shared.customHosts.removeAll { $0 == destination }
        } else {
            Prefs.shared.hiddenHosts.append(destination)
        }
        byDestination[destination]?.disconnect()
        reload()
    }

    func disconnectAll() {
        for host in byDestination.values where host.isConnected { host.disconnect() }
    }
}

// MARK: - Askpass helper

/// A tiny SSH_ASKPASS script so passphrases, passwords and host key
/// confirmations show up as native dialogs instead of failing silently.
enum AskPass {
    static var scriptPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scout", isDirectory: true)
        return dir.appendingPathComponent("askpass.sh").path
    }

    static func install() {
        let script = """
        #!/bin/sh
        prompt="$1"
        case "$prompt" in
          *"(yes/no"*)
            /usr/bin/osascript -e 'on run argv' -e 'activate' -e 'display dialog (item 1 of argv) buttons {"Cancel", "Connect"} default button "Connect" cancel button "Cancel" with title "Scout" with icon caution' -e 'return "yes"' -e 'end run' -- "$prompt" || exit 1
            ;;
          *)
            /usr/bin/osascript -e 'on run argv' -e 'activate' -e 'text returned of (display dialog (item 1 of argv) default answer "" with hidden answer with title "Scout" with icon note)' -e 'end run' -- "$prompt" || exit 1
            ;;
        esac
        """
        let url = URL(fileURLWithPath: scriptPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
