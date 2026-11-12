import AppKit
import SwiftUI

enum BuddySize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1.0
        case .large: return 1.25
        }
    }
}

enum BuddyShape: String, CaseIterable, Identifiable {
    case dot, bubble, diamond, pointer
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

final class BuddyModel: ObservableObject {
    @Published var count: Int = 0
    @Published var listening: Bool = false
    @Published var showCount: Bool = true
    @Published var size: BuddySize = .medium
    @Published var shape: BuddyShape = .bubble
}

/// A small arrowhead pointer, tip at the top-left corner of its frame.
struct PointerShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))                          // tip
        p.addLine(to: CGPoint(x: r.minX + w, y: r.minY + h * 0.58))         // right wing
        p.addLine(to: CGPoint(x: r.minX + w * 0.52, y: r.minY + h * 0.66))  // notch
        p.addLine(to: CGPoint(x: r.minX + w * 0.30, y: r.minY + h))         // left wing
        p.closeSubpath()
        return p
    }
}

/// The companion marker plus an optional note-count pill.
/// The marker's top-left sits at the top-left of the view.
struct BuddyGraphic: View {
    var shape: BuddyShape = .dot
    let scale: CGFloat
    let listening: Bool
    let count: Int
    let showCount: Bool

    private var top: Color { listening ? Color(red: 1.0, green: 0.45, blue: 0.5) : Color(red: 0.70, green: 0.58, blue: 1.0) }
    private var bottom: Color { listening ? Theme.listening : Theme.accentDeep }
    private var fill: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing) }

    var body: some View {
        Group {
            if shape == .bubble {
                bubble
            } else {
                HStack(alignment: .top, spacing: 4 * scale) {
                    marker
                    if showCount || listening {
                        pill.offset(y: pillDrop).transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .fixedSize()
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: count)
        .animation(.easeInOut(duration: 0.2), value: listening)
    }

    private var pillDrop: CGFloat {
        switch shape {
        case .pointer: return 12 * scale
        default: return 6 * scale
        }
    }

    @ViewBuilder private var marker: some View {
        switch shape {
        case .dot, .bubble:
            Circle()
                .fill(fill)
                .overlay(Circle().stroke(Color.white, lineWidth: 2 * scale))
                .frame(width: 13 * scale, height: 13 * scale)
                .shadow(color: bottom.opacity(0.6), radius: 4 * scale, x: 0, y: 1)
        case .diamond:
            RoundedRectangle(cornerRadius: 2.5 * scale)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 2.5 * scale).stroke(Color.white, lineWidth: 2 * scale))
                .frame(width: 11 * scale, height: 11 * scale)
                .rotationEffect(.degrees(45))
                .frame(width: 16 * scale, height: 16 * scale)
                .shadow(color: bottom.opacity(0.6), radius: 4 * scale, x: 0, y: 1)
        case .pointer:
            PointerShape()
                .fill(fill)
                .overlay(PointerShape().stroke(Color.white, style: StrokeStyle(lineWidth: 1.6 * scale, lineJoin: .round)))
                .frame(width: 17 * scale, height: 20 * scale)
                .shadow(color: bottom.opacity(0.55), radius: 4 * scale, x: 0, y: 1)
        }
    }

    private var label: some View {
        Group {
            if listening {
                Image(systemName: "mic.fill").font(.system(size: 9 * scale, weight: .bold))
            } else {
                Text("\(count)")
                    .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundColor(.white)
    }

    private var pill: some View {
        label
            .padding(.horizontal, 6 * scale)
            .frame(minWidth: 20 * scale, minHeight: 18 * scale)
            .background(Capsule().fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1.2 * scale))
            .shadow(color: bottom.opacity(0.45), radius: 3 * scale, x: 0, y: 1)
    }

    /// Count inside a single round badge; shrinks to a dot when the count is hidden.
    @ViewBuilder private var bubble: some View {
        if showCount || listening {
            label
                .padding(.horizontal, 5 * scale)
                .frame(minWidth: 24 * scale, minHeight: 24 * scale)
                .background(Capsule().fill(fill))
                .overlay(Capsule().stroke(Color.white, lineWidth: 2 * scale))
                .shadow(color: bottom.opacity(0.55), radius: 4 * scale, x: 0, y: 1)
        } else {
            marker
        }
    }
}

struct BuddyView: View {
    @ObservedObject var model: BuddyModel
    static let canvas = CGSize(width: 140, height: 80)

    var body: some View {
        BuddyGraphic(shape: model.shape, scale: model.size.scale, listening: model.listening,
                     count: model.count, showCount: model.showCount)
            .padding(.leading, 6)   // room for the shadow
            .padding(.top, 6)
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

/// Click-through companion that trails the cursor while a review session is active.
final class CursorBuddy {
    let model = BuddyModel()
    private let panel: NSPanel
    private var timer: Timer?
    private var position: CGPoint?   // where the buddy's tip currently is (screen coords)

    /// Offset of the buddy's tip from the real cursor's tip.
    /// Sits to the right of the arrow, vertically level with its upper half.
    private let offset = CGVector(dx: 22, dy: 6)
    private let inset = CGPoint(x: 6, y: 6) // matches BuddyView padding

    var enabled = false { didSet { update() } }
    var suppressed = false { didSet { update() } }

    init() {
        let size = BuddyView.canvas
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    private func update() {
        if enabled && !suppressed {
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
            position = nil // snap to the cursor when (re)appearing
            tick()
            panel.orderFrontRegardless()
        } else {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
        }
    }

    private func tick() {
        let m = NSEvent.mouseLocation
        let target = CGPoint(x: m.x + offset.dx, y: m.y + offset.dy)
        guard var p = position else {
            position = target
            place(target)
            return
        }
        let dx = target.x - p.x, dy = target.y - p.y
        if abs(dx) < 0.3 && abs(dy) < 0.3 { return }
        // Ease toward the cursor so it trails slightly, like a companion.
        let k: CGFloat = 0.32
        p.x += dx * k
        p.y += dy * k
        if hypot(dx, dy) > 600 { p = target } // jumped across screens: don't fly the whole way
        position = p
        place(p)
    }

    private func place(_ tip: CGPoint) {
        // Panel origin is bottom-left; the tip sits `inset` from the panel's top-left.
        panel.setFrameOrigin(NSPoint(x: tip.x - inset.x,
                                     y: tip.y - (BuddyView.canvas.height - inset.y)))
    }
}
