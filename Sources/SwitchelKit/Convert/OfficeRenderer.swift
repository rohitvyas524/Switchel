import AppKit
import WebKit

/// Renders Word files to PDF with their pictures, tables and styling, without needing Pages:
/// Quick Look's Office importer turns the document into HTML plus image files, and WebKit
/// prints that onto the document's own page size and margins.
enum OfficeRenderer {
    struct PageSetup {
        var size = CGSize(width: 612, height: 792)
        var margins = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
    }

    /// Quick Look's HTML rendering of `url`, in a scratch folder the caller deletes.
    static func html(for url: URL) async throws -> (page: URL, folder: URL) {
        let folder = try Output.temporaryFolder()
        // qlmanage names its output after the file, so work on a plainly named copy.
        let copy = folder.appendingPathComponent("document.\(url.pathExtension)")
        try FileManager.default.copyItem(at: url, to: copy)
        try? await Shell.run("/usr/bin/qlmanage", ["-p", "-o", folder.path, copy.path])
        let page = folder.appendingPathComponent("document.\(url.pathExtension).qlpreview/Preview.html")
        guard FileManager.default.fileExists(atPath: page.path) else {
            try? FileManager.default.removeItem(at: folder)
            throw SwitchelError("macOS couldn't read \(url.lastPathComponent)")
        }
        return (page, folder)
    }

    /// The first section's page size and margins from a .docx (twentieths of a point).
    static func pageSetup(of url: URL) async -> PageSetup {
        var setup = PageSetup()
        guard Output.normalizedExtension(url) == "docx", let folder = try? Output.temporaryFolder() else { return setup }
        defer { try? FileManager.default.removeItem(at: folder) }
        guard (try? await Zip.extract(url, to: folder)) != nil,
              let xml = try? String(contentsOf: folder.appendingPathComponent("word/document.xml")) else { return setup }
        func value(_ element: String, _ attribute: String) -> CGFloat? {
            guard let tag = xml.range(of: "<w:\(element) [^>]*>", options: [.regularExpression, .backwards]),
                  let match = xml[tag].range(of: "w:\(attribute)=\"-?[0-9]+\"", options: .regularExpression) else { return nil }
            let digits = xml[match].split(separator: "\"")[1]
            return Double(digits).map { CGFloat($0) / 20 }
        }
        if let width = value("pgSz", "w"), let height = value("pgSz", "h") { setup.size = CGSize(width: width, height: height) }
        setup.margins = NSEdgeInsets(top: value("pgMar", "top") ?? 72, left: value("pgMar", "left") ?? 72,
                                     bottom: value("pgMar", "bottom") ?? 72, right: value("pgMar", "right") ?? 72)
        return setup
    }

    /// Quick Look places floating pictures absolutely, and web pages can't wrap text around those,
    /// so text runs underneath them. Turn each into a float on its nearer side (or a centred block),
    /// which wraps the way Word's square wrapping does.
    static func floatingPicturesWrapped(_ html: String, contentWidth: CGFloat) -> String {
        guard let rule = try? NSRegularExpression(pattern: #"(\.s\d+\.s\d+\.s\d+ \{)([^}]*position:absolute[^}]*)\}"#) else { return html }
        var result = html
        // Classes turned into centred blocks, with the room the picture used to cover.
        var blocks: [(name: String, height: CGFloat)] = []
        for match in rule.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let range = Range(match.range, in: html), let selector = Range(match.range(at: 1), in: html),
                  let body = Range(match.range(at: 2), in: html) else { continue }
            func number(_ property: String) -> CGFloat {
                guard let found = html[body].range(of: "\(property):\\s*-?[0-9.]+", options: .regularExpression) else { return 0 }
                return CGFloat(Double(html[body][found].split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0)
            }
            let width = number("width"), height = number("height")
            let left = number("margin-left"), right = contentWidth - width - left
            let placement: String
            if abs(left - right) < 40 || width > contentWidth * 0.6 {
                placement = "display:block; margin: 8px auto;"
                if let name = html[selector].split(separator: ".").first { blocks.append((String(name), height + number("margin-top"))) }
            } else if left < right {
                placement = "float:left; margin: 4px 14px 8px 0;"
            } else {
                placement = "float:right; margin: 4px 0 8px 14px;"
            }
            let size = (width > 0 ? "width:\(width)px; " : "") + (height > 0 ? "height:\(height)px; " : "")
            result.replaceSubrange(range, with: String(html[selector]) + size + placement + " position:static; }")
        }
        // Authors leave empty lines under a floating picture to make room for it. Now that the picture
        // takes its own space, drop that many empty lines after it so the gap isn't doubled.
        let empty = #"^\s*<p[^>]*>(\s*<span[^>]*>(\s|&nbsp;|\u{00A0})*</span>)*\s*</p>"#
        for block in blocks {
            var searchFrom = result.startIndex
            while let use = result.range(of: "class=\"\(block.name)\"", range: searchFrom..<result.endIndex),
                  let close = result.range(of: #"</(div|p)>"#, options: .regularExpression, range: use.upperBound..<result.endIndex) {
                var cursor = close.upperBound
                var room = block.height
                while room > 7, let line = result.range(of: empty, options: .regularExpression, range: cursor..<result.endIndex) {
                    result.removeSubrange(line)
                    room -= 14.4  // one 12-point line at 1.2 spacing
                    cursor = line.lowerBound
                }
                searchFrom = cursor
            }
        }
        return result
    }

    /// Word (or any file Quick Look previews as HTML) → paginated PDF.
    @MainActor
    static func pdf(from url: URL, to out: URL) async throws {
        let (page, folder) = try await html(for: url)
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = await pageSetup(of: url)
        // Quick Look wraps the document in one fixed-size "page" with its margins as padding.
        // Unwrap it so WebKit can paginate and the print margins can take over.
        var html = try String(contentsOf: page)
        let unwrap = "<style>body > div:first-of-type { padding: 0 !important; width: auto !important; min-height: 0 !important; overflow: visible !important; } img { break-inside: avoid; } tr { break-inside: avoid; }</style>"
        html = html.replacingOccurrences(of: "</head>", with: unwrap + "</head>")
        html = floatingPicturesWrapped(html, contentWidth: setup.size.width - setup.margins.left - setup.margins.right)
        try html.write(to: page, atomically: true, encoding: .utf8)
        try await WebPrinter(page: page, readAccess: page.deletingLastPathComponent(), setup: setup).print(to: out)
    }
}

/// Loads a local page in an off-screen WKWebView, renders it as one long PDF page, then cuts that
/// into real pages. Cuts land in blank rows so no line of text or picture is split.
/// (WebKit's own print operation can deadlock when run synchronously, so it isn't used.)
@MainActor
private final class WebPrinter: NSObject, WKNavigationDelegate {
    private let page: URL
    private let readAccess: URL
    private let setup: OfficeRenderer.PageSetup
    private var loaded: CheckedContinuation<Void, Error>?

    init(page: URL, readAccess: URL, setup: OfficeRenderer.PageSetup) {
        self.page = page
        self.readAccess = readAccess
        self.setup = setup
    }

    func print(to out: URL) async throws {
        let width = setup.size.width - setup.margins.left - setup.margins.right
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: setup.size.height))
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            view.loadFileURL(page, allowingReadAccessTo: readAccess)
        }
        // Let images decode and layout settle.
        try await Task.sleep(nanoseconds: 300_000_000)
        let data = try await view.pdf(configuration: WKPDFConfiguration())
        guard let provider = CGDataProvider(data: data as CFData), let tall = CGPDFDocument(provider)?.page(at: 1) else {
            throw SwitchelError("Couldn't render the document")
        }
        try paginate(tall, to: out)
    }

    private func paginate(_ tall: CGPDFPage, to out: URL) throws {
        let box = tall.getBoxRect(.mediaBox)
        let pageHeight = setup.size.height - setup.margins.top - setup.margins.bottom
        let blank = blankRows(tall, box: box)

        // Cut positions, measured from the top of the long page.
        var cuts: [CGFloat] = [0]
        while box.height - cuts.last! > pageHeight {
            let start = cuts.last!, ideal = start + pageHeight
            // Prefer the gap between paragraphs (a tall blank band), then between lines, in the bottom 40%.
            func lowestGap(atLeast rows: Int) -> Int? {
                stride(from: Int(ideal), through: Int(start + pageHeight * 0.6), by: -1).first { row in
                    row - rows >= 0 && (row - rows...row).allSatisfy { blank.indices.contains($0) && blank[$0] }
                }
            }
            let candidate = lowestGap(atLeast: 9) ?? lowestGap(atLeast: 2)
            cuts.append(candidate.map(CGFloat.init) ?? ideal)
        }
        cuts.append(box.height)

        var media = CGRect(origin: .zero, size: setup.size)
        guard let ctx = CGContext(out as CFURL, mediaBox: &media, nil) else { throw SwitchelError("Couldn't create \(out.lastPathComponent)") }
        let top = setup.size.height - setup.margins.top
        for (start, end) in zip(cuts, cuts.dropFirst()) where end > start {
            ctx.beginPage(mediaBox: &media)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: setup.margins.left, y: top - (end - start), width: box.width, height: end - start))
            // Shift the long page so the slice starting at `start` sits at the top margin.
            ctx.translateBy(x: setup.margins.left - box.minX, y: top - box.height + start - box.minY)
            ctx.drawPDFPage(tall)
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// For each 1-point row from the top, whether it's (nearly) white across the whole width.
    private func blankRows(_ tall: CGPDFPage, box: CGRect) -> [Bool] {
        let width = max(Int(box.width), 1), height = max(Int(box.height), 1)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return []
        }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(tall)
        guard let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        // Bitmap row 0 is the top of the page.
        return (0..<height).map { row in
            let line = pixels + row * width
            return (0..<width).allSatisfy { line[$0] > 245 }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }
}
