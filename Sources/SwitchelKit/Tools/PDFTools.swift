import Foundation
import PDFKit

enum PDFTools {
    /// Re-encodes embedded images as screen-resolution JPEG.
    static func compress(_ url: URL) throws -> URL {
        let doc = try PDFConverter.open(url)
        let out = Output.url(for: url, ext: "pdf", suffix: "compressed")
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard doc.write(to: out, withOptions: options) else { throw SwitchelError("Couldn't write \(out.lastPathComponent)") }
        return out
    }

    /// Merges in Finder name order, named after the first file.
    static func merge(_ urls: [URL]) throws -> URL {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let merged = PDFDocument()
        for url in sorted {
            let doc = try PDFConverter.open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let out = Output.url(for: sorted[0], ext: "pdf", suffix: "merged")
        guard merged.write(to: out) else { throw SwitchelError("Couldn't write \(out.lastPathComponent)") }
        return out
    }

    enum SplitMode: Equatable {
        case everyPage
        case every(Int)
        /// 1-based, e.g. "1-3, 5, 8-10".
        case ranges(String)
    }

    /// Writes the parts into a folder named after the PDF.
    static func split(_ url: URL, _ mode: SplitMode) throws -> URL {
        let doc = try PDFConverter.open(url)
        let count = doc.pageCount
        let groups: [ClosedRange<Int>] = switch mode {
        case .everyPage: (0..<count).map { $0...$0 }
        case .every(let n): stride(from: 0, to: count, by: max(n, 1)).map { $0...min($0 + max(n, 1) - 1, count - 1) }
        case .ranges(let text): try parseRanges(text, pageCount: count)
        }
        let folder = Output.url(for: url, ext: nil, suffix: "split")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = Output.baseName(url)
        for group in groups {
            let part = PDFDocument()
            for i in group { if let page = doc.page(at: i)?.copy() as? PDFPage { part.insert(page, at: part.pageCount) } }
            let name = group.count == 1 ? "\(base) p\(group.lowerBound + 1)" : "\(base) p\(group.lowerBound + 1)-\(group.upperBound + 1)"
            guard part.write(to: folder.appendingPathComponent("\(name).pdf")) else { throw SwitchelError("Couldn't write \(name).pdf") }
        }
        return folder
    }

    /// "1-3, 5" → [0...2, 4...4] (0-based).
    static func parseRanges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        let ranges = try text.split(separator: ",").map { part -> ClosedRange<Int> in
            let bounds = part.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let first = bounds.first ?? nil, let last = bounds.last ?? nil, bounds.count <= 2,
                  first >= 1, last >= first, last <= pageCount else {
                throw SwitchelError("“\(part.trimmingCharacters(in: .whitespaces))” isn't a page range in 1–\(pageCount)")
            }
            return (first - 1)...(last - 1)
        }
        guard !ranges.isEmpty else { throw SwitchelError("Enter page ranges, like 1-3, 5") }
        return ranges
    }

    /// A page in the organiser; it can come from any PDF, so others can be dropped in.
    struct PageEdit: Identifiable, Equatable {
        let id = UUID()
        let source: URL
        let index: Int
        var rotation = 0
    }

    /// Saves the pages in the given order and rotation, named after `url`. Pages left out are dropped.
    static func rearrange(_ url: URL, pages: [PageEdit]) throws -> URL {
        var documents: [URL: PDFDocument] = [:]
        let edited = PDFDocument()
        for edit in pages {
            if documents[edit.source] == nil { documents[edit.source] = try PDFConverter.open(edit.source) }
            guard let page = documents[edit.source]?.page(at: edit.index)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + edit.rotation) % 360
            edited.insert(page, at: edited.pageCount)
        }
        guard edited.pageCount > 0 else { throw SwitchelError("Keep at least one page") }
        let out = Output.url(for: url, ext: "pdf", suffix: "edited")
        guard edited.write(to: out) else { throw SwitchelError("Couldn't write \(out.lastPathComponent)") }
        return out
    }
}
