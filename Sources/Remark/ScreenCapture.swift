import AppKit

enum ScreenCapture {
    /// `rect` is in Cocoa global coordinates (origin at bottom-left of the primary screen).
    static func capture(rect: CGRect, to url: URL) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let topY = primaryHeight - rect.maxY
        let region = [rect.minX, topY, rect.width, rect.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x: no sound, -R: region, -t png
        process.arguments = ["-x", "-t", "png", "-R", region, url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Remark: screencapture failed: \(error)")
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
