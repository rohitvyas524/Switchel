import AppKit
import PDFKit
import UniformTypeIdentifiers

enum PDFFormat: String, CaseIterable {
    case docx, pages, pptx, xlsx, jpg, png, epub, txt, md
}

/// How PDF pages become Word, Pages and PowerPoint files.
enum OfficeLayout: String, CaseIterable, Identifiable {
    /// Selectable, editable text with headings kept.
    case editable
    /// Each page as a sharp picture: looks identical, including tables, equations and scans, but text can't be edited.
    case exact

    var id: Self { self }
}

enum PDFConverter {
    @MainActor
    static func convert(_ url: URL, to format: PDFFormat, layout: OfficeLayout = .editable) async throws -> URL {
        let doc = try open(url)
        let title = Output.baseName(url)
        switch format {
        case .jpg, .png:
            return try await Task.detached { try images(url, format: format == .png ? .png : .jpg) }.value
        case .txt:
            let out = Output.url(for: url, ext: "txt")
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return out
        case .docx where layout == .exact, .pages where layout == .exact:
            let out = Output.url(for: url, ext: format.rawValue)
            let pages = try await Task.detached {
                try (0..<doc.pageCount).compactMap { doc.page(at: $0) }.map {
                    (jpeg: try ImageConverter.encode(try render($0, dpi: 300), type: .jpeg, quality: 0.9), size: displaySize($0))
                }
            }.value
            if format == .docx {
                try await Packages.writePictureDOCX(pages: pages, to: out)
            } else {
                let folder = try Output.temporaryFolder()
                defer { try? FileManager.default.removeItem(at: folder) }
                let docx = folder.appendingPathComponent("\(title).docx")
                try await Packages.writePictureDOCX(pages: pages, to: docx)
                try await IWork.save(docx, with: .pages, to: out)
            }
            return out
        case .docx, .pages:
            // Editable: headings, paragraphs and real tables rebuilt from the page layout.
            let out = Output.url(for: url, ext: format.rawValue)
            let layout = await Task.detached { PDFLayout.document(doc) }.value
            if format == .docx {
                try await Packages.writeDOCX(layout, to: out)
            } else {
                let folder = try Output.temporaryFolder()
                defer { try? FileManager.default.removeItem(at: folder) }
                let docx = folder.appendingPathComponent("\(title).docx")
                try await Packages.writeDOCX(layout, to: docx)
                try await IWork.save(docx, with: .pages, to: out)
            }
            return out
        case .md:
            let out = Output.url(for: url, ext: "md")
            try PDFLayout.markdown(PDFLayout.blocks(doc)).write(to: out, atomically: true, encoding: .utf8)
            return out
        case .epub:
            let out = Output.url(for: url, ext: "epub")
            let chapters = (0..<doc.pageCount).compactMap { i -> Packages.Chapter? in
                guard let page = doc.page(at: i)?.attributedString else { return nil }
                return Packages.Chapter(title: "Page \(i + 1)", body: RichText.xhtmlBody(page))
            }
            try await Packages.writeEPUB(chapters, title: title, to: out)
            return out
        case .pptx:
            let out = Output.url(for: url, ext: "pptx")
            let slides: [Packages.Slide]
            if layout == .exact {
                slides = try await Task.detached {
                    try (0..<doc.pageCount).compactMap { doc.page(at: $0) }.map {
                        .picture(try ImageConverter.encode(try render($0, dpi: 200), type: .jpeg, quality: 0.85))
                    }
                }.value
            } else {
                slides = (0..<doc.pageCount).map { .text(doc.page(at: $0)?.attributedString.map(RichText.paragraphs) ?? []) }
            }
            let size = doc.page(at: 0).map(displaySize) ?? CGSize(width: 792, height: 612)
            try await Packages.writePPTX(slides: slides, slideSize: size, to: out)
            return out
        case .xlsx:
            let out = Output.url(for: url, ext: "xlsx")
            let layout = await Task.detached { PDFLayout.document(doc) }.value
            let sheet = spreadsheet(layout)
            try await Packages.writeXLSX(sheet.table, to: out, formats: sheet.formats, columnWidths: sheet.widths)
            return out
        }
    }

    /// 300 DPI. A multi-page PDF becomes a folder with one image per page.
    static func images(_ url: URL, format: ImageFormat) throws -> URL {
        let doc = try open(url)
        let type: UTType = format == .png ? .png : .jpeg
        if doc.pageCount == 1, let page = doc.page(at: 0) {
            let out = Output.url(for: url, ext: format.rawValue)
            try ImageConverter.write(try render(page), to: out, type: type, quality: 0.9)
            return out
        }
        let folder = Output.url(for: url, ext: nil, suffix: "pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = Output.baseName(url)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let file = folder.appendingPathComponent("\(base) \(i + 1).\(format.rawValue)")
            try ImageConverter.write(try render(page), to: file, type: type, quality: 0.9)
        }
        return folder
    }

    /// Lays the PDF out as one sheet: each table keeps its cells and look, each paragraph takes a row,
    /// with a blank row between blocks. Column widths follow the widest table.
    static func spreadsheet(_ layout: PDFLayout.Document) -> (table: Table, formats: [[Packages.CellFormat?]], widths: [CGFloat]?) {
        func format(_ runs: [PDFLayout.Run], fill: String? = nil, alignment: PDFLayout.Alignment = .left, border: Bool = false) -> Packages.CellFormat? {
            let style = runs.first { !$0.text.allSatisfy(\.isWhitespace) }?.style ?? PDFLayout.Style()
            let horizontal: String? = switch alignment {
            case .center: "center"
            case .right: "right"
            default: nil
            }
            return Packages.CellFormat(bold: style.bold, italic: style.italic, font: style.font, size: style.size, color: style.color,
                                       fill: fill, alignment: horizontal, border: border)
        }
        var table: Table = []
        var formats: [[Packages.CellFormat?]] = []
        var widths: [CGFloat]?
        for block in layout.blocks {
            switch block {
            case .paragraph(let paragraph):
                table.append([paragraph.text])
                formats.append([format(paragraph.runs)])
            case .table(let found):
                for (r, row) in found.rows.enumerated() {
                    table.append(row.map { $0.map(\.text).joined() })
                    formats.append(row.indices.map { c in
                        format(row[c], fill: r < found.shading.count ? found.shading[r][c] : nil,
                               alignment: found.alignments[min(c, found.alignments.count - 1)], border: found.borders)
                    })
                }
                // Points to Excel's character units (about 5.5 pt each).
                if found.columnWidths.count > (widths?.count ?? 0) { widths = found.columnWidths.map { max($0 / 5.5, 6) } }
            case .picture, .pageBreak:
                continue
            }
            table.append([])
            formats.append([])
        }
        while table.last?.isEmpty == true { table.removeLast(); formats.removeLast() }
        return (table, formats, widths)
    }

    static func displaySize(_ page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .mediaBox)
        return page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    }

    static func render(_ page: PDFPage, dpi: CGFloat = 300) throws -> CGImage {
        let size = displaySize(page)
        // Cap very large pages at ~50 MP.
        let scale = min(dpi / 72, sqrt(50_000_000 / max(size.width * size.height, 1)))
        let ctx = try ImageConverter.context(width: Int(size.width * scale), height: Int(size.height * scale), alpha: false)
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { throw SwitchelError("Couldn't render page") }
        return image
    }

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw SwitchelError("Couldn't open \(url.lastPathComponent)") }
        guard !doc.isLocked else { throw SwitchelError("\(url.lastPathComponent) is password-protected") }
        return doc
    }
}
