import AppKit

enum NoteKind: String, Codable, CaseIterable, Identifiable {
    case note, bug, ux, question, idea

    var id: String { rawValue }

    var label: String {
        switch self {
        case .note: return "Note"
        case .bug: return "Bug"
        case .ux: return "UX"
        case .question: return "Question"
        case .idea: return "Idea"
        }
    }

    var colorHex: String {
        switch self {
        case .note: return "#6B7280"
        case .bug: return "#DC2626"
        case .ux: return "#EA580C"
        case .question: return "#2563EB"
        case .idea: return "#059669"
        }
    }
}

struct ReviewNote: Codable, Identifiable {
    var id = UUID()
    var number: Int
    var createdAt: Date
    var kind: NoteKind
    var text: String
    var imageFile: String?  // relative to the session folder; nil for text-selection notes
    var sourceApp: String?
    var quote: String?      // selected text, or text pulled from the screenshot
    var windowTitle: String?

    var context: String? {
        let parts = [sourceApp, windowTitle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

extension NoteKind {
    var nsColor: NSColor {
        let hex = colorHex.dropFirst()
        let v = UInt32(hex, radix: 16) ?? 0x6B7280
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

struct ReviewSession: Codable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var reviewer: String
    var notes: [ReviewNote] = []
}

struct RecentSession {
    let title: String
    let url: URL
    let count: Int
    let date: Date
}

/// Each review session is a folder in ~/Documents/Remark:
///   session.json, shots/*.png, report.html, report.md
final class SessionStore {
    static let rootURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Remark", isDirectory: true)

    private(set) var session: ReviewSession?
    private(set) var folder: URL?
    var onChange: (() -> Void)?

    private let lastKey = "lastSessionFolder"

    var isActive: Bool { session != nil }
    var reportHTMLURL: URL? { folder?.appendingPathComponent("report.html") }
    var reportMDURL: URL? { folder?.appendingPathComponent("report.md") }

    // MARK: Lifecycle

    func start(title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let finalTitle = clean.isEmpty ? "Review \(Self.display.string(from: now))" : clean
        let url = Self.rootURL.appendingPathComponent("\(Self.stamp.string(from: now))-\(Self.slug(finalTitle))",
                                                      isDirectory: true)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("shots", isDirectory: true),
                                                 withIntermediateDirectories: true)
        session = ReviewSession(title: finalTitle, createdAt: now, reviewer: NSFullUserName())
        folder = url
        UserDefaults.standard.set(url.path, forKey: lastKey)
        save()
    }

    func ensureSession() {
        if session == nil { start(title: "") }
    }

    @discardableResult
    func open(folder url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("session.json")),
              let s = try? Self.decoder.decode(ReviewSession.self, from: data) else { return false }
        session = s
        folder = url
        UserDefaults.standard.set(url.path, forKey: lastKey)
        onChange?()
        return true
    }

    func resumeLast() {
        guard let path = UserDefaults.standard.string(forKey: lastKey) else { return }
        open(folder: URL(fileURLWithPath: path, isDirectory: true))
    }

    func end() {
        session = nil
        folder = nil
        UserDefaults.standard.removeObject(forKey: lastKey)
        onChange?()
    }

    // MARK: Notes

    func nextImageURL() -> URL {
        ensureSession()
        let n = (session?.notes.map(\.number).max() ?? 0) + 1
        let name = String(format: "shot-%03d-%@.png", n, String(UUID().uuidString.prefix(4)).lowercased())
        return folder!.appendingPathComponent("shots", isDirectory: true).appendingPathComponent(name)
    }

    func add(kind: NoteKind, text: String, imageURL: URL?, quote: String?,
             sourceApp: String?, windowTitle: String?) {
        guard var s = session else { return }
        let n = (s.notes.map(\.number).max() ?? 0) + 1
        let cleanQuote = quote?.trimmingCharacters(in: .whitespacesAndNewlines)
        s.notes.append(ReviewNote(number: n,
                                  createdAt: Date(),
                                  kind: kind,
                                  text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  imageFile: imageURL.map { "shots/" + $0.lastPathComponent },
                                  sourceApp: sourceApp,
                                  quote: (cleanQuote?.isEmpty ?? true) ? nil : cleanQuote,
                                  windowTitle: windowTitle))
        session = s
        save()
    }

    func save() {
        guard let s = session, let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(s) {
            try? data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        }
        try? markdown().write(to: folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        try? html(embedImages: false).write(to: folder.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
        onChange?()
    }

    /// Single self-contained HTML file (images embedded) — safe to email/upload.
    func exportShareable() -> URL? {
        guard let s = session, let folder else { return nil }
        let url = folder.appendingPathComponent("\(Self.slug(s.title))-shareable.html")
        do {
            try html(embedImages: true).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func recentSessions(limit: Int = 10) -> [RecentSession] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return [] }
        var out: [RecentSession] = []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let s = try? decoder.decode(ReviewSession.self, from: data) else { continue }
            out.append(RecentSession(title: s.title, url: dir, count: s.notes.count, date: s.createdAt))
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(limit))
    }

    // MARK: Reports

    func markdown() -> String {
        guard let s = session else { return "" }
        var md = "# \(s.title)\n\n"
        md += "_Reviewed by \(s.reviewer) · \(Self.display.string(from: s.createdAt)) · \(s.notes.count) note\(s.notes.count == 1 ? "" : "s")_\n\n"
        for n in s.notes {
            md += "## \(n.number). [\(n.kind.label)]\(n.context.map { " — \($0)" } ?? "")\n\n"
            if let q = n.quote {
                md += q.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            }
            if let img = n.imageFile {
                md += "![Note \(n.number)](\(img))\n\n"
            }
            md += (n.text.isEmpty ? "_(no note)_" : n.text) + "\n\n"
            md += "<sub>\(Self.time.string(from: n.createdAt))</sub>\n\n---\n\n"
        }
        return md
    }

    func html(embedImages: Bool) -> String {
        guard let s = session, let folder else { return "" }

        var counts: [NoteKind: Int] = [:]
        s.notes.forEach { counts[$0.kind, default: 0] += 1 }
        let chips = NoteKind.allCases.compactMap { kind -> String? in
            guard let c = counts[kind], c > 0 else { return nil }
            return "<span class=\"chip\" style=\"--c:\(kind.colorHex)\">\(kind.label) · \(c)</span>"
        }.joined()

        let cards = s.notes.map { n -> String in
            var imageHTML = ""
            if let file = n.imageFile {
                var src = Self.esc(file)
                if embedImages, let data = try? Data(contentsOf: folder.appendingPathComponent(file)) {
                    src = "data:image/png;base64," + data.base64EncodedString()
                }
                imageHTML = "<a href=\"\(src)\" target=\"_blank\"><img src=\"\(src)\" alt=\"Screenshot for note \(n.number)\"></a>"
            }
            let quoteHTML = n.quote.map { "<blockquote>\(Self.esc($0))</blockquote>" } ?? ""
            let body = n.text.isEmpty ? "<div class=\"text empty\">(no note)</div>"
                                      : "<div class=\"text\">\(Self.esc(n.text))</div>"
            let app = n.context.map { " · \(Self.esc($0))" } ?? ""
            return """
            <article class="card" id="note-\(n.number)">
              <header>
                <span class="num">#\(n.number)</span>
                <span class="chip" style="--c:\(n.kind.colorHex)">\(n.kind.label)</span>
                <span class="meta">\(Self.time.string(from: n.createdAt))\(app)</span>
              </header>
              \(quoteHTML)
              \(body)
              \(imageHTML)
            </article>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.esc(s.title)) — Review</title>
        <style>
          :root { --bg:#faf9f7; --fg:#1c1917; --muted:#78716c; --card:#fff; --line:#e7e5e4; --accent:#8B5CF6; }
          @media (prefers-color-scheme: dark) { :root { --bg:#171513; --fg:#f5f5f4; --muted:#a8a29e; --card:#211e1b; --line:#3a3532; --accent:#A78BFA; } }
          * { box-sizing: border-box; }
          body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, sans-serif; }
          main { max-width: 880px; margin: 0 auto; padding: 48px 24px 80px; }
          h1 { font-size: 30px; margin: 0 0 6px; letter-spacing: -0.02em; }
          .sub { color: var(--muted); margin-bottom: 14px; }
          .chips { display:flex; gap:8px; flex-wrap:wrap; margin-bottom: 32px; }
          .chip { --c:#6b7280; display:inline-block; font-size:12px; font-weight:600; padding:2px 10px; border-radius:999px;
                  color:var(--c); background: color-mix(in srgb, var(--c) 14%, transparent); }
          .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:18px 20px 20px; margin-bottom:22px; }
          .card header { display:flex; align-items:center; gap:10px; margin-bottom:10px; }
          .num { font-weight:700; color:var(--accent); }
          .meta { margin-left:auto; color:var(--muted); font-size:13px; text-align:right; }
          blockquote { margin:0 0 12px; padding:8px 14px; border-left:3px solid var(--accent); white-space:pre-wrap;
                       background: color-mix(in srgb, var(--accent) 8%, transparent); border-radius:0 8px 8px 0; font-size:14px; }
          .text { white-space: pre-wrap; margin: 0 0 14px; font-size: 15.5px; }
          .text.empty { color: var(--muted); font-style: italic; }
          img { display:block; max-width:100%; max-height:560px; margin:0 auto; border-radius:8px; border:1px solid var(--line); }
          footer { color:var(--muted); font-size:12px; text-align:center; margin-top:40px; }
          @media print { body { background:#fff; color:#000; } .card { break-inside: avoid; } }
        </style>
        </head>
        <body>
        <main>
          <h1>\(Self.esc(s.title))</h1>
          <div class="sub">Reviewed by \(Self.esc(s.reviewer)) · \(Self.display.string(from: s.createdAt)) · \(s.notes.count) note\(s.notes.count == 1 ? "" : "s")</div>
          <div class="chips">\(chips)</div>
          \(cards.isEmpty ? "<p class=\"sub\">No notes yet. Press ⌃⌥R to capture one.</p>" : cards)
          <footer>Made with Remark</footer>
        </main>
        </body>
        </html>
        """
    }

    // MARK: Helpers

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = s.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "review" : String(collapsed.prefix(40))
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f
    }()

    static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
