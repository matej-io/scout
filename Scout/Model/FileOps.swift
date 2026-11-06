import AppKit

/// File operations that work the same on this Mac and over SSH.
enum FileOps {
    enum ConflictPolicy { case keepBoth, replace, skip }

    private static let queue = DispatchQueue(label: "scout.fileops", qos: .userInitiated)

    // MARK: New folder

    static func newFolder(in folder: ItemRef, completion: @escaping (Result<ItemRef, Error>) -> Void) {
        queue.async {
            let name = FileService.uniqueName("untitled folder", existing: FileService.existingNames(in: folder), isDirectory: true)
            let target = folder.appending(name)
            let result: Result<ItemRef, Error>
            switch target {
            case .local(let url):
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    result = .success(settled(target))
                } catch { result = .failure(error) }
            case .remote(let host, let path):
                result = remote(host, "mkdir -- \(shq(path))").map { target }
            }
            finish(result, changed: [folder], completion: completion)
        }
    }

    // MARK: Rename

    static func rename(_ item: ItemRef, to newName: String, completion: @escaping (Result<ItemRef, Error>) -> Void) {
        guard let parent = item.parent else { return }
        let target = parent.appending(newName)
        queue.async {
            let result: Result<ItemRef, Error>
            switch (item, target) {
            case (.local(let from), .local(let to)):
                do {
                    if FileManager.default.fileExists(atPath: to.path) && from.path.lowercased() != to.path.lowercased() {
                        throw ScoutError("The name “\(newName)” is already taken. Please choose a different name.")
                    }
                    try FileManager.default.moveItem(at: from, to: to)
                    result = .success(settled(target))
                } catch { result = .failure(error) }
            case (.remote(let host, let from), .remote(_, let to)):
                let cmd = "if [ -e \(shq(to)) ]; then echo 'The name “\(newName.replacingOccurrences(of: "'", with: ""))” is already taken. Please choose a different name.' >&2; exit 17; fi; mv -- \(shq(from)) \(shq(to))"
                result = remote(host, cmd).map { target }
            default:
                result = .failure(ScoutError("Can’t rename this item."))
            }
            finish(result, changed: [parent], completion: completion)
        }
    }

    // MARK: Delete

    /// Moves local items to the Bin. Returns the new locations for undo.
    static func trash(_ urls: [URL], completion: @escaping ([URL: URL], Error?) -> Void) {
        NSWorkspace.shared.recycle(urls) { trashed, error in
            FileService.notifyChanged(urls.map { .local($0.deletingLastPathComponent()) })
            completion(trashed, error)
        }
    }

    static func deleteRemote(_ refs: [ItemRef], completion: @escaping (Error?) -> Void) {
        guard let host = refs.first?.remoteHost else { return }
        let paths = refs.map { shq($0.path) }.joined(separator: " ")
        let activity = Activity.shared.begin("Deleting \(refs.count == 1 ? "“\(refs[0].name)”" : "\(refs.count) items")…")
        queue.async {
            let result = remote(host, "rm -rf -- \(paths)")
            DispatchQueue.main.async {
                Activity.shared.end(activity)
                FileService.notifyChanged(Array(Set(refs.compactMap(\.parent))))
                if case .failure(let error) = result { completion(error) } else { completion(nil) }
            }
        }
    }

    // MARK: Duplicate

    static func duplicate(_ items: [FileItem], completion: @escaping (Result<[ItemRef], Error>) -> Void) {
        guard let parent = items.first?.ref.parent else { return }
        queue.async {
            var existing = FileService.existingNames(in: parent)
            var created: [ItemRef] = []
            var failure: Error?
            for item in items {
                let name = FileService.uniqueName(item.name, existing: existing, isDirectory: item.isDirectory, copySuffix: true)
                existing.insert(name)
                let target = parent.appending(name)
                switch (item.ref, target) {
                case (.local(let from), .local(let to)):
                    do { try FileManager.default.copyItem(at: from, to: to); created.append(settled(target)) } catch { failure = error }
                case (.remote(let host, let from), .remote(_, let to)):
                    switch remote(host, "cp -Rp -- \(shq(from)) \(shq(to))") {
                    case .success: created.append(target)
                    case .failure(let error): failure = error
                    }
                default: break
                }
            }
            let result: Result<[ItemRef], Error> = failure.map { .failure($0) } ?? .success(created)
            if failure == nil, !created.isEmpty { DispatchQueue.main.async { UISound.play(UISound.copy) } }
            finish(result, changed: [parent], completion: completion)
        }
    }

    // MARK: Alias / compress

    static func makeAlias(_ items: [FileItem], completion: @escaping (Result<[ItemRef], Error>) -> Void) {
        queue.async {
            var created: [ItemRef] = []
            var failure: Error?
            var folders: [ItemRef] = []
            for item in items {
                guard case .local(let url) = item.ref else { continue }
                let parent = url.deletingLastPathComponent()
                let existing = FileService.existingNames(in: .local(parent))
                let name = FileService.uniqueName(item.name + " alias", existing: existing, isDirectory: true)
                let target = parent.appendingPathComponent(name)
                do {
                    let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                    try URL.writeBookmarkData(data, to: target)
                    created.append(.local(target))
                    folders.append(.local(parent))
                } catch { failure = error }
            }
            finish(failure.map { .failure($0) } ?? .success(created), changed: folders, completion: completion)
        }
    }

    static func compress(_ items: [FileItem], completion: @escaping (Result<ItemRef, Error>) -> Void) {
        guard let parent = items.first?.ref.parent else { return }
        let activity = Activity.shared.begin("Compressing…")
        queue.async {
            let existing = FileService.existingNames(in: parent)
            let baseName = items.count == 1 ? items[0].name + ".zip" : "Archive.zip"
            let zipName = FileService.uniqueName(baseName, existing: existing, isDirectory: false)
            let target = parent.appending(zipName)
            var result: Result<ItemRef, Error>
            switch parent {
            case .local(let dir):
                let args: [String]
                if items.count == 1 {
                    args = ["-c", "-k", "--sequesterRsrc", "--keepParent", items[0].ref.path, dir.appendingPathComponent(zipName).path]
                    let r = ProcessRunner.runSync("/usr/bin/ditto", args)
                    result = r.ok ? .success(target) : .failure(ScoutError(r.stderrString))
                } else {
                    // zip needs to run inside the folder so paths inside the archive are relative.
                    let script = "cd \(shq(dir.path)) && /usr/bin/zip -r -q -y \(shq(zipName)) " + items.map { shq($0.name) }.joined(separator: " ")
                    let r2 = ProcessRunner.runSync("/bin/sh", ["-c", script])
                    result = r2.ok ? .success(target) : .failure(ScoutError(r2.stderrString))
                }
            case .remote(let host, let dir):
                let names = items.map { shq($0.name) }.joined(separator: " ")
                let cmd = "cd -- \(shq(dir)) && if command -v zip >/dev/null; then zip -r -q -y \(shq(zipName)) \(names); else tar -czf \(shq((zipName as NSString).deletingPathExtension + ".tar.gz")) \(names); fi"
                result = remote(host, cmd).map { target }
            }
            DispatchQueue.main.async { Activity.shared.end(activity) }
            finish(result, changed: [parent], completion: completion)
        }
    }

    // MARK: Copy / move between any two places

    /// Copies or moves items into a folder, asking about name conflicts like Finder does.
    static func transfer(_ sources: [ItemRef], to destination: ItemRef, move: Bool, window: NSWindow?,
                         completion: (([ItemRef]) -> Void)? = nil) {
        let sources = sources.filter { src in
            // Can't put a folder inside itself.
            if src == destination { return false }
            if src.remoteHost == destination.remoteHost, destination.path.hasPrefix(src.path + "/") { return false }
            return true
        }
        guard !sources.isEmpty else { return }

        queue.async {
            let existing = FileService.existingNames(in: destination)
            let sameFolder = sources.filter { $0.parent == destination }
            let conflicts = sources.filter { existing.contains($0.name) && $0.parent != destination }
            DispatchQueue.main.async {
                let run: (ConflictPolicy) -> Void = { policy in
                    perform(sources, to: destination, move: move, policy: policy, existing: existing,
                            sameFolder: Set(sameFolder), completion: completion)
                }
                guard let first = conflicts.first else { run(.keepBoth); return }
                let alert = NSAlert()
                alert.messageText = conflicts.count == 1
                    ? "An item named “\(first.name)” already exists in this location. Do you want to replace it with the one you’re \(move ? "moving" : "copying")?"
                    : "\(conflicts.count) items with the same names already exist in this location. Do you want to replace them with the ones you’re \(move ? "moving" : "copying")?"
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Stop")
                alert.addButton(withTitle: "Keep Both")
                let handle: (NSApplication.ModalResponse) -> Void = { response in
                    switch response {
                    case .alertFirstButtonReturn: run(.replace)
                    case .alertThirdButtonReturn: run(.keepBoth)
                    default: break
                    }
                }
                if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
            }
        }
    }

    private static func perform(_ sources: [ItemRef], to destination: ItemRef, move: Bool, policy: ConflictPolicy,
                                existing: Set<String>, sameFolder: Set<ItemRef>, completion: (([ItemRef]) -> Void)?) {
        let title = sources.count == 1 ? "“\(sources[0].name)”" : "\(sources.count) items"
        let description = "\(move ? "Moving" : "Copying") \(title) to “\(destination.name)”"
        let activity = Activity.shared.begin(description + "…")
        let progress = TransferProgress(title: description, move: move)
        ProgressWindowController.shared.track(progress)
        queue.async {
            var names = existing
            var created: [ItemRef] = []
            var errors: [String] = []
            var changed: Set<ItemRef> = [destination]
            var undoMoves: [(from: URL, to: URL)] = []
            let sizes = measure(sources, to: destination, move: move, progress: progress)
            progress.total = sizes.flatMap { sizes in
                let total = sizes.values.reduce(0, +)
                return total > 0 ? total : nil
            }

            for src in sources {
                if progress.isCancelled { break }
                var name = src.name
                if sameFolder.contains(src) {
                    if move { continue }
                    name = FileService.uniqueName(name, existing: names, isDirectory: true, copySuffix: true)
                } else if names.contains(name) {
                    switch policy {
                    case .skip: continue
                    case .keepBoth: name = FileService.uniqueName(name, existing: names, isDirectory: isDirectory(src))
                    case .replace:
                        if case .failure(let e) = delete(destination.appending(name)) { errors.append(e.localizedDescription); continue }
                    }
                }
                names.insert(name)
                let target = destination.appending(name)
                let before = progress.completed
                switch copyOne(src, to: target, move: move, progress: progress) {
                case .success:
                    // Clones and other quiet copies don't report as they go; count the item as done.
                    if let size = sizes?[src] { progress.add(size - (progress.completed - before)) }
                    created.append(settled(target))
                    if let p = src.parent, move { changed.insert(p) }
                    if move, case .local(let a) = src, case .local(let b) = target { undoMoves.append((a, b)) }
                case .failure(let error):
                    if progress.isCancelled {
                        // Like Finder, a stopped copy doesn't leave a half-copied item behind.
                        // A move whose source is already gone did finish, so its target stays.
                        if !move || exists(src) { removePartial(target) }
                    } else {
                        errors.append(error.localizedDescription)
                    }
                }
            }

            DispatchQueue.main.async {
                progress.finish()
                ProgressWindowController.shared.finished(progress)
                Activity.shared.end(activity)
                FileService.notifyChanged(Array(changed))
                registerUndo(move: move, created: created, undoMoves: undoMoves)
                if !created.isEmpty, errors.isEmpty, !progress.isCancelled { UISound.play(UISound.copy) }
                if !errors.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "The operation can’t be completed."
                    alert.informativeText = errors.prefix(5).joined(separator: "\n")
                    alert.runModal()
                }
                completion?(created)
            }
        }
    }

    private static func registerUndo(move: Bool, created: [ItemRef], undoMoves: [(from: URL, to: URL)]) {
        guard let undo = NSApp.keyWindow?.undoManager else { return }
        if move, !undoMoves.isEmpty {
            undo.registerUndo(withTarget: NSApp) { _ in
                for m in undoMoves { try? FileManager.default.moveItem(at: m.to, to: m.from) }
                FileService.notifyChanged(undoMoves.flatMap { [ItemRef.local($0.from.deletingLastPathComponent()), .local($0.to.deletingLastPathComponent())] })
            }
            undo.setActionName("Move")
        } else if !move {
            let urls = created.compactMap(\.localURL)
            guard !urls.isEmpty else { return }
            undo.registerUndo(withTarget: NSApp) { _ in
                trash(urls) { _, _ in }
            }
            undo.setActionName("Copy")
        }
    }

    private static func isDirectory(_ ref: ItemRef) -> Bool {
        if case .local(let url) = ref { return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
        return true
    }

    private static func delete(_ ref: ItemRef) -> Result<Void, Error> {
        switch ref {
        case .local(let url):
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); return .success(()) } catch { return .failure(error) }
        case .remote(let host, let path):
            return remote(host, "rm -rf -- \(shq(path))")
        }
    }

    /// Copies (or moves) a single item to an exact target path.
    private static func copyOne(_ src: ItemRef, to target: ItemRef, move: Bool, progress: TransferProgress?) -> Result<Void, Error> {
        switch (src, target) {
        case (.local(let from), .local(let to)):
            if move, sameVolume(from, to.deletingLastPathComponent()) {
                do { try FileManager.default.moveItem(at: from, to: to); return .success(()) } catch { return .failure(error) }
            }
            // Copying (or moving to another disk, which copies and then deletes) reports progress as it goes.
            let result = copyLocal(from, to: to, progress: progress)
            if move, case .success = result {
                do { try FileManager.default.removeItem(at: from) } catch { return .failure(error) }
            }
            return result

        case (.remote(let h1, let from), .remote(let h2, let to)) where h1 == h2:
            return remote(h1, "\(move ? "mv" : "cp -Rp") -- \(shq(from)) \(shq(to))", progress: progress)

        case (.local(let from), .remote(let host, let to)):
            let result = upload(from, host: host, to: to, progress: progress)
            if move, case .success = result { try? FileManager.default.removeItem(at: from) }
            return result

        case (.remote(let host, let from), .local(let to)):
            let result = download(host: host, path: from, to: to, progress: progress)
            if move, case .success = result { _ = remote(host, "rm -rf -- \(shq(from))") }
            return result

        case (.remote(let h1, let from), .remote(let h2, let to)):
            // Different hosts: stage through a local temporary folder.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scout-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let staged = tmp.appendingPathComponent((from as NSString).lastPathComponent)
            if case .failure(let e) = download(host: h1, path: from, to: staged, progress: progress) { return .failure(e) }
            let result = upload(staged, host: h2, to: to, progress: progress)
            if move, case .success = result { _ = remote(h1, "rm -rf -- \(shq(from))") }
            return result
        }
    }

    // MARK: Progress

    /// The bytes each item will take to transfer, for the progress bar. Nil when that can't be told in advance
    /// (copies within one server). Moves within one disk count as nothing, since they're instant.
    private static func measure(_ sources: [ItemRef], to destination: ItemRef, move: Bool, progress: TransferProgress) -> [ItemRef: Int64]? {
        var sizes: [ItemRef: Int64] = [:]
        for src in sources {
            if progress.isCancelled { return nil }
            switch (src, destination) {
            case (.local(let from), .local(let to)):
                sizes[src] = move && sameVolume(from, to) ? 0 : localSize(from, progress: progress)
            case (.local(let from), .remote):
                sizes[src] = localSize(from, progress: progress)
            case (.remote(let host, let path), .local):
                guard let size = remoteSize(host, path) else { return nil }
                sizes[src] = size
            case (.remote(let h1, let path), .remote(let h2, _)):
                guard h1 != h2, let size = remoteSize(h1, path) else { return nil }
                sizes[src] = 2 * size   // downloaded, then uploaded again
            }
        }
        return sizes
    }

    private static func localSize(_ url: URL, progress: TransferProgress) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var count = 0
        for case let item as URL in enumerator {
            count += 1
            if count % 1000 == 0, progress.isCancelled { break }
            guard let v = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }

    private static func remoteSize(_ host: String, _ path: String) -> Int64? {
        let result = SSHManager.shared.host(host).runSync("du -sk -- \(shq(path)) 2>/dev/null")
        guard let field = result.stdoutString.split(whereSeparator: \.isWhitespace).first, let kb = Int64(field) else { return nil }
        return kb * 1024
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb)
    }

    private static func exists(_ ref: ItemRef) -> Bool {
        switch ref {
        case .local(let url): return (try? url.checkResourceIsReachable()) ?? false
        case .remote(let host, let path): return SSHManager.shared.host(host).runSync("test -e \(shq(path)) || test -L \(shq(path))").ok
        }
    }

    private static func removePartial(_ ref: ItemRef) {
        switch ref {
        case .local(let url): try? FileManager.default.removeItem(at: url)
        case .remote(let host, let path): _ = remote(host, "rm -rf -- \(shq(path))")
        }
    }

    /// What the copyfile callback needs: the shared progress, and how much of the current file it has counted.
    private final class CopyContext {
        let progress: TransferProgress?
        var fileCounted: Int64 = 0
        init(_ progress: TransferProgress?) { self.progress = progress }

        func count(_ bytes: Int64) { progress?.add(bytes) }
    }

    private static let copyCallback: copyfile_callback_t = { what, stage, state, src, _, ctx in
        guard let ctx else { return COPYFILE_CONTINUE }
        let context = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
        if context.progress?.isCancelled == true { return COPYFILE_QUIT }
        switch (Int(what), Int(stage)) {
        case (Int(COPYFILE_RECURSE_FILE), Int(COPYFILE_START)):
            context.fileCounted = 0
        case (Int(COPYFILE_COPY_DATA), Int(COPYFILE_PROGRESS)):
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                context.count(Int64(copied) - context.fileCounted)
                context.fileCounted = max(context.fileCounted, Int64(copied))
            }
        case (Int(COPYFILE_RECURSE_FILE), Int(COPYFILE_FINISH)):
            // Cloned and very small files don't report data progress; count them whole.
            var info = stat()
            if let src, lstat(src, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
                context.count(Int64(info.st_size) - context.fileCounted)
            }
            context.fileCounted = 0
        default:
            break
        }
        return COPYFILE_CONTINUE
    }

    /// Copies a file or folder on this Mac the way Finder does (cloning where the disk allows it),
    /// counting bytes into `progress` and stopping when it's cancelled.
    private static func copyLocal(_ from: URL, to: URL, progress: TransferProgress?) -> Result<Void, Error> {
        guard let state = copyfile_state_alloc() else { return .failure(ScoutError("Couldn’t copy “\(from.lastPathComponent)”.")) }
        defer { copyfile_state_free(state) }
        let context = CopyContext(progress)
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)
        let status = copyfile(from.path, to.path, state, flags)
        let code = errno
        if progress?.isCancelled == true { return .failure(CocoaError(.userCancelled)) }
        if status < 0 {
            let reason = String(cString: strerror(code))
            return .failure(ScoutError("Couldn’t copy “\(from.lastPathComponent)”: \(reason)."))
        }
        return .success(())
    }

    /// Passes data from one pipe to another, counting it. Writes never raise SIGPIPE: if the reader goes away,
    /// `broken` runs (to stop the writer) and the relay keeps draining its input so nothing upstream blocks.
    private static func relay(from input: FileHandle, to output: FileHandle, progress: TransferProgress?,
                              broken: @escaping () -> Void) -> DispatchGroup {
        _ = fcntl(output.fileDescriptor, F_SETNOSIGPIPE, 1)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var writing = true
            while let data = try? input.read(upToCount: 256 * 1024), !data.isEmpty {
                guard writing else { continue }
                do {
                    try output.write(contentsOf: data)
                    progress?.add(Int64(data.count))
                } catch {
                    writing = false
                    broken()
                }
            }
            try? output.close()
            group.leave()
        }
        return group
    }

    // MARK: SSH transfers (tar streams, so folders, permissions and odd names all survive)

    private static let tarFlags = ["--no-mac-metadata", "--no-xattrs", "--no-acls"]

    static func upload(_ local: URL, host: String, to remotePath: String, progress: TransferProgress? = nil) -> Result<Void, Error> {
        let ssh = SSHManager.shared.host(host)
        let parent = local.deletingLastPathComponent().path
        let name = local.lastPathComponent
        let remoteDir = (remotePath as NSString).deletingLastPathComponent
        let script = """
        t=$(mktemp -d \(shq(remoteDir + "/.scout-upload.XXXXXX"))) || exit 1
        tar -xf - -C "$t" && mv -- "$t"/\(shq(name)) \(shq(remotePath)); r=$?
        rm -rf -- "$t"; exit $r
        """
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-c", "-f", "-"] + tarFlags + ["-C", parent, name]
        tar.environment = ["COPYFILE_DISABLE": "1"]
        let tarOut = Pipe()
        let sshIn = Pipe()
        tar.standardOutput = tarOut
        tar.standardError = FileHandle.nullDevice
        do { try tar.run() } catch { return .failure(error) }
        progress?.setCancelHandler { if tar.isRunning { tar.terminate() } }
        let relayed = relay(from: tarOut.fileHandleForReading, to: sshIn.fileHandleForWriting, progress: progress) {
            if tar.isRunning { tar.terminate() }
        }
        let result = ssh.runSync(script, input: sshIn) { process in
            progress?.setCancelHandler {
                process.terminate()
                if tar.isRunning { tar.terminate() }
            }
        }
        progress?.setCancelHandler(nil)
        // If ssh never ran or quit early, make sure the relay and tar can finish.
        if tar.isRunning, !result.ok { tar.terminate() }
        try? sshIn.fileHandleForReading.close()
        relayed.wait()
        tar.waitUntilExit()
        if progress?.isCancelled == true { return .failure(CocoaError(.userCancelled)) }
        if !result.ok { return .failure(ScoutError(SSHHost.cleanError(result.stderrString, fallback: "Couldn’t upload “\(name)”."))) }
        return .success(())
    }

    static func download(host: String, path: String, to local: URL, progress: TransferProgress? = nil) -> Result<Void, Error> {
        let ssh = SSHManager.shared.host(host)
        let fm = FileManager.default
        let staging: URL
        do {
            staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: local.deletingLastPathComponent(), create: true)
        } catch {
            staging = fm.temporaryDirectory.appendingPathComponent("scout-\(UUID().uuidString)")
            try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: staging) }

        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-x", "-f", "-", "-C", staging.path]
        let sshOut = Pipe()
        let untarIn = Pipe()
        untar.standardInput = untarIn
        let untarErr = Pipe()
        untar.standardError = untarErr
        do { try untar.run() } catch { return .failure(error) }
        var sshProcess: Process?
        let lock = NSLock()
        let relayed = relay(from: sshOut.fileHandleForReading, to: untarIn.fileHandleForWriting, progress: progress) {
            lock.lock(); let process = sshProcess; lock.unlock()
            process?.terminate()
        }
        let result = ssh.runSync("tar -cf - -C \(shq(parent.isEmpty ? "/" : parent)) -- \(shq(name))", output: sshOut) { process in
            lock.lock(); sshProcess = process; lock.unlock()
            progress?.setCancelHandler {
                process.terminate()
                if untar.isRunning { untar.terminate() }
            }
        }
        progress?.setCancelHandler(nil)
        // If ssh never started, nothing closes the pipe's write end; do it so the relay sees the end.
        try? sshOut.fileHandleForWriting.close()
        relayed.wait()
        untar.waitUntilExit()
        if progress?.isCancelled == true { return .failure(CocoaError(.userCancelled)) }
        if !result.ok {
            return .failure(ScoutError(SSHHost.cleanError(result.stderrString, fallback: "Couldn’t download “\(name)”.")))
        }
        do {
            try fm.moveItem(at: staging.appendingPathComponent(name), to: local)
        } catch { return .failure(error) }
        return .success(())
    }

    /// Downloads a remote file into the cache so it can be opened or previewed.
    static func cachedCopy(of ref: ItemRef, completion: @escaping (Result<URL, Error>) -> Void) {
        guard case .remote(let host, let path) = ref else {
            if let url = ref.localURL { completion(.success(url)) }
            return
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.matej.Scout/Remote", isDirectory: true)
        let safeHost = host.replacingOccurrences(of: "/", with: "_")
        let local = base.appendingPathComponent(safeHost).appendingPathComponent(String(path.drop(while: { $0 == "/" })))
        let activity = Activity.shared.begin("Downloading “\(ref.name)”…")
        queue.async {
            try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: local)
            let result = download(host: host, path: path, to: local).map { local }
            DispatchQueue.main.async {
                Activity.shared.end(activity)
                completion(result)
            }
        }
    }

    // MARK: Helpers

    /// A local ref made before its item existed lacks the trailing slash a folder's URL gets once it's on disk,
    /// so it wouldn't match the folder in a listing (to select it or rename it). Rebuilt afterwards, it does.
    private static func settled(_ ref: ItemRef) -> ItemRef {
        guard case .local(let url) = ref else { return ref }
        return .local(url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent))
    }

    private static func remote(_ host: String, _ command: String, progress: TransferProgress? = nil) -> Result<Void, Error> {
        let ssh = SSHManager.shared.host(host)
        let result = ssh.runSync(command) { process in progress?.setCancelHandler { process.terminate() } }
        progress?.setCancelHandler(nil)
        if progress?.isCancelled == true { return .failure(CocoaError(.userCancelled)) }
        if result.ok { return .success(()) }
        return .failure(ScoutError(SSHHost.cleanError(result.stderrString, fallback: "The operation couldn’t be completed on “\(ssh.displayName)”.")))
    }

    private static func finish<T>(_ result: Result<T, Error>, changed: [ItemRef], completion: @escaping (Result<T, Error>) -> Void) {
        DispatchQueue.main.async {
            FileService.notifyChanged(changed)
            completion(result)
        }
    }

    static func emptyTrash() {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        DispatchQueue.global().async {
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            DispatchQueue.main.async { FileService.notifyChanged([.local(Location.trashURL)]) }
        }
    }
}
