import AppKit
import PDFKit

/// Rebuilds a PDF's structure, with its formatting, from where each character sits on the page.
/// A PDF only stores positioned glyphs; paragraphs and tables have to be recovered from geometry,
/// and fonts, colours, pictures and rules from the content stream (`PDFPageStyles`).
enum PDFLayout {
    struct Style: Equatable {
        var font = "Helvetica"
        var size: CGFloat = 11
        var bold = false
        var italic = false
        var underline = false
        /// "RRGGBB"; nil for black.
        var color: String?
        var link: URL?
    }

    struct Run: Equatable {
        var text: String
        var style: Style
    }

    enum Alignment: Equatable {
        case left, center, right, justified
    }

    struct Paragraph: Equatable {
        var runs: [Run]
        var heading = 0
        var alignment: Alignment = .left
        /// Points from the left margin.
        var indent: CGFloat = 0
        var firstLineIndent: CGFloat = 0
        var spaceBefore: CGFloat = 0
        /// Baseline to baseline, in points, when it differs from single spacing.
        var lineSpacing: CGFloat?

        var text: String { runs.map(\.text).joined() }
    }

    struct Table: Equatable {
        var rows: [[[Run]]]
        /// Each column's width in points, as on the page.
        var columnWidths: [CGFloat]
        var alignments: [Alignment]
        var header: Bool
        var borders: Bool
        /// "RRGGBB" per cell, nil for none.
        var shading: [[String?]]
        var indent: CGFloat = 0
        var spaceBefore: CGFloat = 0

        var text: [[String]] { rows.map { $0.map { $0.map(\.text).joined() } } }
    }

    struct Picture: Equatable {
        var jpeg: Data
        var size: CGSize
        var indent: CGFloat
        var spaceBefore: CGFloat
    }

    enum Block: Equatable {
        case paragraph(Paragraph)
        case table(Table)
        case picture(Picture)
        case pageBreak
    }

    struct Document {
        var pageSize: CGSize
        var margins: NSEdgeInsets
        var blocks: [Block]
    }

    // MARK: Building

    static func document(_ doc: PDFDocument) -> Document {
        let pages = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        let analysed = pages.map(analyse)
        let body = bodySize(analysed.flatMap(\.lines))

        // Margins come from where content sits across all pages.
        let first = pages.first.map { $0.bounds(for: .mediaBox) } ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let content = analysed.compactMap(\.contentBounds)
        let left = content.map(\.minX).min().map { $0 - first.minX } ?? 72
        let right = content.map(\.maxX).max().map { first.maxX - $0 } ?? 72
        let top = content.map(\.maxY).max().map { first.maxY - $0 } ?? 72
        let margins = NSEdgeInsets(top: max(top, 18), left: max(left, 18), bottom: 36, right: max(right, 18))

        var blocks: [Block] = []
        for (index, page) in analysed.enumerated() {
            if index > 0 { blocks.append(.pageBreak) }
            let bounds = pages[index].bounds(for: .mediaBox)
            blocks += structure(page, body: body, left: bounds.minX + margins.left, right: bounds.maxX - margins.right,
                                top: bounds.maxY - margins.top)
        }
        return Document(pageSize: first.size, margins: margins, blocks: blocks)
    }

    static func blocks(_ doc: PDFDocument) -> [Block] { document(doc).blocks }

    // MARK: Page analysis

    struct Cell {
        var runs: [Run]
        var minX: CGFloat
        var maxX: CGFloat
        var text: String { runs.map(\.text).joined() }
    }

    struct Line {
        var cells: [Cell]
        var minY: CGFloat
        var maxY: CGFloat
        var baseline: CGFloat
        var size: CGFloat
        var count: Int

        var text: String { cells.map(\.text).joined(separator: " ") }
        var minX: CGFloat { cells.first!.minX }
        var maxX: CGFloat { cells.last!.maxX }
        var height: CGFloat { maxY - minY }
        /// Cells rejoined with a space, for lines that turn out not to be table rows.
        var runs: [Run] {
            cells.enumerated().flatMap { index, cell in index == 0 ? cell.runs : [Run(text: " ", style: cell.runs[0].style)] + cell.runs }
        }
    }

    private struct Placed {
        var rect: CGRect
        var jpeg: Data
    }

    private struct Analysis {
        var lines: [Line]
        var pictures: [Placed]
        var rules: [PDFPageStyles.Shape]
        var fills: [PDFPageStyles.Shape]
        var contentBounds: CGRect?
    }

    private struct Glyph {
        let char: Character
        let box: CGRect
        let style: Style
        let baseline: CGFloat
    }

    private static func analyse(_ page: PDFPage) -> Analysis {
        let bounds = page.bounds(for: .mediaBox)
        let styles = page.pageRef.map(PDFPageStyles.init)
        let shapes = styles?.shapes ?? []
        let rules = shapes.filter { min($0.rect.width, $0.rect.height) <= 2.5 && max($0.rect.width, $0.rect.height) > 2 }
        let fills = shapes.filter { !$0.stroked && min($0.rect.width, $0.rect.height) > 2.5 && hex($0.color) != "FFFFFF" }
        let links: [(CGRect, URL)] = page.annotations.compactMap { annotation in
            guard let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url else { return nil }
            return (annotation.bounds, url)
        }

        // Runs bucketed by baseline so each glyph only checks its neighbours.
        var buckets: [Int: [PDFPageStyles.TextRun]] = [:]
        for run in styles?.runs ?? [] { buckets[Int((run.start.y / 4).rounded(.down)), default: []].append(run) }
        func run(for box: CGRect) -> PDFPageStyles.TextRun? {
            let low = Int((box.minY / 4).rounded(.down)) - 1, high = Int((box.maxY / 4).rounded(.down)) + 1
            let expected = box.minY + box.height * 0.22
            var best: PDFPageStyles.TextRun?
            for candidate in (low...high).flatMap({ buckets[$0] ?? [] }) {
                let onLine = candidate.start.y >= box.minY - 1 && candidate.start.y <= box.maxY + 1
                let covers = box.midX >= candidate.start.x - 1 && box.midX <= candidate.endX + 1
                guard onLine && covers else { continue }
                if best == nil || abs(candidate.start.y - expected) < abs(best!.start.y - expected) { best = candidate }
            }
            return best
        }

        var glyphs: [Glyph] = []
        for i in 0..<page.numberOfCharacters {
            // A one-character selection keeps text and bounds on the same index.
            guard let selection = page.selection(for: NSRange(location: i, length: 1)),
                  let char = selection.string?.first, !char.isWhitespace else { continue }
            let box = selection.bounds(for: page)
            // Line-break indices select the glyph before them again.
            guard box.width > 0, glyphs.last.map({ $0.char != char || $0.box != box }) ?? true else { continue }
            var style = Style(size: (box.height / 1.25).rounded())
            var baseline = box.minY + box.height * 0.22
            if let run = run(for: box) {
                style = Self.style(fontName: run.font, size: run.size, color: run.color)
                baseline = run.start.y
            }
            let size = style.size
            style.underline = rules.contains { rule in
                rule.rect.height <= 2.5 && rule.rect.minX <= box.midX && rule.rect.maxX >= box.midX
                    && rule.rect.midY <= baseline + 1 && rule.rect.midY >= baseline - size * 0.3
            }
            style.link = links.first { $0.0.contains(CGPoint(x: box.midX, y: box.midY)) }?.1
            glyphs.append(Glyph(char: char, box: box, style: style, baseline: baseline))
        }

        // Pictures: crop each placed image from a render of the page.
        var pictures: [Placed] = []
        let placements = (styles?.images ?? []).filter { $0.width > 8 && $0.height > 8 }
            // A picture covering the page is a background or a scan under the text, not content.
            .filter { $0.width * $0.height < bounds.width * bounds.height * 0.8 || glyphs.isEmpty }
        if !placements.isEmpty, page.rotation == 0, let render = try? PDFConverter.render(page, dpi: 200) {
            let scale = CGFloat(render.width) / bounds.width
            for rect in placements {
                let clipped = rect.intersection(bounds)
                let crop = CGRect(x: (clipped.minX - bounds.minX) * scale, y: (bounds.maxY - clipped.maxY) * scale,
                                  width: clipped.width * scale, height: clipped.height * scale).integral
                if let image = render.cropping(to: crop), let jpeg = try? ImageConverter.encode(image, type: .jpeg, quality: 0.9) {
                    pictures.append(Placed(rect: clipped, jpeg: jpeg))
                }
            }
        }

        let lines = group(glyphs)
        let content = (lines.map { CGRect(x: $0.minX, y: $0.minY, width: $0.maxX - $0.minX, height: $0.height) } + pictures.map(\.rect))
            .filter { !$0.isEmpty }
        let contentBounds = content.dropFirst().reduce(content.first) { $0?.union($1) }
        return Analysis(lines: lines, pictures: pictures, rules: rules, fills: fills, contentBounds: contentBounds)
    }

    /// Lines top to bottom, each split into cells wherever there's a column-sized gap.
    private static func group(_ glyphs: [Glyph]) -> [Line] {
        // A glyph joins a line when its centre falls inside the line's vertical band.
        var groups: [[Glyph]] = []
        var band: ClosedRange<CGFloat>?
        for glyph in glyphs.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let current = band, current.contains(glyph.box.midY) {
                groups[groups.count - 1].append(glyph)
                band = min(current.lowerBound, glyph.box.minY)...max(current.upperBound, glyph.box.maxY)
            } else {
                groups.append([glyph])
                band = glyph.box.minY...glyph.box.maxY
            }
        }
        return groups.map { group in
            let sorted = group.sorted { $0.box.minX < $1.box.minX }
            let typical = sorted.map(\.box.width).sorted()[sorted.count / 2]
            let size = sorted.map(\.style.size).sorted()[sorted.count / 2]
            var cells: [Cell] = []
            var current = Cell(runs: [], minX: sorted[0].box.minX, maxX: sorted[0].box.maxX)
            var previous: Glyph?
            func append(_ text: String, _ style: Style) {
                if let last = current.runs.last, last.style == style {
                    current.runs[current.runs.count - 1].text += text
                } else {
                    current.runs.append(Run(text: text, style: style))
                }
            }
            for glyph in sorted {
                if let previous {
                    let gap = glyph.box.minX - previous.box.maxX
                    if gap > max(typical * 1.5, size * 0.9) {
                        cells.append(current)
                        current = Cell(runs: [], minX: glyph.box.minX, maxX: glyph.box.maxX)
                    } else if gap > typical * 0.2 {
                        // A space keeps underline and link only when both neighbours share them.
                        var space = previous.style
                        if previous.style.underline != glyph.style.underline { space.underline = false }
                        if previous.style.link != glyph.style.link { space.link = nil }
                        append(" ", space)
                    }
                }
                append(String(glyph.char), glyph.style)
                current.maxX = glyph.box.maxX
                previous = glyph
            }
            cells.append(current)
            let baselines = group.map(\.baseline).sorted()
            return Line(cells: cells, minY: group.map(\.box.minY).min()!, maxY: group.map(\.box.maxY).max()!,
                        baseline: baselines[baselines.count / 2], size: size, count: group.count)
        }
    }

    /// The size covering the most characters.
    private static func bodySize(_ lines: [Line]) -> CGFloat {
        var coverage: [CGFloat: Int] = [:]
        for line in lines { coverage[line.size.rounded(), default: 0] += line.count }
        return coverage.max { $0.value < $1.value }?.key ?? 12
    }

    // MARK: Structure

    private static func structure(_ page: Analysis, body: CGFloat, left: CGFloat, right: CGFloat, top: CGFloat) -> [Block] {
        let lines = page.lines
        var blocks: [Block] = []
        var open: (paragraph: Paragraph, lines: [Line])?
        var previousBottom = top
        var pictures = page.pictures.sorted { $0.rect.maxY > $1.rect.maxY }

        func flush() {
            guard let current = open else { return }
            var paragraph = current.paragraph
            let members = current.lines
            paragraph.indent = max(0, members.map(\.minX).min()! - left)
            if members.count > 1 {
                paragraph.firstLineIndent = members[0].minX - members[1...].map(\.minX).min()!
                let gaps = zip(members, members.dropFirst()).map { $0.baseline - $1.baseline }.sorted()
                let spacing = gaps[gaps.count / 2]
                if abs(spacing - (paragraph.runs.map(\.style.size).max() ?? 11) * 1.2) > 1.5 { paragraph.lineSpacing = spacing }
            }
            paragraph.alignment = alignment(of: members, left: left, right: right)
            blocks.append(.paragraph(paragraph))
            open = nil
        }

        func placePictures(above y: CGFloat) {
            while let picture = pictures.first, picture.rect.midY > y {
                pictures.removeFirst()
                flush()
                blocks.append(.picture(Picture(jpeg: picture.jpeg, size: picture.rect.size, indent: max(0, picture.rect.minX - left),
                                               spaceBefore: max(0, previousBottom - picture.rect.maxY))))
                previousBottom = picture.rect.minY
            }
        }

        var i = 0
        while i < lines.count {
            placePictures(above: lines[i].maxY)
            if let found = table(startingAt: i, in: page, left: left) {
                flush()
                var table = found.0
                table.spaceBefore = max(0, previousBottom - lines[i].maxY)
                blocks.append(.table(table))
                previousBottom = lines[i + found.1 - 1].minY
                i += found.1
                continue
            }
            let line = lines[i]
            let ratio = line.size / body
            let heading = line.text.count < 120 ? (ratio >= 1.6 ? 1 : ratio >= 1.3 ? 2 : ratio >= 1.12 ? 3 : 0) : 0
            let startsItem = line.text.range(of: #"^([•▪◦‣\-–*]|\d+[.)])\s"#, options: .regularExpression) != nil
            // Continue the paragraph when the next line sits close below in the same size.
            if var current = open, heading == current.paragraph.heading, !startsItem,
               abs(line.size - current.lines.last!.size) < 0.5,
               current.lines.last!.minY - line.maxY < line.height * 0.9 {
                if current.paragraph.text.hasSuffix("-") {
                    current.paragraph.runs[current.paragraph.runs.count - 1].text.removeLast()
                } else {
                    current.paragraph.runs.append(Run(text: " ", style: current.paragraph.runs.last!.style))
                }
                current.paragraph.runs += line.runs
                current.lines.append(line)
                open = current
            } else {
                flush()
                open = (Paragraph(runs: line.runs, heading: heading, spaceBefore: max(0, previousBottom - line.maxY)), [line])
            }
            previousBottom = line.minY
            i += 1
        }
        placePictures(above: -.infinity)
        flush()
        return blocks.map(merged)
    }

    /// Joins neighbouring runs that ended up with the same style.
    private static func merged(_ block: Block) -> Block {
        func merge(_ runs: [Run]) -> [Run] {
            var merged: [Run] = []
            for run in runs {
                if let last = merged.last, last.style == run.style { merged[merged.count - 1].text += run.text } else { merged.append(run) }
            }
            return merged
        }
        switch block {
        case .paragraph(var paragraph):
            paragraph.runs = merge(paragraph.runs)
            return .paragraph(paragraph)
        case .table(var table):
            table.rows = table.rows.map { $0.map(merge) }
            return .table(table)
        default:
            return block
        }
    }

    private static func alignment(of lines: [Line], left: CGFloat, right: CGFloat) -> Alignment {
        let width = right - left
        if lines.count > 1 {
            // Every line but the last reaching the right edge means justified.
            let full = lines.dropLast().allSatisfy { right - $0.maxX < 4 && $0.minX - left < width * 0.2 }
            if full && right - lines.last!.maxX > 8 { return .justified }
        }
        let leftGaps = lines.map { $0.minX - left }, rightGaps = lines.map { right - $0.maxX }
        if zip(leftGaps, rightGaps).allSatisfy({ abs($0 - $1) < 6 && $0 > 12 }) { return .center }
        if rightGaps.allSatisfy({ $0 < 4 }) && leftGaps.allSatisfy({ $0 > width * 0.3 }) { return .right }
        return .left
    }

    /// A run of at least two closely spaced lines whose cells fall into the same columns.
    private static func table(startingAt start: Int, in page: Analysis, left: CGFloat) -> (Table, Int)? {
        let lines = page.lines
        guard lines[start].cells.count >= 2 else { return nil }
        var rows = [lines[start]]
        var end = start + 1
        while end < lines.count {
            let line = lines[end], previous = rows.last!
            guard previous.minY - line.maxY < max(previous.height, line.height) * 2.2 else { break }
            if line.cells.count >= 2 {
                rows.append(line)
            } else if line.cells[0].minX > rows[0].cells[1].minX - 2 {
                // Text wrapping inside a later column belongs to the row above.
                rows.append(line)
            } else {
                break
            }
            end += 1
        }
        let complete = rows.filter { $0.cells.count >= 2 }
        guard complete.count >= 2 else { return nil }

        // Columns come from the fullest rows: the horizontal spans their cells cover.
        let widest = complete.map(\.cells.count).max()!
        var spans: [ClosedRange<CGFloat>] = []
        for cell in complete.filter({ $0.cells.count == widest }).flatMap(\.cells).sorted(by: { $0.minX < $1.minX }) {
            if let last = spans.last, cell.minX <= last.upperBound + 2 {
                spans[spans.count - 1] = last.lowerBound...max(last.upperBound, cell.maxX)
            } else {
                spans.append(cell.minX...cell.maxX)
            }
        }
        guard spans.count >= 2 else { return nil }

        func column(for cell: Cell) -> Int {
            // Most overlap wins; with none, the nearest centre.
            let overlaps = spans.map { max(0, min($0.upperBound, cell.maxX) - max($0.lowerBound, cell.minX)) }
            if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 { return best }
            let mid = (cell.minX + cell.maxX) / 2
            return spans.indices.min { abs((spans[$0].lowerBound + spans[$0].upperBound) / 2 - mid) < abs((spans[$1].lowerBound + spans[$1].upperBound) / 2 - mid) }!
        }

        var edges = Array(repeating: (lefts: [CGFloat](), rights: [CGFloat]()), count: spans.count)
        for line in complete {
            for cell in line.cells {
                let c = column(for: cell)
                edges[c].lefts.append(cell.minX)
                edges[c].rights.append(cell.maxX)
            }
        }
        // Whichever edge the cells share is the one they're aligned to.
        let alignments = edges.map { edge -> Alignment in
            func spread(_ values: [CGFloat]) -> CGFloat { (values.max() ?? 0) - (values.min() ?? 0) }
            let leftSpread = spread(edge.lefts), rightSpread = spread(edge.rights)
            let centers = zip(edge.lefts, edge.rights).map { ($0 + $1) / 2 }
            if leftSpread <= 2 || leftSpread <= rightSpread { return .left }
            if rightSpread <= 2 || rightSpread < spread(centers) { return .right }
            return .center
        }

        var grid: [[[Run]]] = []
        var bands: [ClosedRange<CGFloat>] = []
        for line in rows {
            if line.cells.count == 1, !grid.isEmpty {
                let c = column(for: line.cells[0])
                if let last = grid[grid.count - 1][c].last { grid[grid.count - 1][c].append(Run(text: " ", style: last.style)) }
                grid[grid.count - 1][c] += line.cells[0].runs
                bands[bands.count - 1] = line.minY...bands[bands.count - 1].upperBound
                continue
            }
            var row = Array(repeating: [Run](), count: spans.count)
            for cell in line.cells {
                let c = column(for: cell)
                if let last = row[c].last { row[c].append(Run(text: " ", style: last.style)) }
                row[c] += cell.runs
            }
            grid.append(row)
            bands.append(line.minY...line.maxY)
        }

        // Each column runs to the start of the next, with a little room after the last.
        let widths = spans.indices.map { i -> CGFloat in
            let next = i + 1 < spans.count ? spans[i + 1].lowerBound : spans[i].upperBound + 8
            return next - spans[i].lowerBound
        }
        let box = CGRect(x: spans[0].lowerBound - 6, y: bands.last!.lowerBound - 6,
                         width: spans.last!.upperBound - spans[0].lowerBound + 12, height: bands[0].upperBound - bands.last!.lowerBound + 12)
        let borders = page.rules.contains { $0.rect.intersects(box) }
        let shading = bands.map { band in
            spans.map { span -> String? in
                let centre = CGPoint(x: (span.lowerBound + span.upperBound) / 2, y: (band.lowerBound + band.upperBound) / 2)
                return page.fills.last { $0.rect.contains(centre) }.map { hex($0.color) }
            }
        }
        let text = grid.map { $0.map { $0.map(\.text).joined() } }
        let firstRowBold = grid[0].allSatisfy { $0.allSatisfy { $0.style.bold || $0.text == " " } }
        // Bold isn't always readable, so a number-free first row above numeric rows also counts.
        let hasDigits = { (row: [String]) in row.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil } }
        let header = firstRowBold || (!hasDigits(text[0]) && text.dropFirst().contains(where: hasDigits))
        let table = Table(rows: grid, columnWidths: widths, alignments: alignments, header: header, borders: borders,
                          shading: shading, indent: max(0, spans[0].lowerBound - left))
        return (table, end - start)
    }

    // MARK: Fonts and colours

    /// "ABCDEF+Calibri-BoldItalic" → Calibri, bold, italic.
    static func style(fontName: String, size: CGFloat, color: CGColor) -> Style {
        let name = fontName.replacingOccurrences(of: #"^[A-Z]{6}\+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "-Identity-H", with: "")
        let lower = name.lowercased()
        var style = Style(size: (size * 2).rounded() / 2)
        style.bold = ["bold", "black", "heavy", "semibold", "demi"].contains { lower.contains($0) }
        style.italic = lower.contains("italic") || lower.contains("oblique")
        style.font = family(of: name)
        let rgb = hex(color)
        style.color = rgb == "000000" ? nil : rgb
        return style
    }

    private static func family(of postScriptName: String) -> String {
        // The system UI font isn't available to other apps.
        if postScriptName.hasPrefix(".") { return "Helvetica Neue" }
        if let font = NSFont(name: postScriptName, size: 12), let family = font.familyName, !family.hasPrefix(".") { return family }
        // Not installed: derive it from the name, e.g. "TimesNewRomanPS-BoldMT" → "Times New Roman".
        var base = String(postScriptName.split(whereSeparator: { $0 == "-" || $0 == "," }).first ?? Substring(postScriptName))
        for suffix in ["PSMT", "MT", "PS"] where base.hasSuffix(suffix) && base.count > suffix.count + 2 {
            base.removeLast(suffix.count)
        }
        return base.replacingOccurrences(of: #"(?<=[a-z])(?=[A-Z])"#, with: " ", options: .regularExpression)
    }

    static func hex(_ color: CGColor) -> String {
        let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int(rgb.redComponent * 255 + 0.5), Int(rgb.greenComponent * 255 + 0.5), Int(rgb.blueComponent * 255 + 0.5))
    }

    // MARK: Markdown

    static func markdown(_ blocks: [Block]) -> String {
        func inline(_ runs: [Run]) -> String {
            runs.map { run in
                let text = run.text, trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return text }
                var piece = trimmed
                if run.style.bold && run.style.italic { piece = "***\(piece)***" }
                else if run.style.bold { piece = "**\(piece)**" }
                else if run.style.italic { piece = "*\(piece)*" }
                if let link = run.style.link { piece = "[\(piece)](\(link.absoluteString))" }
                return (text.hasPrefix(" ") ? " " : "") + piece + (text.hasSuffix(" ") ? " " : "")
            }.joined()
        }
        return blocks.compactMap { block -> String? in
            switch block {
            case .paragraph(let paragraph):
                if paragraph.heading > 0 { return String(repeating: "#", count: paragraph.heading) + " " + paragraph.text }
                return inline(paragraph.runs)
            case .table(let table):
                func row(_ cells: [[Run]]) -> String { "| " + cells.map { inline($0).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |" }
                guard let first = table.rows.first else { return nil }
                let rule = "|" + table.alignments.map { $0 == .right ? " ---: |" : $0 == .center ? " :---: |" : " --- |" }.joined()
                return ([row(first), rule] + table.rows.dropFirst().map(row)).joined(separator: "\n")
            case .picture, .pageBreak:
                return nil
            }
        }
        .joined(separator: "\n\n") + "\n"
    }
}
