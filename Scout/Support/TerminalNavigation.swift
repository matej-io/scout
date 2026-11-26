import Foundation
import Darwin

/// A private channel serviced by zsh's line editor, never by a foreground job.
/// Requests are bound to a prompt generation and rejected if there is typed input.
final class TerminalNavigation {
    let directory: URL
    var environment: [String: String] {
        ["ZDOTDIR": directory.path,
         "SCOUT_NAV_DIRECTORY": directory.path,
         "SCOUT_USER_ZDOTDIR": ProcessInfo.processInfo.environment["ZDOTDIR"] ?? ""]
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("scout-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        do {
            guard mkfifo(directory.appendingPathComponent("requests").path, 0o600) == 0 else {
                throw POSIXError(.EIO)
            }
            try Self.bootstrap.write(to: directory.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            try Self.integration.write(to: directory.appendingPathComponent("integration.zsh"), atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func navigate(to url: URL) {
        guard let token = try? String(contentsOf: directory.appendingPathComponent("ready"), encoding: .utf8),
              !token.isEmpty, token.allSatisfy({ $0.isNumber || $0 == "\n" }) else { return }
        let request = token.trimmingCharacters(in: .newlines) + "\t" + Data(url.path.utf8).base64EncodedString() + "\n"
        let bytes = Array(request.utf8)
        let fd = open(directory.appendingPathComponent("requests").path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // A single atomic pipe write; longer paths are conservatively left unchanged.
        guard bytes.count <= fpathconf(fd, _PC_PIPE_BUF) else { return }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    fileprivate static let bootstrap = #"""
    typeset -g _scout_nav_directory="$SCOUT_NAV_DIRECTORY"
    if [[ -n "$SCOUT_USER_ZDOTDIR" ]]; then
        ZDOTDIR="$SCOUT_USER_ZDOTDIR"
    else
        unset ZDOTDIR
    fi
    unset SCOUT_NAV_DIRECTORY SCOUT_USER_ZDOTDIR
    [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source -- "${ZDOTDIR:-$HOME}/.zshenv"
    if [[ -o interactive ]]; then
        _scout_nav_init() {
            precmd_functions=(${precmd_functions:#_scout_nav_init})
            builtin source -- "$_scout_nav_directory/integration.zsh"
            unfunction _scout_nav_init
        }
        typeset -ga precmd_functions
        precmd_functions+=(_scout_nav_init)
    fi
    """#

    fileprivate static let integration = #"""
    zmodload zsh/system || return
    autoload -Uz add-zle-hook-widget add-zsh-hook
    typeset -gi _scout_nav_fd _scout_nav_generation=0
    sysopen -rw -o nonblock,cloexec -u _scout_nav_fd "$_scout_nav_directory/requests" || return
    _scout_nav_pwd() {
        # OSC 7 is informational; the navigation request itself never uses terminal input.
        printf '\e]7;file://%s%s\a' "$HOST" "$PWD"
    }
    _scout_nav_receive() {
        emulate -L zsh
        local line generation encoded destination
        IFS= read -r -u $_scout_nav_fd line || return
        generation=${line%%$'\t'*}
        encoded=${line#*$'\t'}
        [[ "$generation" == "$_scout_nav_generation" && -z "$BUFFER" ]] || return
        destination=$(printf '%s' "$encoded" | command base64 -d && printf '.') || return
        destination=${destination%.}
        [[ "$destination" == /* ]] || return
        builtin cd -- "$destination" || return
        _scout_nav_pwd
        zle reset-prompt
    }
    _scout_nav_begin() {
        (( ++_scout_nav_generation ))
        zle -F $_scout_nav_fd _scout_nav_receive
        print -r -- "$_scout_nav_generation" >| "$_scout_nav_directory/ready"
    }
    _scout_nav_end() {
        zle -F $_scout_nav_fd
        command rm -f -- "$_scout_nav_directory/ready"
    }
    add-zle-hook-widget line-init _scout_nav_begin
    add-zle-hook-widget line-finish _scout_nav_end
    add-zsh-hook precmd _scout_nav_pwd
    _scout_nav_pwd
    """#
}

/// The remote shell owns its FIFO. A separate SSH channel sends requests without writing to the PTY.
final class RemoteTerminalNavigation {
    private let host: SSHHost
    private let directory = "/tmp/scout-shell-\(UUID().uuidString)"
    private let requests = DispatchQueue(label: "Scout.remoteTerminalNavigation")

    init(host: SSHHost) {
        self.host = host
    }

    func launchCommand(path: String) -> String {
        let changeDirectory = path.isEmpty ? "" : "cd \(shq(path)) || exit\n"
        let script = changeDirectory + """
        if [ "${SHELL##*/}" = zsh ]; then
            directory=\(shq(directory))
            if (umask 077; mkdir -- "$directory"); then
                trap 'rm -rf -- "$directory"' EXIT
                trap 'exit 129' HUP
                trap 'exit 143' TERM
                if (umask 077
                    mkfifo "$directory/requests" &&
                    printf '%s\\n' \(shq(TerminalNavigation.bootstrap)) > "$directory/.zshenv" &&
                    printf '%s\\n' \(shq(TerminalNavigation.integration)) > "$directory/integration.zsh"
                ); then
                    SCOUT_NAV_DIRECTORY="$directory" SCOUT_USER_ZDOTDIR="${ZDOTDIR-}" ZDOTDIR="$directory" "$SHELL" -l
                    exit $?
                fi
            fi
        fi
        exec "$SHELL" -l
        """
        let command = "sh -c " + shq(script)
        let arguments = host.sshArguments(["--", host.destination, command], tty: true)
        return (["/usr/bin/ssh"] + arguments).map(shq).joined(separator: " ")
    }

    func navigate(to path: String) {
        guard path.hasPrefix("/") else { return }
        let encoded = Data(path.utf8).base64EncodedString()
        let script = #"""
        directory=$1
        IFS= read -r generation < "$directory/ready" || exit
        zmodload zsh/system || exit
        typeset -i fd
        fifo=$directory/requests
        request="$generation"$'\t'"$2"$'\n'
        limit=$(command getconf PIPE_BUF "$fifo") || exit
        (( ${#request} <= limit )) || exit
        sysopen -w -o nonblock,cloexec -u fd "$fifo" || exit
        syswrite -o $fd "$request"
        """#
        let command = "zsh -fc \(shq(script)) -- \(shq(directory)) \(shq(encoded))"
        let arguments = host.sshArguments(["-o", "BatchMode=yes", "--", host.destination, command])
        requests.async {
            _ = ProcessRunner.runSync("/usr/bin/ssh", arguments)
        }
    }
}
