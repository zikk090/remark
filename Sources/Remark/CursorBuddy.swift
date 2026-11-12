import AppKit
import SwiftUI

final class BuddyModel: ObservableObject {
    @Published var title: String = ""
    @Published var count: Int = 0
    @Published var listening: Bool = false
}

struct BuddyView: View {
    @ObservedObject var model: BuddyModel
    @State private var pulse = false

    private var color: Color {
        model.listening ? .red : Color(red: 1.0, green: 0.55, blue: 0.1)
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.25 : 0.85)
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .shadow(color: color.opacity(0.8), radius: 4)
            }
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.black.opacity(0.72)))
                .foregroundColor(.white)
        }
        .padding(3)
        .frame(width: 200, height: 28, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var label: String {
        if model.listening { return "Listening…" }
        let t = model.title.count > 18 ? String(model.title.prefix(17)) + "…" : model.title
        return "\(t) · \(model.count)"
    }
}

/// A small glowing companion that follows the cursor while a review session is active.
final class CursorBuddy {
    let model = BuddyModel()
    private let panel: NSPanel
    private var timer: Timer?
    private var lastPoint = NSPoint(x: -10_000, y: -10_000)

    var enabled = false { didSet { update() } }
    var suppressed = false { didSet { update() } }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 28),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: BuddyView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        panel.contentView = host
    }

    private func update() {
        if enabled && !suppressed {
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.follow() }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
            follow(force: true)
            panel.orderFrontRegardless()
        } else {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
        }
    }

    private func follow(force: Bool = false) {
        let m = NSEvent.mouseLocation
        if !force && m == lastPoint { return }
        lastPoint = m
        panel.setFrameOrigin(NSPoint(x: m.x + 14, y: m.y - 12 - panel.frame.height))
    }
}
