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

    /// SCOUT_SEARCHTEST=<text>: types a search like a person would, waits for the results, then clicks a file
    /// in the list with real mouse events. The click must select that file, and the results must stay put.
    static func runSearch(_ query: String) {
        func at(_ t: TimeInterval, _ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: block) }
        func log(_ text: String) { NSLog("SEARCHTEST %@", text) }
        func finish() { at(0.5) { NSApp.terminate(nil) } }
        at(1.0) {
            guard let window = NSApp.windows.first(where: { $0.windowController is MainWindowController }),
                  let controller = window.windowController as? MainWindowController,
                  let field = controller.searchItem?.searchField else { log("FAIL no window"); finish(); return }
            let pane = controller.activePane!
            pane.setViewMode(.list)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            let started = PaneViewController.searchesStarted
            // Type one letter every 0.25 s, like unhurried typing.
            for (i, ch) in query.enumerated() {
                at(Double(i) * 0.25) {
                    let s = String(ch)
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: s,
                                                    charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) {
                            window.sendEvent(e)
                        }
                    }
                }
            }
            // SCOUT_SEARCHTEST_WAIT: seconds between the last letter and the click (default 4; less clicks while results still arrive).
            let wait = Double(ProcessInfo.processInfo.environment["SCOUT_SEARCHTEST_WAIT"] ?? "") ?? 4
            at(Double(query.count) * 0.25 + wait) {
                let typed = PaneViewController.searchesStarted - started
                log("typing started \(typed) searches for \(query.count) letters; field “\(field.stringValue)”, query \(pane.searchQuery ?? "nil"), scope \(pane.searchScope), loading \(pane.isLoading)")
                let outline = pane.content.focusView as! NSOutlineView
                let visible = outline.rows(in: outline.visibleRect)
                log("first visible row \(visible.location) (expect 0: results start at the top)")
                let rows = (visible.location..<visible.location + visible.length).filter {
                    (outline.item(atRow: $0) as? FileItem)?.isBrowsable == false && outline.visibleRect.contains(outline.rect(ofRow: $0))
                }
                guard let row = rows.first, let item = outline.item(atRow: row) as? FileItem else {
                    log("FAIL no file in results (\(pane.items.count) items)"); finish(); return
                }
                let count = pane.items.count
                let before = PaneViewController.searchesStarted
                let rect = outline.rect(ofRow: row)
                let point = outline.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
                let screenY = outline.convert(rect, to: nil).minY
                log("results \(count), clicking row \(row) \(item.name) at \(point) (row in window y \(screenY))")
                // The table tracks the mouse after a mouse down, so queue the mouse up first.
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                NSApp.postEvent(up, atStart: false)
                window.sendEvent(down)
                var samples: [String] = []
                for t in stride(from: 0.1, through: 3.0, by: 0.1) {
                    at(t) {
                        let selected = pane.selectedItems.map(\.name)
                        let row = outline.row(forItem: item)
                        let y = row >= 0 ? outline.convert(outline.rect(ofRow: row), to: nil).minY : -1
                        samples.append(String(format: "%.1f:%@/%d/%.0f", t, selected.first ?? "-", pane.items.count, y))
                    }
                }
                at(3.2) {
                    let selected = pane.selectedItems.map(\.ref)
                    let restarted = PaneViewController.searchesStarted - before
                    let row = outline.row(forItem: item)
                    let y = row >= 0 ? outline.convert(outline.rect(ofRow: row), to: nil).minY : -1
                    log("samples (time:selection/results/row y) " + samples.joined(separator: " "))
                    log("after click: selected \(pane.selectedItems.map(\.name)), results \(pane.items.count), searches restarted \(restarted), row y \(y)")
                    let ok = selected == [item.ref] && restarted == 0 && abs(y - screenY) < 1 && visible.location == 0 && typed == 1
                    log(ok ? "PASS" : "FAIL")
                    finish()
                }
            }
        }
    }

    /// SCOUT_OPSTEST=<empty folder>: in a real window, checks that toolbar clicks leave the active pane alone in
    /// split view, that a new folder's name is ready to type straight away, and that a long copy shows the
    /// progress window (after its delay), finishes, and can be stopped without leaving a partial copy.
    /// SCOUT_OPSTEST_SOURCE names the big file to copy; it should be on another disk, so it's copied rather than cloned.
    static func runOps(folder: String) {
        func at(_ t: TimeInterval, _ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: block) }
        func log(_ text: String) { NSLog("OPSTEST %@", text) }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            log("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
            if !ok { failures += 1 }
        }
        let dir = URL(fileURLWithPath: folder)
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCOUT_OPSTEST_SOURCE"]
                         ?? "/System/Library/Frameworks")
        let progressWindow = ProgressWindowController.shared.window!
        func progressText() -> String {
            var texts: [String] = []
            func walk(_ v: NSView) {
                if let f = v as? NSTextField, !f.stringValue.isEmpty { texts.append(f.stringValue) }
                if let bar = v as? NSProgressIndicator { texts.append(bar.isIndeterminate ? "[indeterminate]" : String(format: "[%.0f%%]", bar.doubleValue * 100)) }
                v.subviews.forEach(walk)
            }
            if let content = progressWindow.contentView { walk(content) }
            return texts.joined(separator: " | ")
        }
        /// Total bytes of the regular files in a file or folder, and how many there are.
        func contents(_ url: URL) -> (bytes: Int, files: Int) {
            var bytes = 0, files = 0
            let urls = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])?.allObjects as? [URL] ?? [url]
            for u in urls + [url] {
                guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
                bytes += v.fileSize ?? 0
                files += 1
            }
            return (bytes, files)
        }
        func click(_ window: NSWindow, at point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(e)
            }
        }

        at(1.0) {
            guard let window = NSApp.windows.first(where: { $0.windowController is MainWindowController }),
                  let controller = window.windowController as? MainWindowController else { log("FAIL no window"); NSApp.terminate(nil); return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.setContentSize(NSSize(width: 1100, height: 650))
            controller.activePane.navigate(to: .folder(.local(dir)))
            controller.activePane.setViewMode(.list)
            controller.toggleSplit(nil)
            at(1.0) {
                // 1. Toolbar clicks over the right pane don't activate it; clicks in the pane do.
                let left = controller.panes[0], right = controller.panes[1]
                left.focus()
                let rightFrame = right.view.convert(right.view.bounds, to: nil)
                let toolbarY = (window.contentLayoutRect.maxY + window.frame.height) / 2
                click(window, at: NSPoint(x: rightFrame.midX, y: toolbarY))
                check("toolbar click keeps left pane active", controller.activePane === left)
                window.makeFirstResponder(controller.searchItem?.searchField)
                check("search field click keeps left pane active", controller.activePane === left)
                left.focus()
                click(window, at: NSPoint(x: rightFrame.midX, y: rightFrame.midY))
                check("content click activates right pane", controller.activePane === right)
                left.focus()

                // 2. A new folder's name is being edited straight away, in list and icon views (the watcher reload comes after).
                left.newFolder(nil)
                at(1.2) {
                    let editor = window.firstResponder as? NSTextView
                    check("new folder name editable (list)", left.content.isEditingName && editor?.isFieldEditor == true,
                          "editing \(left.content.isEditingName), first responder \(String(describing: window.firstResponder))")
                    editor?.string = "renamed folder"
                    window.makeFirstResponder(left.content.focusView)
                    at(1.0) {
                        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                        check("typed name applied", names.contains("renamed folder"), names.description)
                        subfolderTest(left, window: window) {
                            left.setViewMode(.icon)
                            left.newFolder(nil)
                            at(1.2) {
                                check("new folder name editable (icons)", left.content.isEditingName && (window.firstResponder as? NSTextView)?.isFieldEditor == true,
                                      "first responder \(String(describing: window.firstResponder))")
                                window.makeFirstResponder(left.content.focusView)
                                left.setViewMode(.list)
                                copyTest(controller: controller)
                            }
                        }
                    }
                }
            }
        }

        // 2b. A folder's context menu offers a new folder inside it: revealed and renamed in place in the list,
        //     named up front (“New Subfolder”) in icon view.
        func subfolderTest(_ pane: PaneViewController, window: NSWindow, then next: @escaping () -> Void) {
            let parent = URL(fileURLWithPath: folder).appendingPathComponent("renamed folder")
            func menuTitle() -> String? {
                pane.contextMenu(for: pane.selectedItems).items.first { $0.action == #selector(PaneViewController.newSubfolder(_:)) }?.title
            }
            pane.content.select([.local(parent)])
            check("folder menu offers New Folder (list)", menuTitle() == "New Folder", String(describing: menuTitle()))
            pane.newSubfolder(nil)
            at(1.2) {
                let inside = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
                check("subfolder created inside", inside == ["untitled folder"], inside.description)
                check("subfolder name editable (list)", pane.content.isEditingName && (window.firstResponder as? NSTextView)?.isFieldEditor == true,
                      "first responder \(String(describing: window.firstResponder))")
                window.makeFirstResponder(pane.content.focusView)
                pane.setViewMode(.icon)
                at(0.5) {
                    pane.content.select([.local(parent)])
                    check("folder menu offers New Subfolder (icons)", menuTitle() == "New Subfolder", String(describing: menuTitle()))
                    pane.setViewMode(.list)
                    at(0.5, next)
                }
            }
        }

        // 3. A long copy shows progress after the delay, completes, and stops cleanly when cancelled.
        func copyTest(controller: MainWindowController) {
            let target = dir.appendingPathComponent(source.lastPathComponent)
            let expected = contents(source)
            let start = Date()
            FileOps.transfer([.local(source)], to: .local(dir), move: false, window: controller.window)
            at(ProgressWindowController.showDelay - 0.5) {
                check("progress hidden before the delay", !progressWindow.isVisible)
            }
            var samples: [String] = []
            for t in stride(from: 1.2, through: 4.0, by: 0.7) { at(t) { samples.append(progressText()) } }
            func waitDone() {
                if !Activity.shared.tasks.isEmpty, Date().timeIntervalSince(start) < 120 { at(0.25, waitDone); return }
                at(0.5) {
                    let copied = contents(target)
                    log("copied in \(String(format: "%.1f", Date().timeIntervalSince(start))) s; samples: \(samples.joined(separator: " || "))")
                    check("progress shown during copy", samples.contains { $0.contains("Copying") && $0.contains(" of ") })
                    check("copy complete", copied == expected, "\(copied) vs \(expected)")
                    check("progress closed after copy", !progressWindow.isVisible)
                    try? FileManager.default.removeItem(at: target)
                    cancelTest(controller: controller)
                }
            }
            at(1.0, waitDone)
        }

        func cancelTest(controller: MainWindowController) {
            let target = dir.appendingPathComponent(source.lastPathComponent)
            FileOps.transfer([.local(source)], to: .local(dir), move: false, window: controller.window)
            at(1.8) {
                var stop: NSButton?
                func find(_ v: NSView) { if let b = v as? NSButton, b.toolTip == "Stop" { stop = b }; v.subviews.forEach(find) }
                if let content = progressWindow.contentView { find(content) }
                log("before stop: \(progressText())")
                check("stop button present", stop != nil)
                stop?.performClick(nil)
                at(2.5) {
                    check("stopped copy removed", !FileManager.default.fileExists(atPath: target.path))
                    check("progress closed after stop", !progressWindow.isVisible)
                    log(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// SCOUT_REFRESHTEST=<empty folder>: in list view with a folder expanded, makes a new folder, renames it, moves
    /// it into the expanded folder, trashes a file and changes the folder behind Scout's back. The list must take
    /// each change in place: never rebuilt as a whole, the expanded folder never collapsing (sampled every few ms).
    static func runRefresh(folder: String) {
        func at(_ t: TimeInterval, _ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: block) }
        func log(_ text: String) { NSLog("REFRESHTEST %@", text) }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            log("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
            if !ok { failures += 1 }
        }
        let dir = URL(fileURLWithPath: folder)
        let fm = FileManager.default
        let mermaid = dir.appendingPathComponent("Little Mermaid")
        for name in ["Alpha", "Zed", "Little Mermaid/a", "Little Mermaid/b"] {
            try? fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["one.txt", "two.txt"] { fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data()) }

        at(1.0) {
            guard let window = NSApp.windows.first(where: { $0.windowController is MainWindowController }),
                  let controller = window.windowController as? MainWindowController else { log("FAIL no window"); NSApp.terminate(nil); return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let pane = controller.activePane!
            pane.navigate(to: .folder(.local(dir)))
            pane.setViewMode(.list)
            at(1.0) {
                let outline = pane.content.focusView as! NSOutlineView
                func row(_ name: String) -> Int {
                    (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? FileItem)?.name == name } ?? -1
                }
                func names() -> [String] {
                    (0..<outline.numberOfRows).map { r in
                        let item = outline.item(atRow: r) as! FileItem
                        return String(repeating: "  ", count: outline.level(forRow: r)) + item.name
                    }
                }
                outline.expandItem(outline.item(atRow: row("Little Mermaid")))
                at(0.8) {
                    guard let expanded = outline.item(atRow: row("Little Mermaid")) as? FileItem, outline.isItemExpanded(expanded) else {
                        log("FAIL couldn't expand: \(names())"); NSApp.terminate(nil); return
                    }
                    log("start: \(names())")
                    let reloadsBefore = ListContentController.fullReloads
                    var collapsedSamples = 0, replacedSamples = 0, samples = 0
                    let sampler = Timer(timeInterval: 0.004, repeats: true) { _ in
                        samples += 1
                        let r = row("Little Mermaid")
                        let item = r >= 0 ? outline.item(atRow: r) as? FileItem : nil
                        if item !== expanded { replacedSamples += 1 }
                        if item.map({ !outline.isItemExpanded($0) }) ?? true { collapsedSamples += 1 }
                    }
                    RunLoop.main.add(sampler, forMode: .common)

                    // 1. New folder, named while the watcher's reload waits.
                    pane.newFolder(nil)
                    at(1.0) {
                        let editor = window.firstResponder as? NSTextView
                        check("new folder name editable", pane.content.isEditingName && editor?.isFieldEditor == true)
                        editor?.string = "test"
                        window.makeFirstResponder(outline)
                        at(1.0) {
                            check("renamed in place", row("test") >= 0 && outline.level(forRow: row("test")) == 0, "\(names())")
                            check("renamed folder selected", (outline.item(atRow: outline.selectedRow) as? FileItem)?.name == "test")
                            // 2. Move it into the expanded folder.
                            FileOps.transfer([.local(dir.appendingPathComponent("test"))], to: .local(mermaid), move: true, window: window)
                            at(1.5) {
                                let r = row("test")
                                check("moved into expanded folder", r >= 0 && outline.level(forRow: r) == 1
                                      && outline.parent(forItem: outline.item(atRow: r)) as? FileItem === expanded, "\(names())")
                                // 3. Trash a file.
                                FileOps.trash([dir.appendingPathComponent("one.txt")]) { _, _ in }
                                at(1.5) {
                                    check("trashed file gone", row("one.txt") < 0, "\(names())")
                                    // 4. Changes made elsewhere: a new file at the top, a folder removed inside the expanded one.
                                    fm.createFile(atPath: dir.appendingPathComponent("three.txt").path, contents: Data())
                                    try? fm.removeItem(at: mermaid.appendingPathComponent("a"))
                                    at(1.5) {
                                        sampler.invalidate()
                                        check("outside new file shown", row("three.txt") >= 0, "\(names())")
                                        // The folder's own date changed, so its contents are refreshed too.
                                        check("outside removal in expanded folder shown", row("a") < 0, "\(names())")
                                        let reloads = ListContentController.fullReloads - reloadsBefore
                                        check("list never rebuilt", reloads == 0, "\(reloads) full reloads")
                                        check("expanded folder never collapsed", collapsedSamples == 0, "\(collapsedSamples)/\(samples) samples")
                                        check("expanded folder kept its row", replacedSamples == 0, "\(replacedSamples)/\(samples) samples")
                                        let top = (pane.content as! ListContentController).topLevelNames
                                        check("order matches sort", top == pane.sorted(pane.items).map(\.name), "\(top)")
                                        log("end: \(names())")
                                        log(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
                                        NSApp.terminate(nil)
                                    }
                                }
                            }
                        }
                    }
                }
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
