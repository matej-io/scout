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

    private static let bootstrap = #"""
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

    private static let integration = #"""
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
        destination=$(printf '%s' "$encoded" | /usr/bin/base64 -D; printf '.')
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
