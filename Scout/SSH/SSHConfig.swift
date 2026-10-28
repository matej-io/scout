import Foundation

struct SSHHostEntry: Hashable {
    let alias: String
    var hostName: String?
    var user: String?
    var port: String?
    var proxyJump: String?

    var subtitle: String {
        var s = ""
        if let user { s += user + "@" }
        s += hostName ?? alias
        if let port, port != "22" { s += ":" + port }
        return s
    }
}

/// Reads host aliases out of ~/.ssh/config (following Include directives).
enum SSHConfig {
    static var sshDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    static func load() -> [SSHHostEntry] {
        var entries: [SSHHostEntry] = []
        var seen = Set<String>()
        parse(url: sshDirectory.appendingPathComponent("config"), depth: 0, into: &entries, seen: &seen)
        return entries
    }

    /// Private keys found in ~/.ssh (files that have a matching .pub).
    static func privateKeys() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sshDirectory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { url in
            url.pathExtension != "pub" && fm.fileExists(atPath: url.path + ".pub")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func parse(url: URL, depth: Int, into entries: inout [SSHHostEntry], seen: inout Set<String>) {
        guard depth < 8, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var current: [Int] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (keyword, args) = split(line)
            switch keyword {
            case "include":
                for pattern in args {
                    var expanded = (pattern as NSString).expandingTildeInPath
                    if !expanded.hasPrefix("/") {
                        expanded = sshDirectory.appendingPathComponent(expanded).path
                    }
                    for path in glob(expanded) {
                        parse(url: URL(fileURLWithPath: path), depth: depth + 1, into: &entries, seen: &seen)
                    }
                }
            case "host":
                current = []
                for pattern in args where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                    if seen.insert(pattern).inserted {
                        entries.append(SSHHostEntry(alias: pattern))
                        current.append(entries.count - 1)
                    } else if let index = entries.firstIndex(where: { $0.alias == pattern }) {
                        current.append(index)
                    }
                }
            case "match":
                current = []
            case "hostname":
                for i in current where entries[i].hostName == nil { entries[i].hostName = args.first }
            case "user":
                for i in current where entries[i].user == nil { entries[i].user = args.first }
            case "port":
                for i in current where entries[i].port == nil { entries[i].port = args.first }
            case "proxyjump":
                for i in current where entries[i].proxyJump == nil { entries[i].proxyJump = args.first }
            default:
                break
            }
        }
    }

    private static func split(_ line: String) -> (String, [String]) {
        var keyword = ""
        var rest = Substring(line)
        if let index = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) {
            keyword = String(line[..<index])
            rest = line[index...]
        } else {
            keyword = line
            rest = ""
        }
        let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" || $0 == "=" })
        var args: [String] = []
        var token = ""
        var inQuotes = false
        for ch in trimmed {
            if ch == "\"" { inQuotes.toggle(); continue }
            if (ch == " " || ch == "\t") && !inQuotes {
                if !token.isEmpty { args.append(token); token = "" }
            } else {
                token.append(ch)
            }
        }
        if !token.isEmpty { args.append(token) }
        return (keyword.lowercased(), args)
    }

    private static func glob(_ pattern: String) -> [String] {
        var gt = glob_t()
        defer { globfree(&gt) }
        guard Darwin.glob(pattern, 0, nil, &gt) == 0 else { return [] }
        return (0..<Int(gt.gl_matchc)).compactMap { gt.gl_pathv[$0].flatMap { String(cString: $0) } }
    }
}
