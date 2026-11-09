import AppKit
import OSLog
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Keys {
        static let enabled = "enabled"
        static let shownWelcome = "shownWelcome"
    }

    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()
    private let picker = PickerController()
    private let toast = ToastController()
    private let log = Logger(subsystem: "local.fileflipper.offline", category: "actions")

    private struct Job {
        let id = UUID()
        let item: PickerItem
        let urls: [URL]
        let endAccess: () -> Void
    }
    private var pending: [Job] = []
    private var activeID: UUID?
    private var activeTask: Task<Void, Never>?
    private var terminateWhenIdle = false
    private var observers: [NSObjectProtocol] = []
    private var completedFiles = 0
    private var failures: [String] = []
    private var cancelledTasks = 0
    private var progressText = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two running copies (e.g. one in Applications and one in a build folder) would each show a picker.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("Proteus is already running")
            alert.informativeText = L("Look for the ◎ icon in the menu bar at the top-right of your screen.")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        UserDefaults.standard.register(defaults: [Keys.enabled: true])

        setUpStatusItem()

        monitor.isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        monitor.onShow = { [weak self] point, urls, tools in
            self?.picker.show(at: point, urls: urls, tools: tools)
        }
        monitor.onModeChange = { [weak self] tools in
            self?.picker.setToolsMode(tools)
        }
        monitor.onEnd = { [weak self] in
            self?.picker.hide(afterDelay: 0.35)
        }
        picker.onPick = { [weak self] item, urls in
            self?.run(item, on: urls)
        }
        monitor.start()
        // Timers can stall across sleep, screen lock and user switching; start fresh afterwards.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.monitor.restart() }
            })
        }

        if !UserDefaults.standard.bool(forKey: Keys.shownWelcome) {
            UserDefaults.standard.set(true, forKey: Keys.shownWelcome)
            showHelp()
        }
    }

    // MARK: Running actions

    private func run(_ item: PickerItem, on urls: [URL]) {
        // Sandbox: we need permission to write into the folders holding these files.
        guard let endAccess = FolderAccess.shared.beginAccess(to: urls.map { $0.deletingLastPathComponent() }) else {
            log.error("No folder access for \(urls.first?.deletingLastPathComponent().path ?? "?", privacy: .public)")
            toast.show(L("Proteus needs folder access to save the converted file"), symbol: "lock.fill", duration: 4)
            return
        }

        pending.append(Job(item: item, urls: urls, endAccess: endAccess))
        if activeTask == nil { startNext() } else { showProgress() }
    }

    private func startNext() {
        guard !pending.isEmpty else { return }
        let job = pending.removeFirst()
        activeID = job.id
        progressText = L("%@: %@…", job.item.title, job.urls.count == 1 ? job.urls[0].lastPathComponent : L("%@ files", String(job.urls.count)))
        showProgress()
        let owner = self
        activeTask = Task.detached(priority: .userInitiated) {
            let result: Result<[URL], Error>
            do {
                let outputs = try await ConversionWork.progressContext.withValue({ message in
                    Task { @MainActor in
                        guard owner.activeID == job.id else { return }
                        owner.progressText = message
                        owner.showProgress()
                    }
                }) {
                    try ConversionWork.check()
                    return try await job.item.action(job.urls)
                }
                result = .success(outputs)
            } catch is CancellationError { result = .failure(ConversionError.cancelled) }
            catch { result = .failure(error) }
            await owner.complete(result, job: job)
        }
    }

    private func showProgress() {
        let queued = pending.isEmpty ? "" : L(" · %@ queued", String(pending.count))
        toast.show(progressText + queued, symbol: "hourglass", duration: nil)
    }

    private func complete(_ result: Result<[URL], Error>, job: Job) {
        job.endAccess()
        activeTask = nil
        activeID = nil
        switch result {
        case .success(let outputs): completedFiles += outputs.count
        case .failure(ConversionError.cancelled): cancelledTasks += 1
        case .failure(ConversionError.partial(let outputs, let message, let cancelled)):
            completedFiles += outputs.count
            if cancelled { cancelledTasks += 1 } else { failures.append(message) }
        case .failure(let error):
            failures.append(error.localizedDescription)
            log.error("Conversion failed: \(error.localizedDescription, privacy: .public)")
        }
        if terminateWhenIdle { NSApp.reply(toApplicationShouldTerminate: true); return }
        if !pending.isEmpty { startNext(); return }
        let summary = L("Saved %@ files", String(completedFiles))
        if let error = failures.first {
            toast.show(summary + " · " + error, symbol: "exclamationmark.circle", duration: 6)
        } else if cancelledTasks > 0 {
            toast.show(summary + " · " + L("Cancelled"), symbol: "xmark.circle", duration: 4)
        } else {
            toast.show(summary, symbol: "checkmark.circle.fill")
        }
        completedFiles = 0
        failures.removeAll()
        cancelledTasks = 0
    }

    @objc private func cancelCurrent() {
        activeTask?.cancel()
        progressText = L("Cancelling…")
        showProgress()
        if NSApp.modalWindow != nil { NSApp.abortModal() }
    }

    @objc private func clearQueue() {
        for job in pending { job.endAccess() }
        cancelledTasks += pending.count
        pending.removeAll()
        if activeTask != nil { showProgress() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        monitor.stop()
        picker.hide()
        clearQueue()
        guard activeTask != nil else { return .terminateNow }
        terminateWhenIdle = true
        cancelCurrent()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let menu = NSMenu()
        let items = Catalog.items(for: panel.urls, tools: false) + Catalog.items(for: panel.urls, tools: true)
        guard !items.isEmpty else {
            toast.show(L("Choose supported files of the same type"), symbol: "exclamationmark.circle")
            return
        }
        chosenURLs = panel.urls
        chosenItems = items
        for (index, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.title, action: #selector(chooseFormat(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.toolTip = item.detail
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    private var chosenURLs: [URL] = []
    private var chosenItems: [PickerItem] = []
    @objc private func chooseFormat(_ sender: NSMenuItem) {
        guard chosenItems.indices.contains(sender.tag) else { return }
        run(chosenItems[sender.tag], on: chosenURLs)
        chosenItems = []; chosenURLs = []
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Proteus")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let choose = NSMenuItem(title: L("Choose Files…"), action: #selector(chooseFiles), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)
        if activeTask != nil {
            let cancel = NSMenuItem(title: L("Cancel Current Conversion"), action: #selector(cancelCurrent), keyEquivalent: ".")
            cancel.target = self
            menu.addItem(cancel)
        }
        if !pending.isEmpty {
            let clear = NSMenuItem(title: L("Clear Queue (%@)", String(pending.count)), action: #selector(clearQueue), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        menu.addItem(.separator())
        let enabled = NSMenuItem(title: L("Enabled"), action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = monitor.isEnabled ? .on : .off
        menu.addItem(enabled)

        let login = NSMenuItem(title: L("Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if FolderAccess.isSandboxed {
            menu.addItem(.separator())
            let folders = FolderAccess.shared.grantedFolders
            let header = NSMenuItem(title: folders.isEmpty ? L("No Folder Access Yet") : L("Can Save In:"),
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for folder in folders {
                let entry = NSMenuItem(title: "  " + folder.path, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                menu.addItem(entry)
            }
            let grant = NSMenuItem(title: L("Allow Home Folder…"), action: #selector(grantHome), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
            if !folders.isEmpty {
                let reset = NSMenuItem(title: L("Reset Folder Access"), action: #selector(resetFolders), keyEquivalent: "")
                reset.target = self
                menu.addItem(reset)
            }
        }

        menu.addItem(.separator())

        let help = NSMenuItem(title: L("How to Use…"), action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)

        let about = NSMenuItem(title: L("About Proteus"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit Proteus"), action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() {
        monitor.isEnabled.toggle()
        UserDefaults.standard.set(monitor.isEnabled, forKey: Keys.enabled)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            toast.show(L("Launch at Login: %@", error.localizedDescription), symbol: "xmark.octagon.fill", duration: 4)
        }
    }

    @objc private func grantHome() {
        FolderAccess.shared.requestHomeAccess()
    }

    @objc private func resetFolders() {
        FolderAccess.shared.resetAll()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: L("Convert files right in Finder.\nOpen source under the MIT License.")),
        ])
    }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("How to use Proteus")
        var paragraphs = [
            L("Convert: drag a file in Finder and hold Shift. Drop it on a format in the ring. The converted copy is saved next to the original."),
            L("Tools: hold Option + Shift while dragging to see tools for that file type (crop, compress, cut out, rotate, merge, split…)."),
            L("Markdown: pick MD to turn Word, PDF, PowerPoint or Excel into Markdown, ready for AI."),
            L("To cancel, drop in the centre or outside the ring. You can also choose files and formats from the menu bar using the keyboard."),
            L("Everything happens locally on your Mac. Proteus lives in the menu bar."),
            L("For PDFs, DOCX preserves each page as an image. DOCX Text and RTF export editable text without original page layout or pictures."),
        ]
        if FolderAccess.isSandboxed {
            paragraphs.append(L("The first time you convert a file in a folder, macOS asks you to allow Proteus to save there. Choose “Allow Home Folder” to grant access once for all your folders."))
        }
        alert.informativeText = paragraphs.joined(separator: "\n\n")
        alert.addButton(withTitle: L("Got It"))
        if FolderAccess.isSandboxed && FolderAccess.shared.grantedFolders.isEmpty {
            alert.addButton(withTitle: L("Allow Home Folder…"))
        }
        if alert.runModal() == .alertSecondButtonReturn {
            FolderAccess.shared.requestHomeAccess()
        }
    }
}
