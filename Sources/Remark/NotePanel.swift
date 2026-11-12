import AppKit
import SwiftUI

final class NoteViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var kind: NoteKind = .note
    @Published var isListening = false
    @Published var micError: String?

    let image: NSImage
    let sourceApp: String?
    let sessionTitle: String

    var toggleMic: () -> Void = {}
    var save: () -> Void = {}
    var cancel: () -> Void = {}

    init(image: NSImage, sourceApp: String?, sessionTitle: String) {
        self.image = image
        self.sourceApp = sourceApp
        self.sessionTitle = sessionTitle
    }
}

struct NoteView: View {
    @ObservedObject var model: NoteViewModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill").foregroundColor(.orange)
                Text(model.sessionTitle).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                if let app = model.sourceApp {
                    Text(app).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.top, 14)

            Image(nsImage: model.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 170)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

            Picker("", selection: $model.kind) {
                ForEach(NoteKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.text)
                    .font(.system(size: 13))
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(model.isListening ? Color.red.opacity(0.7) : Color.secondary.opacity(0.25),
                                lineWidth: model.isListening ? 2 : 1))
                if model.text.isEmpty {
                    Text(model.isListening ? "Listening… just talk" : "Type a note, or hit Talk and speak")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 110)

            if let err = model.micError {
                Text(err).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(action: model.toggleMic) {
                    Label(model.isListening ? "Stop" : "Talk",
                          systemImage: model.isListening ? "stop.circle.fill" : "mic.fill")
                }
                .tint(model.isListening ? .red : .orange)
                .buttonStyle(.bordered)

                Spacer()

                Button("Discard", action: model.cancel)
                Button("Save", action: model.save)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }

            Text("⌘↩ save   ·   ⌘D talk / stop   ·   Esc discard")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(width: 400)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { editorFocused = true }
        }
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class NotePanelController: NSObject, NSWindowDelegate {
    let model: NoteViewModel
    private let panel: KeyPanel
    private let dictation = Dictation()
    private let autoListen: Bool
    private var keyMonitor: Any?
    private var baseText = ""
    private var finished = false

    /// true = saved, false = discarded
    var onFinish: ((Bool) -> Void)?
    var onListeningChange: ((Bool) -> Void)?

    init(model: NoteViewModel, anchor: CGRect, autoListen: Bool) {
        self.model = model
        self.autoListen = autoListen
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 440),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let host = NSHostingView(rootView: NoteView(model: model))
        panel.contentView = host
        let size = host.fittingSize
        if size.width > 0 && size.height > 0 { panel.setContentSize(size) }
        position(near: anchor)

        model.toggleMic = { [weak self] in self?.toggleMic() }
        model.save = { [weak self] in self?.finish(saved: true) }
        model.cancel = { [weak self] in self?.finish(saved: false) }

        dictation.onText = { [weak self] transcript in
            guard let self else { return }
            self.model.text = self.baseText.isEmpty ? transcript : self.baseText + " " + transcript
        }
        dictation.onStateChange = { [weak self] running in
            self?.model.isListening = running
            self?.onListeningChange?(running)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        if autoListen { toggleMic() }
    }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = event.keyCode
            if code == 53 { // Esc
                self.finish(saved: false); return nil
            }
            if (code == 36 || code == 76) && mods.contains(.command) { // ⌘↩
                self.finish(saved: true); return nil
            }
            if code == 2 && mods == .command { // ⌘D
                self.toggleMic(); return nil
            }
            return event
        }
    }

    private func toggleMic() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        model.micError = nil
        Dictation.requestAccess { [weak self] error in
            guard let self, !self.finished else { return }
            if let error {
                self.model.micError = error
                return
            }
            self.baseText = self.model.text.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try self.dictation.start()
            } catch {
                self.model.micError = error.localizedDescription
            }
        }
    }

    private func finish(saved: Bool) {
        guard !finished else { return }
        finished = true
        dictation.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.delegate = nil
        panel.orderOut(nil)
        onFinish?(saved)
    }

    func windowWillClose(_ notification: Notification) {
        finish(saved: false)
    }

    private func position(near anchor: CGRect) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        let gap: CGFloat = 14

        var x = anchor.maxX + gap
        if x + size.width > visible.maxX {
            x = anchor.minX - gap - size.width
        }
        if x < visible.minX {
            // Selection is wide — dock to the right edge of the screen.
            x = visible.maxX - size.width - 20
        }
        var y = anchor.maxY - size.height
        y = min(max(y, visible.minY + 10), visible.maxY - size.height - 10)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
