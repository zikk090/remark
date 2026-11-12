import AppKit
import SwiftUI

final class NoteViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var kind: NoteKind = .note
    @Published var quote: String
    @Published var isListening = false
    @Published var isExtracting = false
    @Published var message: String?

    let image: NSImage?
    let imageURL: URL?
    let sourceApp: String?
    let windowTitle: String?
    let sessionTitle: String

    var toggleMic: () -> Void = {}
    var extractText: () -> Void = {}
    var save: () -> Void = {}
    var cancel: () -> Void = {}

    var isTextNote: Bool { image == nil }

    var context: String? {
        let parts = [sourceApp, windowTitle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    init(image: NSImage?, imageURL: URL?, quote: String = "",
         sourceApp: String?, windowTitle: String?, sessionTitle: String) {
        self.image = image
        self.imageURL = imageURL
        self.quote = quote
        self.sourceApp = sourceApp
        self.windowTitle = windowTitle
        self.sessionTitle = sessionTitle
    }
}

struct NoteView: View {
    @ObservedObject var model: NoteViewModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: model.isTextNote ? "text.quote" : "text.bubble.fill").foregroundColor(Theme.accent)
                Text(model.sessionTitle).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                if let ctx = model.context {
                    Text(ctx).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.top, 14)

            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            }

            if !model.quote.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.isTextNote ? "Selected text" : "Text in screenshot")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if !model.isTextNote {
                            Button("Remove") { model.quote = "" }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                    Text(model.quote)
                        .font(.system(size: 12))
                        .lineLimit(model.isTextNote ? 10 : 6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.leading, 10)
                        .padding(.trailing, 6)
                        .background(Theme.accentSoft)
                        .overlay(Rectangle().fill(Theme.accent).frame(width: 3), alignment: .leading)
                }
            }

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
            .frame(height: 100)

            if let msg = model.message {
                Text(msg).font(.caption).foregroundColor(Theme.accent).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: model.toggleMic) {
                    Label(model.isListening ? "Stop" : "Talk",
                          systemImage: model.isListening ? "stop.circle.fill" : "mic.fill")
                }
                .tint(model.isListening ? Theme.listening : Theme.accent)
                .buttonStyle(.bordered)

                if !model.isTextNote {
                    Button(action: model.extractText) {
                        if model.isExtracting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Text", systemImage: "text.viewfinder")
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Pull the text out of this screenshot (⌘E)")
                    .disabled(model.isExtracting)
                }

                Spacer()

                Button("Discard", action: model.cancel)
                Button("Save", action: model.save)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }

            Text(model.isTextNote ? "⌘↩ save  ·  ⌘D talk  ·  Esc discard"
                                  : "⌘↩ save  ·  ⌘D talk  ·  ⌘E grab text  ·  Esc discard")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(width: 420)
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
    private let host: NSHostingView<NoteView>
    private let dictation = Dictation()
    private let autoListen: Bool
    private let autoExtract: Bool
    private var keyMonitor: Any?
    private var baseText = ""
    private var finished = false

    /// true = saved, false = discarded
    var onFinish: ((Bool) -> Void)?
    var onListeningChange: ((Bool) -> Void)?

    init(model: NoteViewModel, anchor: CGRect, autoListen: Bool, autoExtract: Bool) {
        self.model = model
        self.autoListen = autoListen
        self.autoExtract = autoExtract
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        host = NSHostingView(rootView: NoteView(model: model))
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = host
        let size = host.fittingSize
        if size.width > 0 && size.height > 0 { panel.setContentSize(size) }
        position(near: anchor)

        model.toggleMic = { [weak self] in self?.toggleMic() }
        model.extractText = { [weak self] in self?.extractText() }
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
        if autoExtract && !model.isTextNote { extractText() }
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
            if code == 14 && mods == .command && !self.model.isTextNote { // ⌘E
                self.extractText(); return nil
            }
            return event
        }
    }

    private func extractText() {
        guard let url = model.imageURL, !model.isExtracting else { return }
        model.isExtracting = true
        model.message = nil
        OCR.recognize(url: url) { [weak self] text in
            guard let self, !self.finished else { return }
            self.model.isExtracting = false
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                self.model.message = "No text found in this capture."
            } else {
                self.model.quote = clean
            }
            self.refit()
        }
    }

    private func toggleMic() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        model.message = nil
        Dictation.requestAccess { [weak self] error in
            guard let self, !self.finished else { return }
            if let error {
                self.model.message = error
                self.refit()
                return
            }
            self.baseText = self.model.text.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try self.dictation.start()
            } catch {
                self.model.message = error.localizedDescription
                self.refit()
            }
        }
    }

    /// Resize to fit new content while keeping the top edge in place.
    private func refit() {
        DispatchQueue.main.async {
            let size = self.host.fittingSize
            guard size.height > 0 else { return }
            var frame = self.panel.frame
            let top = frame.maxY
            let newFrame = self.panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.size = newFrame.size
            frame.origin.y = top - frame.height
            if let visible = self.panel.screen?.visibleFrame, frame.minY < visible.minY {
                frame.origin.y = visible.minY + 10
            }
            self.panel.setFrame(frame, display: true, animate: true)
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
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor.insetBy(dx: -1, dy: -1)) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        let gap: CGFloat = 14

        var x = anchor.maxX + gap
        if x + size.width > visible.maxX {
            x = anchor.minX - gap - size.width
        }
        if x < visible.minX {
            x = visible.maxX - size.width - 20
        }
        var y = anchor.maxY - size.height
        y = min(max(y, visible.minY + 10), visible.maxY - size.height - 10)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
