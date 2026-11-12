import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, html, markdown, json, csv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: return "PDF Document"
        case .html: return "Web Page (single HTML file)"
        case .markdown: return "Markdown + Images (.zip)"
        case .json: return "JSON (raw data)"
        case .csv: return "CSV (spreadsheet)"
        }
    }

    var summary: String {
        switch self {
        case .pdf: return "Paginated report for clients and stakeholders."
        case .html: return "One file with images embedded. Opens in any browser."
        case .markdown: return "README.md plus a shots/ folder. Good for HackerOne, GitHub, Jira."
        case .json: return "Everything Remark knows, for scripts and integrations."
        case .csv: return "One row per note. Opens in Numbers, Excel, Sheets."
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .html: return "html"
        case .markdown: return "zip"
        case .json: return "json"
        case .csv: return "csv"
        }
    }

    var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .data }
}

enum ExportError: LocalizedError {
    case noSession, failed(String)
    var errorDescription: String? {
        switch self {
        case .noSession: return "There's no active session to export."
        case .failed(let why): return why
        }
    }
}

enum Exporter {
    static func export(_ format: ExportFormat, store: SessionStore, to url: URL, pageSize: PageSize) throws {
        guard let session = store.session, let folder = store.folder else { throw ExportError.noSession }
        try? FileManager.default.removeItem(at: url)

        switch format {
        case .pdf:
            try PDFReport.render(session: session, folder: folder, to: url, page: pageSize.rect)
        case .html:
            try store.html(embedImages: true).write(to: url, atomically: true, encoding: .utf8)
        case .json:
            try SessionStore.encoder.encode(session).write(to: url, options: .atomic)
        case .csv:
            try csv(session).write(to: url, atomically: true, encoding: .utf8)
        case .markdown:
            try markdownZip(store: store, session: session, folder: folder, to: url)
        }
    }

    private static func csv(_ s: ReviewSession) -> String {
        func cell(_ v: String?) -> String {
            let raw = v ?? ""
            return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let iso = ISO8601DateFormatter()
        var rows = ["number,kind,note,quoted_text,app,window,created_at,image"]
        for n in s.notes {
            rows.append([String(n.number), n.kind.label, cell(n.text), cell(n.quote),
                         cell(n.sourceApp), cell(n.windowTitle), iso.string(from: n.createdAt),
                         cell(n.imageFile)].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func markdownZip(store: SessionStore, session: ReviewSession, folder: URL, to url: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = staging.appendingPathComponent(SessionStore.slug(session.title), isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("shots"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try store.markdown().write(to: bundle.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for file in session.notes.compactMap(\.imageFile) {
            try? fm.copyItem(at: folder.appendingPathComponent(file), to: bundle.appendingPathComponent(file))
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, url.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ExportError.failed("Couldn't create the zip file.") }
    }
}

/// Paginated PDF drawn natively (no web view), so output is identical every time.
enum PDFReport {
    static func render(session s: ReviewSession, folder: URL, to url: URL, page: CGRect) throws {
        var mediaBox = page
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, [
            kCGPDFContextTitle as String: s.title,
            kCGPDFContextAuthor as String: s.reviewer,
            kCGPDFContextCreator as String: "Remark"
        ] as CFDictionary) else {
            throw ExportError.failed("Couldn't create the PDF file.")
        }

        let margin: CGFloat = 48
        let width = page.width - margin * 2
        let bottomLimit = page.height - margin - 18 // leave room for footer
        var y: CGFloat = margin
        var pageNumber = 0

        let accent = Theme.nsAccent
        let muted = NSColor(srgbRed: 0.47, green: 0.44, blue: 0.42, alpha: 1)
        let line = NSColor(srgbRed: 0.90, green: 0.89, blue: 0.88, alpha: 1)

        func beginPage() {
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            pageNumber += 1
            y = margin
            let footer = NSAttributedString(string: "\(s.title)  ·  \(pageNumber)", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: muted
            ])
            footer.draw(at: NSPoint(x: margin, y: page.height - margin + 6))
        }

        func endPage() {
            NSGraphicsContext.current = nil
            ctx.endPDFPage()
        }

        func ensure(_ height: CGFloat) {
            if y + height > bottomLimit && y > margin {
                endPage()
                beginPage()
            }
        }

        func height(of str: NSAttributedString, width w: CGFloat) -> CGFloat {
            ceil(str.boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }

        func drawParagraphs(_ text: String, attrs: [NSAttributedString.Key: Any],
                            indent: CGFloat = 0, bar: NSColor? = nil, spacing: CGFloat = 3) {
            for para in text.components(separatedBy: "\n") {
                let str = NSAttributedString(string: para.isEmpty ? " " : para, attributes: attrs)
                let w = width - indent
                let h = height(of: str, width: w)
                ensure(h)
                if let bar {
                    bar.setFill()
                    NSRect(x: margin, y: y - 1, width: 2.5, height: h + spacing).fill()
                }
                str.draw(with: NSRect(x: margin + indent, y: y, width: w, height: h),
                         options: [.usesLineFragmentOrigin, .usesFontLeading])
                y += h + spacing
            }
        }

        beginPage()

        // Title block
        drawParagraphs(s.title, attrs: [.font: NSFont.systemFont(ofSize: 22, weight: .bold),
                                        .foregroundColor: NSColor.black])
        y += 2
        let noteWord = s.notes.count == 1 ? "note" : "notes"
        drawParagraphs("Reviewed by \(s.reviewer)  ·  \(SessionStore.display.string(from: s.createdAt))  ·  \(s.notes.count) \(noteWord)",
                       attrs: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: muted])

        var counts: [NoteKind: Int] = [:]
        s.notes.forEach { counts[$0.kind, default: 0] += 1 }
        let summary = NSMutableAttributedString()
        for kind in NoteKind.allCases {
            guard let c = counts[kind], c > 0 else { continue }
            summary.append(NSAttributedString(string: "\(kind.label) \(c)    ", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: kind.nsColor
            ]))
        }
        if summary.length > 0 {
            let h = height(of: summary, width: width)
            summary.draw(with: NSRect(x: margin, y: y + 4, width: width, height: h),
                         options: [.usesLineFragmentOrigin])
            y += h + 4
        }
        y += 14
        line.setFill()
        NSRect(x: margin, y: y, width: width, height: 1).fill()
        y += 18

        // Notes
        for n in s.notes {
            // Keep the header with at least a bit of content.
            ensure(60)

            let header = NSMutableAttributedString()
            header.append(NSAttributedString(string: "#\(n.number)  ", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: accent
            ]))
            header.append(NSAttributedString(string: n.kind.label.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: n.kind.nsColor, .kern: 0.6
            ]))
            var meta = "   ·   " + SessionStore.time.string(from: n.createdAt)
            if let ctxText = n.context { meta += "   ·   " + ctxText }
            header.append(NSAttributedString(string: meta, attributes: [
                .font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: muted
            ]))
            let hh = height(of: header, width: width)
            header.draw(with: NSRect(x: margin, y: y, width: width, height: hh),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += hh + 8

            if let q = n.quote {
                drawParagraphs(q, attrs: [.font: NSFont.systemFont(ofSize: 10.5),
                                          .foregroundColor: NSColor(white: 0.25, alpha: 1)],
                               indent: 12, bar: accent, spacing: 2)
                y += 6
            }

            drawParagraphs(n.text.isEmpty ? "(no note)" : n.text,
                           attrs: [.font: n.text.isEmpty ? NSFont.systemFont(ofSize: 11).withItalic()
                                                         : NSFont.systemFont(ofSize: 11.5),
                                   .foregroundColor: n.text.isEmpty ? muted : NSColor.black])

            if let file = n.imageFile, let image = NSImage(contentsOf: folder.appendingPathComponent(file)) {
                y += 6
                let size = image.size
                let maxH = (bottomLimit - margin) * 0.62
                let scale = min(width / max(size.width, 1), maxH / max(size.height, 1), 1)
                let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
                ensure(drawSize.height)
                let rect = NSRect(x: margin + (width - drawSize.width) / 2, y: y,
                                  width: drawSize.width, height: drawSize.height)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
                line.setStroke()
                let border = NSBezierPath(rect: rect)
                border.lineWidth = 0.75
                border.stroke()
                y += drawSize.height
            }

            y += 16
            if y + 1 < bottomLimit {
                line.setFill()
                NSRect(x: margin, y: y, width: width, height: 0.75).fill()
            }
            y += 18
        }

        if s.notes.isEmpty {
            drawParagraphs("No notes yet.", attrs: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted])
        }

        endPage()
        ctx.closePDF()
    }
}

private extension NSFont {
    func withItalic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
