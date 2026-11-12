import AppKit
import Carbon.HIToolbox

enum HotkeyAction: String, CaseIterable, Identifiable {
    case capture, captureText, newSession, toggleBuddy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: return "Capture area & note"
        case .captureText: return "Note on selected text"
        case .newSession: return "New review session"
        case .toggleBuddy: return "Show / hide cursor buddy"
        }
    }

    var defaultShortcut: Shortcut {
        let ctrlOpt = UInt32(controlKey | optionKey)
        switch self {
        case .capture: return Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: ctrlOpt, key: "R")
        case .captureText: return Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: ctrlOpt, key: "T")
        case .newSession: return Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: ctrlOpt, key: "N")
        case .toggleBuddy: return Shortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: ctrlOpt, key: "B")
        }
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask
    var key: String       // display name of the key, e.g. "R", "Space", "F5"

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    var menuKeyEquivalent: String { key.count == 1 ? key.lowercased() : "" }

    var menuModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    /// Builds a shortcut from a key press. Requires ⌃, ⌥ or ⌘ unless it's a function key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }

        let code = Int(event.keyCode)
        let isFunctionKey = Shortcut.functionKeys[code] != nil
        let hasStrongModifier = flags.contains(.control) || flags.contains(.option) || flags.contains(.command)
        guard hasStrongModifier || isFunctionKey else { return nil }

        let name: String
        if let special = Shortcut.functionKeys[code] ?? Shortcut.specialKeys[code] {
            name = special
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            name = chars.uppercased()
        } else {
            return nil
        }
        self.init(keyCode: UInt32(code), modifiers: carbon, key: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19"
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟"
    ]
}

final class ShortcutStore: ObservableObject {
    @Published private(set) var shortcuts: [HotkeyAction: Shortcut] = [:]
    /// Actions whose shortcut macOS refused (taken by another app).
    @Published var unavailable: Set<HotkeyAction> = []
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    init() {
        for action in HotkeyAction.allCases {
            if defaults.bool(forKey: disabledKey(action)) { continue }
            if let data = defaults.data(forKey: key(action)),
               let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
                shortcuts[action] = s
            } else {
                shortcuts[action] = action.defaultShortcut
            }
        }
    }

    func shortcut(for action: HotkeyAction) -> Shortcut? { shortcuts[action] }

    func set(_ shortcut: Shortcut?, for action: HotkeyAction) {
        if let shortcut {
            shortcuts[action] = shortcut
            defaults.set(try? JSONEncoder().encode(shortcut), forKey: key(action))
            defaults.set(false, forKey: disabledKey(action))
        } else {
            shortcuts[action] = nil
            defaults.removeObject(forKey: key(action))
            defaults.set(true, forKey: disabledKey(action))
        }
        onChange?()
    }

    func resetAll() {
        for action in HotkeyAction.allCases {
            defaults.removeObject(forKey: key(action))
            defaults.removeObject(forKey: disabledKey(action))
            shortcuts[action] = action.defaultShortcut
        }
        onChange?()
    }

    func conflict(with shortcut: Shortcut, excluding action: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first { other in
            guard other != action, let s = shortcuts[other] else { return false }
            return s.keyCode == shortcut.keyCode && s.modifiers == shortcut.modifiers
        }
    }

    private func key(_ a: HotkeyAction) -> String { "shortcut.\(a.rawValue)" }
    private func disabledKey(_ a: HotkeyAction) -> String { "shortcut.\(a.rawValue).disabled" }
}

/// Drives the "click, then press keys" shortcut recorder in Settings.
final class ShortcutRecorder: ObservableObject {
    @Published var recording: HotkeyAction?
    @Published var message: String?

    private let store: ShortcutStore
    private var monitor: Any?
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}

    init(store: ShortcutStore) { self.store = store }

    func toggle(_ action: HotkeyAction) {
        if recording == action { stop(); return }
        stop()
        recording = action
        message = "Press the new shortcut. Esc cancels, ⌫ clears."
        onBegin() // pause global hotkeys so the combo reaches us
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard let action = recording else { return }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if flags.isEmpty && event.keyCode == UInt16(kVK_Escape) { stop(); return }
        if flags.isEmpty && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) {
            store.set(nil, for: action)
            stop()
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            message = "Include ⌃, ⌥ or ⌘ (or use an F-key)."
            NSSound.beep()
            return
        }
        if let other = store.conflict(with: shortcut, excluding: action) {
            message = "\(shortcut.display) is already used for “\(other.title)”."
            NSSound.beep()
            return
        }
        store.set(shortcut, for: action)
        stop()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let wasRecording = recording != nil
        recording = nil
        message = nil
        if wasRecording { onEnd() }
    }
}
