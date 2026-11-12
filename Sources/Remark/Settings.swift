import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import Speech
import SwiftUI

enum PageSize: String, CaseIterable, Identifiable {
    case a4, letter
    var id: String { rawValue }
    var label: String { self == .a4 ? "A4" : "US Letter" }
    var rect: CGRect { self == .a4 ? CGRect(x: 0, y: 0, width: 595, height: 842)
                                   : CGRect(x: 0, y: 0, width: 612, height: 792) }
}

final class Preferences: ObservableObject {
    private let d = UserDefaults.standard
    var onChange: (() -> Void)?

    @Published var buddyEnabled: Bool { didSet { d.set(buddyEnabled, forKey: "buddyEnabled"); onChange?() } }
    @Published var buddyShowCount: Bool { didSet { d.set(buddyShowCount, forKey: "buddyShowCount"); onChange?() } }
    @Published var buddyShape: BuddyShape { didSet { d.set(buddyShape.rawValue, forKey: "buddyShape"); onChange?() } }
    @Published var buddySize: BuddySize { didSet { d.set(buddySize.rawValue, forKey: "buddySize"); onChange?() } }
    @Published var autoListen: Bool { didSet { d.set(autoListen, forKey: "autoListen"); onChange?() } }
    @Published var autoExtractText: Bool { didSet { d.set(autoExtractText, forKey: "autoExtractText"); onChange?() } }
    @Published var pageSize: PageSize { didSet { d.set(pageSize.rawValue, forKey: "pageSize"); onChange?() } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Remark: launch at login change failed: \(error)")
            }
        }
    }

    init() {
        buddyEnabled = d.object(forKey: "buddyEnabled") as? Bool ?? true
        buddyShowCount = d.object(forKey: "buddyShowCount") as? Bool ?? true
        buddyShape = BuddyShape(rawValue: d.string(forKey: "buddyShape") ?? "") ?? .bubble
        buddySize = BuddySize(rawValue: d.string(forKey: "buddySize") ?? "") ?? .medium
        autoListen = d.bool(forKey: "autoListen")
        autoExtractText = d.bool(forKey: "autoExtractText")
        pageSize = PageSize(rawValue: d.string(forKey: "pageSize") ?? "") ?? .a4
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Layout

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcuts, cursor, export, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .cursor: return "Cursor"
        case .export: return "Export"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .cursor: return "cursorarrow.rays"
        case .export: return "square.and.arrow.up.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var shortcuts: ShortcutStore
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var prefs: Preferences
    @State private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(pane.title)
                        .font(.system(size: 22, weight: .bold))
                        .padding(.bottom, 2)
                    content
                }
                .padding(.horizontal, 28)
                .padding(.top, 34)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 720, height: 500)
        .tint(Theme.accent)
        .onChange(of: pane) { _ in recorder.stop() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Remark").font(.system(size: 15, weight: .bold))
                    Text("v\(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 40)
            .padding(.bottom, 16)

            ForEach(SettingsPane.allCases) { p in
                Button { pane = p } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(pane == p ? .white : Theme.accent)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(pane == p ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.accentSoft)))
                        Text(p.title)
                            .font(.system(size: 13, weight: pane == p ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(pane == p ? Theme.accentSoft : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 200)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general: GeneralPane(prefs: prefs)
        case .shortcuts: ShortcutsPane(shortcuts: shortcuts, recorder: recorder)
        case .cursor: CursorPane(prefs: prefs)
        case .export: ExportPane(prefs: prefs)
        case .permissions: PermissionsPane()
        case .about: AboutPane()
        }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    static let repoURL = URL(string: "https://github.com/zikk090/remark")!
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.6)
            .padding(.leading, 4)
            .padding(.bottom, -10)
    }
}

/// Renders "⌃⌥R" as individual key caps.
struct KeyCaps: View {
    let shortcut: Shortcut?
    let recording: Bool

    var body: some View {
        HStack(spacing: 4) {
            if recording {
                Text("Type shortcut…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            } else if let shortcut {
                ForEach(Array(caps(shortcut).enumerated()), id: \.offset) { _, cap in
                    Text(cap)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(minWidth: 22, minHeight: 22)
                        .padding(.horizontal, cap.count > 1 ? 6 : 0)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
                }
            } else {
                Text("Not set")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
        }
    }

    private func caps(_ s: Shortcut) -> [String] {
        var out: [String] = []
        let m = s.modifiers
        if m & UInt32(controlKey) != 0 { out.append("⌃") }
        if m & UInt32(optionKey) != 0 { out.append("⌥") }
        if m & UInt32(shiftKey) != 0 { out.append("⇧") }
        if m & UInt32(cmdKey) != 0 { out.append("⌘") }
        out.append(s.key)
        return out
    }
}

// MARK: - Panes

struct GeneralPane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        SectionLabel("Notes")
        Card {
            Row(title: "Start talking when a note opens",
                subtitle: "Dictation starts right away; type to add to it.") {
                Toggle("", isOn: $prefs.autoListen).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            Row(title: "Pull text out of every screenshot",
                subtitle: "Runs on-device OCR and attaches the text to the note.") {
                Toggle("", isOn: $prefs.autoExtractText).labelsHidden().toggleStyle(.switch)
            }
        }

        SectionLabel("App")
        Card {
            Row(title: "Open Remark at login") {
                Toggle("", isOn: $prefs.launchAtLogin).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            Row(title: "Sessions folder", subtitle: SessionStore.rootURL.path(percentEncoded: false)) {
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: SessionStore.rootURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(SessionStore.rootURL)
                }
            }
        }
    }
}

struct ShortcutsPane: View {
    @ObservedObject var shortcuts: ShortcutStore
    @ObservedObject var recorder: ShortcutRecorder

    var body: some View {
        Text("Click a shortcut, then press the keys you want. Esc cancels, ⌫ clears.")
            .font(.callout)
            .foregroundStyle(.secondary)

        Card {
            ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { RowDivider() }
                Row(title: action.title, subtitle: warning(for: action)) {
                    Button { recorder.toggle(action) } label: {
                        KeyCaps(shortcut: shortcuts.shortcut(for: action), recording: recorder.recording == action)
                    }
                    .buttonStyle(.plain)
                    .help("Click to record a new shortcut")
                }
            }
        }

        if let msg = recorder.message {
            Label(msg, systemImage: "keyboard")
                .font(.callout)
                .foregroundColor(Theme.accent)
        }

        HStack {
            Spacer()
            Button("Restore Defaults") {
                recorder.stop()
                shortcuts.resetAll()
            }
        }
    }

    private func warning(for action: HotkeyAction) -> String? {
        shortcuts.unavailable.contains(action) ? "⚠︎ Another app is using this combo. Pick a different one." : nil
    }
}

struct CursorPane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Text("During a review session, a small purple marker follows your cursor and shows how many notes you've taken. It turns red while you're talking.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Card {
            Row(title: "Show cursor buddy during a session",
                subtitle: "Toggle it any time with your shortcut.") {
                Toggle("", isOn: $prefs.buddyEnabled).labelsHidden().toggleStyle(.switch)
            }
        }

        SectionLabel("Shape")
        HStack(spacing: 10) {
            ForEach(BuddyShape.allCases) { shape in
                ShapeTile(shape: shape, prefs: prefs)
            }
        }
        .opacity(prefs.buddyEnabled ? 1 : 0.4)
        .disabled(!prefs.buddyEnabled)

        Card {
            Row(title: "Show note count") {
                Toggle("", isOn: $prefs.buddyShowCount).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            Row(title: "Size") {
                Picker("", selection: $prefs.buddySize) {
                    ForEach(BuddySize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
        .disabled(!prefs.buddyEnabled)
    }
}

struct ShapeTile: View {
    let shape: BuddyShape
    @ObservedObject var prefs: Preferences
    @State private var hovering = false

    private var selected: Bool { prefs.buddyShape == shape }

    var body: some View {
        Button { prefs.buddyShape = shape } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 17))
                        .foregroundColor(.primary)
                    BuddyGraphic(shape: shape, scale: prefs.buddySize.scale * 0.9,
                                 listening: hovering, count: 7, showCount: prefs.buddyShowCount)
                        .offset(x: 14, y: 17)
                }
                .frame(width: 90, height: 58, alignment: .topLeading)
                .padding(.leading, 18)

                Text(shape.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Theme.accent : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Hover to preview the talking state")
    }
}

struct ExportPane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Text("Export any session from the menu bar → Export.")
            .font(.callout)
            .foregroundStyle(.secondary)

        SectionLabel("PDF")
        Card {
            Row(title: "Page size") {
                Picker("", selection: $prefs.pageSize) {
                    ForEach(PageSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
        }

        SectionLabel("Formats")
        Card {
            ForEach(Array(ExportFormat.allCases.enumerated()), id: \.element) { index, format in
                if index > 0 { RowDivider() }
                Row(title: format.title, subtitle: format.summary) {
                    Text(".\(format.fileExtension)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accentSoft))
                }
            }
        }
    }
}

struct PermissionsPane: View {
    @State private var tick = 0

    var body: some View {
        let _ = tick
        Text("Remark only uses these when you press a shortcut. Nothing leaves your Mac.")
            .font(.callout)
            .foregroundStyle(.secondary)

        Card {
            row("Screen Recording", "Screenshot notes. Reopen Remark after granting.",
                symbol: "rectangle.dashed", granted: CGPreflightScreenCaptureAccess(), anchor: "Privacy_ScreenCapture")
            RowDivider()
            row("Accessibility", "Reading highlighted text for text notes.",
                symbol: "text.cursor", granted: AXIsProcessTrusted(), anchor: "Privacy_Accessibility")
            RowDivider()
            row("Microphone", "Talking your notes.",
                symbol: "mic.fill", granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                anchor: "Privacy_Microphone")
            RowDivider()
            row("Speech Recognition", "Turning speech into text, on-device when supported.",
                symbol: "waveform", granted: SFSpeechRecognizer.authorizationStatus() == .authorized,
                anchor: "Privacy_SpeechRecognition")
        }

        HStack {
            Spacer()
            Button("Refresh") { tick += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick += 1 }
    }

    private func row(_ title: String, _ detail: String, symbol: String, granted: Bool, anchor: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.green)
            } else {
                Button("Allow…") {
                    if anchor == "Privacy_Accessibility" { TextGrabber.promptForTrust() }
                    if anchor == "Privacy_ScreenCapture" { ScreenCapture.requestPermission() }
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

struct AboutPane: View {
    var body: some View {
        Card {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remark").font(.system(size: 20, weight: .bold))
                    Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
                    Text("Select anything on your screen, talk or type a note, and send a clean report. No shared docs or edit access needed.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .padding(18)
        }

        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(AppInfo.repoURL)
            } label: {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(.borderedProminent)

            Button {
                NSWorkspace.shared.open(AppInfo.repoURL.appendingPathComponent("issues"))
            } label: {
                Label("Report an issue", systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.bordered)
        }

        Text("Made by Ezinne Kalu.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let shortcuts: ShortcutStore
    private let recorder: ShortcutRecorder
    private let prefs: Preferences

    init(shortcuts: ShortcutStore, recorder: ShortcutRecorder, prefs: Preferences) {
        self.shortcuts = shortcuts
        self.recorder = recorder
        self.prefs = prefs
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(shortcuts: shortcuts, recorder: recorder, prefs: prefs))
            let w = NSWindow(contentViewController: host)
            w.title = "Remark Settings"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stop()
    }
}
