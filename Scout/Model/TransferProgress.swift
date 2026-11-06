import Foundation

/// How far a copy or move has got. The transfer updates it from its background queue;
/// the progress window reads it on the main thread.
final class TransferProgress {
    let title: String
    let move: Bool
    let started = Date()

    private let lock = NSLock()
    private var _total: Int64?
    private var _completed: Int64 = 0
    private var _cancelled = false
    private var _finished = false
    private var cancelHandler: (() -> Void)?

    init(title: String, move: Bool) {
        self.title = title
        self.move = move
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Bytes to transfer in all, or nil while they're being counted (or when they can't be).
    var total: Int64? {
        get { locked { _total } }
        set { locked { _total = newValue } }
    }

    var completed: Int64 { locked { _completed } }
    var isCancelled: Bool { locked { _cancelled } }
    var isFinished: Bool { locked { _finished } }

    func add(_ bytes: Int64) {
        guard bytes > 0 else { return }
        locked { _completed += bytes }
    }

    func finish() { locked { _finished = true } }

    /// Stops the transfer: the running step is interrupted and no further items start.
    func cancel() {
        let handler: (() -> Void)? = locked {
            guard !_cancelled else { return nil }
            _cancelled = true
            return cancelHandler
        }
        handler?()
    }

    /// What interrupts the step that's running now (for example, terminating its processes).
    /// Runs straight away if the transfer was already cancelled.
    func setCancelHandler(_ handler: (() -> Void)?) {
        let runNow: Bool = locked {
            cancelHandler = handler
            return _cancelled
        }
        if runNow { handler?() }
    }
}
