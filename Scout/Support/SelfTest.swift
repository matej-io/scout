import AppKit

/// Exercises file operations end to end (local and over SSH) when launched with
/// SCOUT_SELFTEST=<ssh host>. Everything happens in temporary folders that are removed afterwards.
enum SelfTest {
    /// SCOUT_SPRINGTEST=1: checks spring-loading timing (quick passes don't open, holding does).
    static func runSpring() {
        var opened: [String] = []
        var blinks = 0
        let loader = SpringLoader(blink: { _, _ in blinks += 1 }, open: { key in opened.append(key.base as! String) })
        let start = Date()
        func at(_ t: TimeInterval, _ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: block) }
        loader.hover("A")                       // pass over A quickly…
        at(0.2) { loader.hover("B") }          // …then B
        at(0.3) { loader.hover("B") }          // repeated updates over B don't restart the timer
        at(0.45) { loader.hover("B") }
        at(1.2) {
            NSLog("SPRINGTEST opened=%@ blinks=%d (expect [B], 4) delay=%.2f", opened.description, blinks, SpringLoader.delay)
            loader.hover("C")
            at(0.3) { loader.hover(nil) }      // leave C before the delay
            at(1.0) {
                NSLog("SPRINGTEST after leaving C opened=%@ (expect [B]) elapsed=%.1f", opened.description, Date().timeIntervalSince(start))
                NSApp.terminate(nil)
            }
        }
    }

    static func run(host: String) {
        let queue = DispatchQueue(label: "selftest")
        queue.async {
            var failures = 0
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                NSLog("SELFTEST %@ %@ %@", ok ? "PASS" : "FAIL", name, detail)
                if !ok { failures += 1 }
            }
            func wait<T>(_ body: @escaping (@escaping (T) -> Void) -> Void) -> T {
                let sem = DispatchSemaphore(value: 0)
                var value: T!
                DispatchQueue.main.async { body { value = $0; sem.signal() } }
                sem.wait()
                return value
            }

            let fm = FileManager.default
            let local = fm.temporaryDirectory.appendingPathComponent("scout-selftest-\(UUID().uuidString.prefix(8))")
            try? fm.createDirectory(at: local, withIntermediateDirectories: true)
            let localRef = ItemRef.local(local)
            try? "hello from scout\n".write(to: local.appendingPathComponent("hello world.txt"), atomically: true, encoding: .utf8)
            try? fm.createDirectory(at: local.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
            try? "x".write(to: local.appendingPathComponent("nested/deeper/it's here.txt"), atomically: true, encoding: .utf8)

            // Local operations
            let folder: Result<ItemRef, Error> = wait { FileOps.newFolder(in: localRef, completion: $0) }
            check("local new folder", (try? folder.get())?.name == "untitled folder")
            let renamed: Result<ItemRef, Error> = wait { FileOps.rename(localRef.appending("untitled folder"), to: "Renamed", completion: $0) }
            check("local rename", fm.fileExists(atPath: local.appendingPathComponent("Renamed").path), "\(renamed)")
            let hello = FileItem.local(local.appendingPathComponent("hello world.txt"))!
            let dup: Result<[ItemRef], Error> = wait { FileOps.duplicate([hello], completion: $0) }
            check("local duplicate", fm.fileExists(atPath: local.appendingPathComponent("hello world copy.txt").path), "\(dup)")

            // Remote operations
            let ssh = SSHManager.shared.host(host)
            let connected: Result<Void, Error> = wait { ssh.connect($0) }
            check("ssh connect", (try? connected.get()) != nil, "\(connected)")
            guard ssh.isConnected else { finish(failures, local); return }
            let mk = ssh.runSync("mktemp -d /tmp/scout-selftest.XXXXXX")
            let remoteDir = mk.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            check("remote temp dir", mk.ok && remoteDir.hasPrefix("/tmp/"), remoteDir)
            let remoteRef = ItemRef.remote(host: host, path: remoteDir)

            let rfolder: Result<ItemRef, Error> = wait { FileOps.newFolder(in: remoteRef, completion: $0) }
            check("remote new folder", (try? rfolder.get())?.name == "untitled folder", "\(rfolder)")
            let rrename: Result<ItemRef, Error> = wait { FileOps.rename(remoteRef.appending("untitled folder"), to: "Remote Renamed", completion: $0) }
            check("remote rename", (try? rrename.get()) != nil, "\(rrename)")

            check("upload file", (try? FileOps.upload(local.appendingPathComponent("hello world.txt"), host: host, to: remoteDir + "/hello world.txt").get()) != nil)
            check("upload folder", (try? FileOps.upload(local.appendingPathComponent("nested"), host: host, to: remoteDir + "/nested").get()) != nil)
            let listing = FileService.listSync(remoteRef, showHidden: true)
            let names = Set((try? listing.get())?.map(\.name) ?? [])
            check("remote listing", names == ["Remote Renamed", "hello world.txt", "nested"], "\(names.sorted())")
            let content = ssh.runSync("cat \(shq(remoteDir + "/nested/deeper/it's here.txt"))").stdoutString
            check("upload nested content", content == "x", content)

            let back = local.appendingPathComponent("downloaded")
            check("download folder", (try? FileOps.download(host: host, path: remoteDir + "/nested", to: back).get()) != nil)
            check("download content", (try? String(contentsOf: back.appendingPathComponent("deeper/it's here.txt"), encoding: .utf8)) == "x")

            let cached: Result<URL, Error> = wait { FileOps.cachedCopy(of: remoteRef.appending("hello world.txt"), completion: $0) }
            check("cached copy for open/Quick Look", (try? String(contentsOf: cached.get(), encoding: .utf8)) == "hello from scout\n", "\(cached)")

            let rdup: Result<[ItemRef], Error> = wait {
                FileOps.duplicate([FileItem(ref: remoteRef.appending("hello world.txt"), name: "hello world.txt", isDirectory: false,
                                            isHidden: false, size: nil, modified: nil, kind: "")], completion: $0)
            }
            check("remote duplicate", (try? rdup.get())?.first?.name == "hello world copy.txt", "\(rdup)")

            let del: Error? = wait { FileOps.deleteRemote([remoteRef.appending("hello world copy.txt")], completion: $0) }
            check("remote delete", del == nil)

            let search = FileService.listSync(remoteRef, showHidden: true)
            check("after delete", (try? search.get())?.contains { $0.name == "hello world copy.txt" } == false)

            _ = ssh.runSync("rm -rf -- \(shq(remoteDir))")
            finish(failures, local)
        }
    }

    private static func finish(_ failures: Int, _ local: URL) {
        try? FileManager.default.removeItem(at: local)
        NSLog("SELFTEST DONE failures=%d", failures)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
