import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SessionStore()
    private let buddy = CursorBuddy()
    private let overlay = SelectionOverlay()
    private let prefs = Preferences()
    private let shortcuts = ShortcutStore()
    private lazy var recorder = ShortcutRecorder(store: shortcuts)
    private lazy var settings = SettingsWindowController(shortcuts: shortcuts, recorder: recorder, prefs: prefs)

    private var statusItem: NSStatusItem!
    private var noteController: NotePanelController?
    private var isSelecting = false

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

        shortcuts.onChange = { [weak self] in self?.registerHotkeys() }
        recorder.onBegin = { HotKeyCenter.shared.unregisterAll() }
        recorder.onEnd = { [weak self] in self?.registerHotkeys() }
        prefs.onChange = { [weak self] in self?.refreshBuddy() }
        registerHotkeys()

        store.onChange = { [weak self] in self?.refreshBuddy() }
        store.resumeLast()
        refreshBuddy()

        if !ScreenCapture.hasPermission {
            ScreenCapture.requestPermission()
        }
    }

    private func registerHotkeys() {
        HotKeyCenter.shared.unregisterAll()
        var failed = Set<HotkeyAction>()
        for action in HotkeyAction.allCases {
            guard let s = shortcuts.shortcut(for: action) else { continue }
            let ok = HotKeyCenter.shared.register(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in
                self?.perform(action)
            }
            if !ok { failed.insert(action) }
        }
        shortcuts.unavailable = failed
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .capture: beginCapture()
        case .captureText: beginTextNote()
        case .newSession: promptNewSession()
        case .toggleBuddy: prefs.buddyEnabled.toggle()
        }
    }

    // MARK: Screenshot notes

    private func beginCapture() {
        if let nc = noteController { nc.focus(); return }
        guard !isSelecting else { return }

        if !ScreenCapture.hasPermission && !confirmCaptureWithoutPermission() { return }

        let previousApp = NSWorkspace.shared.frontmostApplication
        let isSelf = previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier
        let sourceApp = isSelf ? nil : previousApp?.localizedName
        let windowTitle = isSelf ? nil : previousApp.flatMap { TextGrabber.focusedWindowTitle(pid: $0.processIdentifier) }

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
                let model = NoteViewModel(image: image, imageURL: url,
                                          sourceApp: sourceApp, windowTitle: windowTitle,
                                          sessionTitle: self.store.session?.title ?? "Review")
                self.presentNote(model, anchor: rect, previousApp: previousApp)
            }
        }
    }

    // MARK: Text-selection notes

    private func beginTextNote() {
        if let nc = noteController { nc.focus(); return }
        guard !isSelecting else { return }

        guard TextGrabber.isTrusted else {
            askForAccessibility()
            return
        }

        let previousApp = NSWorkspace.shared.frontmostApplication
        let isSelf = previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier
        let sourceApp = isSelf ? nil : previousApp?.localizedName
        let windowTitle = isSelf ? nil : previousApp.flatMap { TextGrabber.focusedWindowTitle(pid: $0.processIdentifier) }
        let mouse = NSEvent.mouseLocation

        TextGrabber.grabSelectedText { [weak self] text in
            guard let self else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let hint = self.shortcuts.shortcut(for: .captureText)?.display ?? "the shortcut"
                Toast.show("Highlight some text first, then press \(hint)")
                return
            }
            self.store.ensureSession()
            let model = NoteViewModel(image: nil, imageURL: nil,
                                      quote: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                      sourceApp: sourceApp, windowTitle: windowTitle,
                                      sessionTitle: self.store.session?.title ?? "Review")
            self.presentNote(model, anchor: CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1),
                             previousApp: previousApp)
        }
    }

    private func askForAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow Remark to read selected text"
        alert.informativeText = "To comment on highlighted text, turn on Remark in System Settings › Privacy & Security › Accessibility. Remark only reads the selection when you press the shortcut."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            TextGrabber.promptForTrust()
            TextGrabber.openSettings()
        }
    }

    // MARK: Note panel

    private func presentNote(_ model: NoteViewModel, anchor: CGRect, previousApp: NSRunningApplication?) {
        let controller = NotePanelController(model: model, anchor: anchor,
                                             autoListen: prefs.autoListen,
                                             autoExtract: prefs.autoExtractText)
        controller.onListeningChange = { [weak self] on in self?.buddy.model.listening = on }
        controller.onFinish = { [weak self] saved in
            guard let self else { return }
            if saved {
                self.store.add(kind: model.kind, text: model.text, imageURL: model.imageURL,
                               quote: model.quote, sourceApp: model.sourceApp, windowTitle: model.windowTitle)
            } else if let url = model.imageURL {
                try? FileManager.default.removeItem(at: url)
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
        buddy.model.count = store.session?.notes.count ?? 0
        if buddy.model.showCount != prefs.buddyShowCount { buddy.model.showCount = prefs.buddyShowCount }
        if buddy.model.shape != prefs.buddyShape { buddy.model.shape = prefs.buddyShape }
        if buddy.model.size != prefs.buddySize { buddy.model.size = prefs.buddySize }
        buddy.enabled = prefs.buddyEnabled && store.isActive
    }

    // MARK: Export

    private func export(_ format: ExportFormat) {
        guard let session = store.session else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Export “\(session.title)”"
        panel.nameFieldStringValue = "\(SessionStore.slug(session.title)).\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.export(format, store: store, to: url, pageSize: prefs.pageSize)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showAlert("Export failed", error.localizedDescription)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let headerTitle: String
        if let s = store.session {
            headerTitle = "\(s.title)  ·  \(s.notes.count) note\(s.notes.count == 1 ? "" : "s")"
        } else {
            headerTitle = "No active session"
        }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        item(menu, "Capture Area & Note", #selector(captureAction), shortcut: shortcuts.shortcut(for: .capture))
        item(menu, "Note on Selected Text", #selector(textNoteAction), shortcut: shortcuts.shortcut(for: .captureText))
        item(menu, "New Review Session…", #selector(newSessionAction), shortcut: shortcuts.shortcut(for: .newSession))

        menu.addItem(.separator())
        let active = store.isActive
        item(menu, "Open Report", #selector(openReport), enabled: active)
        item(menu, "Open Session Folder", #selector(openFolder), enabled: active)
        item(menu, "Copy Report as Markdown", #selector(copyMarkdown), enabled: active)

        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        exportItem.isEnabled = active
        let exportMenu = NSMenu()
        for format in ExportFormat.allCases {
            let mi = NSMenuItem(title: format.title + "…", action: #selector(exportAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = format.rawValue
            exportMenu.addItem(mi)
        }
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)

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
        let buddyItem = item(menu, "Show Cursor Buddy", #selector(toggleBuddyAction),
                             shortcut: shortcuts.shortcut(for: .toggleBuddy))
        buddyItem.state = prefs.buddyEnabled ? .on : .off
        let settingsItem = item(menu, "Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(.separator())
        let quitItem = item(menu, "Quit Remark", #selector(quit))
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = .command
    }

    @discardableResult
    private func item(_ menu: NSMenu, _ title: String, _ action: Selector,
                      shortcut: Shortcut? = nil, enabled: Bool = true) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: shortcut?.menuKeyEquivalent ?? "")
        if let shortcut { mi.keyEquivalentModifierMask = shortcut.menuModifiers }
        mi.target = self
        mi.isEnabled = enabled
        menu.addItem(mi)
        return mi
    }

    @objc private func captureAction() {
        // Let the menu close before the overlay appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.beginCapture() }
    }

    @objc private func textNoteAction() {
        // The menu steals focus; give it back to the app holding the selection first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.beginTextNote() }
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
        Toast.show("Report copied as Markdown")
    }

    @objc private func exportAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = ExportFormat(rawValue: raw) else { return }
        export(format)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if !store.open(folder: url) {
            showAlert("Couldn't open session", url.path)
        }
    }

    @objc private func endSession() { store.end() }
    @objc private func toggleBuddyAction() { prefs.buddyEnabled.toggle() }
    @objc private func openSettings() { settings.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
