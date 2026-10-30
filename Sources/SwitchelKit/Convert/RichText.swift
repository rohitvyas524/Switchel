import AppKit

/// Turns attributed text into Markdown or XHTML by walking paragraphs and inferring
/// headings from font size relative to the body text.
enum RichText {
    struct Run {
        var text: String
        var bold = false
        var italic = false
        var link: URL?
    }

    struct Paragraph {
        /// 0 for body text, 1–3 for headings.
        var heading = 0
        var listMarker: String?
        var runs: [Run] = []
        var plainText: String { runs.map(\.text).joined() }
    }

    static func paragraphs(_ text: NSAttributedString) -> [Paragraph] {
        let string = text.string as NSString
        let full = NSRange(location: 0, length: string.length)

        // The body size is the one covering the most characters.
        var coverage: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: full) { value, range, _ in
            coverage[((value as? NSFont)?.pointSize ?? 12).rounded(), default: 0] += range.length
        }
        let body = coverage.max { $0.value < $1.value }?.key ?? 12

        var result: [Paragraph] = []
        string.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { return }
            var paragraph = Paragraph()
            var largest: CGFloat = 0
            text.enumerateAttributes(in: range) { attributes, runRange, _ in
                let font = attributes[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                let link = attributes[.link] as? URL ?? (attributes[.link] as? String).flatMap(URL.init(string:))
                paragraph.runs.append(Run(text: string.substring(with: runRange), bold: traits.contains(.bold),
                                          italic: traits.contains(.italic), link: link))
                largest = max(largest, font?.pointSize ?? body)
            }
            guard !paragraph.plainText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

            if let list = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last {
                paragraph.listMarker = list.isOrdered ? "1." : "-"
                stripListMarker(&paragraph)
            }
            let ratio = largest / body
            if paragraph.listMarker == nil, paragraph.plainText.count < 200 {
                paragraph.heading = ratio >= 1.6 ? 1 : ratio >= 1.3 ? 2 : ratio >= 1.12 ? 3 : 0
            }
            result.append(paragraph)
        }
        return result
    }

    /// AppKit inlines list markers as "\t•\t" at the start of each item.
    private static func stripListMarker(_ paragraph: inout Paragraph) {
        guard var first = paragraph.runs.first?.text,
              let marker = first.range(of: #"^\t?[^\t]{0,6}\t"#, options: .regularExpression) else { return }
        first.removeSubrange(marker)
        paragraph.runs[0].text = first
    }

    static func markdown(_ text: NSAttributedString) -> String {
        paragraphs(text).map { paragraph in
            let body = paragraph.runs.map { run -> String in
                var piece = run.text.replacingOccurrences(of: "*", with: "\\*")
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return piece }
                if paragraph.heading == 0 {
                    if run.bold && run.italic { piece = "***\(trimmed)***" }
                    else if run.bold { piece = "**\(trimmed)**" }
                    else if run.italic { piece = "*\(trimmed)*" }
                }
                if let link = run.link { piece = "[\(trimmed)](\(link.absoluteString))" }
                return piece
            }.joined()
            if paragraph.heading > 0 { return String(repeating: "#", count: paragraph.heading) + " " + body }
            if let marker = paragraph.listMarker { return "\(marker) \(body)" }
            return body
        }
        .joined(separator: "\n\n")
        .replacingOccurrences(of: "\n\n- ", with: "\n- ")
        .replacingOccurrences(of: "\n\n1. ", with: "\n1. ") + "\n"
    }

    /// Body content for an XHTML page (EPUB chapters).
    static func xhtmlBody(_ text: NSAttributedString) -> String {
        var html: [String] = []
        var openList: String?
        for paragraph in paragraphs(text) {
            let inline = paragraph.runs.map { run -> String in
                var piece = run.text.xmlEscaped
                if run.bold { piece = "<strong>\(piece)</strong>" }
                if run.italic { piece = "<em>\(piece)</em>" }
                if let link = run.link { piece = "<a href=\"\(link.absoluteString.xmlEscaped)\">\(piece)</a>" }
                return piece
            }.joined()
            let listTag = paragraph.listMarker.map { $0 == "-" ? "ul" : "ol" }
            if openList != listTag {
                if let openList { html.append("</\(openList)>") }
                if let listTag { html.append("<\(listTag)>") }
                openList = listTag
            }
            if listTag != nil { html.append("<li>\(inline)</li>") }
            else if paragraph.heading > 0 { html.append("<h\(paragraph.heading)>\(inline)</h\(paragraph.heading)>") }
            else { html.append("<p>\(inline)</p>") }
        }
        if let openList { html.append("</\(openList)>") }
        return html.joined(separator: "\n")
    }
}

/// A small CommonMark subset: headings, paragraphs, lists, quotes, code, rules, emphasis, links, images.
enum Markdown {
    static func html(_ source: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var openList: String?
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
            paragraph = []
        }
        func closeList() {
            if let openList { html.append("</\(openList)>") }
            openList = nil
        }

        for line in source.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    html.append("<pre><code>\(lines.joined(separator: "\n").xmlEscaped)</code></pre>")
                    code = nil
                } else {
                    flushParagraph()
                    closeList()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(line); continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                closeList()
            } else if let match = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flushParagraph()
                closeList()
                let level = trimmed[match].count - 1
                let title = trimmed[match.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                html.append("<h\(level)>\(inline(title))</h\(level)>")
            } else if trimmed.range(of: #"^([-*_])( ?\1){2,}$"#, options: .regularExpression) != nil {
                flushParagraph()
                closeList()
                html.append("<hr/>")
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                closeList()
                html.append("<blockquote><p>\(inline(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))</p></blockquote>")
            } else if let item = listItem(trimmed) {
                flushParagraph()
                if openList != item.tag {
                    closeList()
                    html.append("<\(item.tag)>")
                    openList = item.tag
                }
                html.append("<li>\(inline(item.text))</li>")
            } else {
                closeList()
                paragraph.append(trimmed)
            }
        }
        if let lines = code { html.append("<pre><code>\(lines.joined(separator: "\n").xmlEscaped)</code></pre>") }
        flushParagraph()
        closeList()
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\n\(html.joined(separator: "\n"))\n</body></html>"
    }

    private static func listItem(_ line: String) -> (tag: String, text: String)? {
        if let marker = line.range(of: #"^[-*+] "#, options: .regularExpression) {
            return ("ul", String(line[marker.upperBound...]))
        }
        if let marker = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
            return ("ol", String(line[marker.upperBound...]))
        }
        return nil
    }

    static func inline(_ text: String) -> String {
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img alt=\"$1\" src=\"$2\"/>"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
            (#"\*\*\*(.+?)\*\*\*"#, "<strong><em>$1</em></strong>"),
            (#"\*\*(.+?)\*\*"#, "<strong>$1</strong>"),
            (#"__(.+?)__"#, "<strong>$1</strong>"),
            (#"(?<![\w\\])\*(?!\s)(.+?)(?<!\s)\*"#, "<em>$1</em>"),
            (#"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#, "<em>$1</em>"),
            (#"~~(.+?)~~"#, "<del>$1</del>"),
            (#"\\\*"#, "*"),
        ]
        return rules.reduce(text.xmlEscaped) { result, rule in
            result.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
        }
    }
}
