import AppKit
import SwiftUI

/// Remark's brand colors. Change them here and everything follows.
enum Theme {
    static let accentHex = "#8B5CF6"      // violet
    static let accentDeepHex = "#6D28D9"

    static let nsAccent = NSColor(srgbRed: 0x8B / 255.0, green: 0x5C / 255.0, blue: 0xF6 / 255.0, alpha: 1)
    static let nsAccentDeep = NSColor(srgbRed: 0x6D / 255.0, green: 0x28 / 255.0, blue: 0xD9 / 255.0, alpha: 1)

    static let accent = Color(nsColor: nsAccent)
    static let accentDeep = Color(nsColor: nsAccentDeep)
    static let accentSoft = Color(nsColor: nsAccent).opacity(0.12)

    static let gradient = LinearGradient(
        colors: [Color(red: 0xA7 / 255.0, green: 0x8B / 255.0, blue: 0xFA / 255.0), accentDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let listening = Color(red: 0.94, green: 0.27, blue: 0.33)
}
