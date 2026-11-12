import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SessionStore()
    private let buddy = CursorBuddy()
    private let overlay = SelectionOverlay()
    private var statusItem: NSStatusItem!
    private var noteController: NotePanelController?
    private var isSelecting = false

    private var buddyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "buddyEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "buddyEnabled") }
    }

    private var autoListen: Bool {
        get { UserDefaults.standard.bool(forKey: "autoListen") }
        set { UserDefaults.standard.set(newValue, forKey: "autoListen") }
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "Remark")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        let mods = controlKey | optionKey
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in self?.beginCapture() }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_N, modifiers: mods) { [weak self] in self?.promptNewSession() }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_B, modifiers: mods) { [weak self] in self?.toggleBuddy() }

        store.onChange = { [weak self] in self?.refreshBuddy() }
        store.resumeLast()
        refreshBuddy()

        if !ScreenCapture.hasPermission {
            ScreenCapture.requestPermission()
        }
    }

    // MARK: Capture flow

    private func beginCapture() {
        if let nc = noteController { nc.focus(); return }
        guard !isSelecting else { return }

        if !ScreenCapture.hasPermission && !confirmCaptureWithoutPermission() { return }

        let previousApp = NSWorkspace.shared.frontmostApplication
        let sourceApp = previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : previousApp?.localizedName

        isSelecting = true
        buddy.suppressed = true

        overlay.begin { [weak self] rect in
            guard let self else { return }
            guard let rect else {
                self.isSelecting = false
                self.buddy.suppressed = false
                previousApp?.activate(options: [])
                return
            }
            // Give the window server a moment to remove the overlay before grabbing pixels.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let url = self.store.nextImageURL()
                let ok = ScreenCapture.capture(rect: rect, to: url)
                self.isSelecting = false
                self.buddy.suppressed = false
                guard ok, let image = NSImage(contentsOf: url) else {
                    self.showAlert("Couldn't capture that area",
                                   "Make sure Remark has Screen Recording permission in System Settings › Privacy & Security.")
                    return
                }
                self.showNote(image: image, imageURL: url, anchor: rect,
                              sourceApp: sourceApp, previousApp: previousApp)
            }
        }
    }

    private func showNote(image: NSImage, imageURL: URL, anchor: CGRect,
                          sourceApp: String?, previousApp: NSRunningApplication?) {
        let model = NoteViewModel(image: image, sourceApp: sourceApp,
                                  sessionTitle: store.session?.title ?? "Review")
        let controller = NotePanelController(model: model, anchor: anchor, autoListen: autoListen)
        controller.onListeningChange = { [weak self] on in self?.buddy.model.listening = on }
        controller.onFinish = { [weak self] saved in
            guard let self else { return }
            if saved {
                self.store.add(kind: model.kind, text: model.text, imageURL: imageURL, sourceApp: sourceApp)
            } else {
                try? FileManager.default.removeItem(at: imageURL)
            }
            self.buddy.model.listening = false
            self.noteController = nil
            if previousApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp?.activate(options: [])
            }
        }
        noteController = controller
        controller.show()
    }

    private func confirmCaptureWithoutPermission() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remark needs Screen Recording permission"
        alert.informativeText = "Turn on Remark in System Settings › Privacy & Security › Screen Recording, then quit and reopen Remark. Without it, captures only show your wallpaper."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Capture Anyway")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ScreenCapture.requestPermission()
            ScreenCapture.openSettings()
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Sessions

    private func promptNewSession() {
        guard noteController == nil, !isSelecting else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "New review session"
        alert.informativeText = "What are you reviewing? e.g. “Ada’s app — onboarding” or “Acme web app — auth flows”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Session name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            store.start(title: field.stringValue)
        }
    }

    private func refreshBuddy() {
        buddy.model.title = store.session?.title ?? ""
        buddy.model.count = store.session?.notes.count ?? 0
        buddy.enabled = buddyEnabled && store.isActive
    }

    private func toggleBuddy() {
        buddyEnabled.toggle()
        refreshBuddy()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]

        if let s = store.session {
            let header = NSMenuItem(title: "\(s.title)  ·  \(s.notes.count) note\(s.notes.count == 1 ? "" : "s")",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        } else {
            let header = NSMenuItem(title: "No active session", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        menu.addItem(.separator())

        item(menu, "Capture & Note", #selector(captureAction), key: "r", mods: ctrlOpt)
        item(menu, "New Review Session…", #selector(newSessionAction), key: "n", mods: ctrlOpt)

        menu.addItem(.separator())
        let active = store.isActive
        item(menu, "Open Report", #selector(openReport), enabled: active)
        item(menu, "Open Session Folder", #selector(openFolder), enabled: active)
        item(menu, "Copy Report as Markdown", #selector(copyMarkdown), enabled: active)
        item(menu, "Export Shareable HTML", #selector(exportShareable), enabled: active)

        let recentItem = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let recents = SessionStore.recentSessions()
        if recents.isEmpty {
            let none = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            recentMenu.addItem(none)
        }
        for r in recents {
            let mi = NSMenuItem(title: "\(r.title)  (\(r.count))", action: #selector(openRecent(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = r.url
            mi.state = (r.url.standardizedFileURL == store.folder?.standardizedFileURL) ? .on : .off
            recentMenu.addItem(mi)
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        item(menu, "End Session", #selector(endSession), enabled: active)

        menu.addItem(.separator())
        item(menu, "Show Cursor Buddy", #selector(toggleBuddyAction), key: "b", mods: ctrlOpt, state: buddyEnabled)
        item(menu, "Start Talking Automatically", #selector(toggleAutoListen), state: autoListen)
        item(menu, "Screen Recording Settings…", #selector(openScreenSettings))
        menu.addItem(.separator())
        item(menu, "Quit Remark", #selector(quit), key: "q", mods: .command)
    }

    @discardableResult
    private func item(_ menu: NSMenu, _ title: String, _ action: Selector,
                      key: String = "", mods: NSEvent.ModifierFlags = [],
                      state: Bool? = nil, enabled: Bool = true) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mods
        mi.target = self
        mi.isEnabled = enabled
        if let state { mi.state = state ? .on : .off }
        menu.addItem(mi)
        return mi
    }

    @objc private func captureAction() {
        // Let the menu close before the overlay appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.beginCapture() }
    }

    @objc private func newSessionAction() { promptNewSession() }

    @objc private func openReport() {
        store.save()
        if let url = store.reportHTMLURL { NSWorkspace.shared.open(url) }
    }

    @objc private func openFolder() {
        if let url = store.folder { NSWorkspace.shared.open(url) }
    }

    @objc private func copyMarkdown() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(store.markdown(), forType: .string)
    }

    @objc private func exportShareable() {
        guard let url = store.exportShareable() else {
            showAlert("Export failed", "Couldn't write the shareable HTML file.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if !store.open(folder: url) {
            showAlert("Couldn't open session", url.path)
        }
    }

    @objc private func endSession() { store.end() }
    @objc private func toggleBuddyAction() { toggleBuddy() }
    @objc private func toggleAutoListen() { autoListen.toggle() }
    @objc private func openScreenSettings() { ScreenCapture.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
