import AppKit

enum DocumentFormat: String, CaseIterable {
    case docx, pages, md, txt, epub, html, rtf, odt, pdf

    var documentType: NSAttributedString.DocumentType? {
        switch self {
        case .docx: .officeOpenXML
        case .rtf: .rtf
        case .odt: .openDocument
        case .html: .html
        case .txt: .plain
        case .pages, .md, .epub, .pdf: nil
        }
    }

    /// What Pages calls this format when exporting a .pages file directly.
    var pagesExportFormat: String? {
        switch self {
        case .docx: "Microsoft Word"
        case .pdf: "PDF"
        case .epub: "EPUB"
        case .txt: "unformatted text"
        case .rtf: "formatted text"
        default: nil
        }
    }
}

/// Reads anything AppKit's text system understands, plus Markdown, EPUB, Pages and text clippings,
/// into an attributed string, then writes it out. Main actor because HTML import and printing need it.
@MainActor
enum DocumentConverter {
    static func convert(_ url: URL, to format: DocumentFormat) async throws -> URL {
        let out = Output.url(for: url, ext: format.rawValue)
        let source = Output.normalizedExtension(url)
        if source == "pages", let pagesFormat = format.pagesExportFormat {
            try await IWork.export(url, with: .pages, to: out, as: pagesFormat)
            return out
        }
        // Pages lays out Word files faithfully (pictures, tables, headers, columns), so let it make
        // PDFs, EPUBs and Pages documents from them.
        if ["docx", "doc", "rtf"].contains(source), IWork.canUse(.pages), [.pdf, .epub, .pages].contains(format) {
            do {
                if format == .pages {
                    try await IWork.save(url, with: .pages, to: out)
                } else {
                    try await IWork.export(url, with: .pages, to: out, as: format.pagesExportFormat!)
                }
                return out
            } catch {
                // Without Automation permission, fall back to the built-in conversion.
                try? FileManager.default.removeItem(at: out)
            }
        }
        // macOS's plain Word reader drops pictures; Quick Look's keeps pictures, tables and styling.
        if ["docx", "doc"].contains(source), format == .pdf {
            do {
                try await OfficeRenderer.pdf(from: url, to: out)
                return out
            } catch {
                try? FileManager.default.removeItem(at: out)
            }
        }
        let text = try await read(url)
        try await write(text, as: format, to: out, title: Output.baseName(url))
        return out
    }

    static func read(_ url: URL) async throws -> NSAttributedString {
        switch Output.normalizedExtension(url) {
        case "md":
            return try html(Data(Markdown.html(try String(contentsOf: url)).utf8))
        case "txt":
            var encoding = String.Encoding.utf8
            let string = try String(contentsOf: url, usedEncoding: &encoding)
            return NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        case "epub":
            let (chapters, folder) = try await Packages.epubChapters(url)
            defer { try? FileManager.default.removeItem(at: folder) }
            let combined = NSMutableAttributedString()
            for chapter in chapters {
                let part = try NSAttributedString(url: chapter, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                          .characterEncoding: String.Encoding.utf8.rawValue],
                                                  documentAttributes: nil)
                if combined.length > 0 { combined.append(NSAttributedString(string: "\n")) }
                combined.append(part)
            }
            return combined
        case "pages":
            let folder = try Output.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let docx = folder.appendingPathComponent("export.docx")
            try await IWork.export(url, with: .pages, to: docx, as: "Microsoft Word")
            return try NSAttributedString(url: docx, options: [:], documentAttributes: nil)
        case "textclipping":
            return try clipping(url)
        default:
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
    }

    static func write(_ text: NSAttributedString, as format: DocumentFormat, to out: URL, title: String) async throws {
        switch format {
        case .docx, .rtf, .odt, .html, .txt:
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: format.documentType!]
            if format == .txt || format == .html {
                attributes[.characterEncoding] = String.Encoding.utf8.rawValue
            }
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
            try data.write(to: out)
        case .md:
            try RichText.markdown(text).write(to: out, atomically: true, encoding: .utf8)
        case .epub:
            try await Packages.writeEPUB([.init(title: title, body: RichText.xhtmlBody(text))], title: title, to: out)
        case .pages:
            let folder = try Output.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let docx = folder.appendingPathComponent("\(title).docx")
            try await write(text, as: .docx, to: docx, title: title)
            try await IWork.save(docx, with: .pages, to: out)
        case .pdf:
            try writePDF(text, to: out)
        }
    }

    static func html(_ data: Data) throws -> NSAttributedString {
        try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                     .characterEncoding: String.Encoding.utf8.rawValue],
                               documentAttributes: nil)
    }

    /// Text clippings are property lists holding pasteboard data by type.
    private static func clipping(_ url: URL) throws -> NSAttributedString {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        guard let items = plist?["UTI-Data"] as? [String: Any] else {
            throw SwitchelError("Couldn't read \(url.lastPathComponent)")
        }
        if let rtf = items["public.rtf"] as? Data, let text = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return text
        }
        let string = (items["public.utf8-plain-text"] as? String)
            ?? (items["public.utf8-plain-text"] as? Data).map { String(decoding: $0, as: UTF8.self) }
            ?? (items["public.utf16-plain-text"] as? Data).flatMap { String(data: $0, encoding: .utf16) }
        guard let string else { throw SwitchelError("\(url.lastPathComponent) has no text") }
        return NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 13)])
    }

    /// US Letter with 1" margins, paginated by the text system.
    static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: url])
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 72
        info.bottomMargin = 72
        info.leftMargin = 72
        info.rightMargin = 72
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        // Plain text has no colour of its own; keep it black even in Dark Mode.
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.textStorage?.setAttributedString(text)
        if let layout = view.layoutManager, let container = view.textContainer {
            layout.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: width, height: ceil(layout.usedRect(for: container).height) + 1))
        }

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw SwitchelError("Couldn't create \(url.lastPathComponent)") }
    }
}
