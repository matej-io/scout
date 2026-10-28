import Foundation

/// Quotes a string for a POSIX shell.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct ScoutError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var ok: Bool { status == 0 }
    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ProcessRunner {
    /// Runs a process to completion. Call from a background queue.
    static func runSync(_ executable: String,
                        _ arguments: [String],
                        environment: [String: String]? = nil,
                        input: Any? = nil,
                        output: Any? = nil,
                        started: ((Process) -> Void)? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        process.standardInput = input ?? FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = output ?? outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
        }
        started?(process)

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        if output == nil {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return ProcessResult(status: process.terminationStatus, stdout: outData, stderr: errData)
    }

    static func run(_ executable: String,
                    _ arguments: [String],
                    completion: @escaping (ProcessResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSync(executable, arguments)
            DispatchQueue.main.async { completion(result) }
        }
    }
}
