import Foundation

/// Rows of cell text; the first sheet of a workbook.
typealias Table = [[String]]

/// Hand-written EPUB, XLSX, ODS and PPTX packages: just the parts each format requires.
enum Packages {
    // MARK: EPUB

    struct Chapter {
        var title: String
        var body: String  // XHTML body content
    }

    static func writeEPUB(_ chapters: [Chapter], title: String, to url: URL) async throws {
        let folder = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID().uuidString
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        var files: [String: String] = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """,
            "OEBPS/style.css": "body { font-family: serif; line-height: 1.5; } h1, h2, h3 { font-family: sans-serif; }",
        ]
        let manifest = chapters.indices.map {
            "<item id=\"c\($0 + 1)\" href=\"chapter\($0 + 1).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spine = chapters.indices.map { "<itemref idref=\"c\($0 + 1)\"/>" }.joined(separator: "\n")
        let navItems = chapters.enumerated().map {
            "<li><a href=\"chapter\($0.offset + 1).xhtml\">\($0.element.title.xmlEscaped)</a></li>"
        }.joined(separator: "\n")
        files["OEBPS/content.opf"] = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="id">urn:uuid:\(id)</dc:identifier>
        <dc:title>\(title.xmlEscaped)</dc:title>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">\(modified)</meta>
        </metadata>
        <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="css" href="style.css" media-type="text/css"/>
        \(manifest)
        </manifest>
        <spine>
        \(spine)
        </spine>
        </package>
        """
        files["OEBPS/nav.xhtml"] = xhtml(title: title, body: "<nav epub:type=\"toc\"><ol>\n\(navItems)\n</ol></nav>")
        for (i, chapter) in chapters.enumerated() {
            files["OEBPS/chapter\(i + 1).xhtml"] = xhtml(title: chapter.title, body: chapter.body)
        }
        try write(files, into: folder)
        try await Zip.create(url, fromContentsOf: folder, storedFirst: "mimetype")
    }

    private static func xhtml(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(title.xmlEscaped)</title><link rel="stylesheet" href="style.css" type="text/css"/></head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// Extracts an EPUB and returns its chapter files in reading order, plus the folder to delete afterwards.
    static func epubChapters(_ url: URL) async throws -> (chapters: [URL], folder: URL) {
        let folder = try Output.temporaryFolder()
        try await Zip.extract(url, to: folder)
        let container = try XMLDocument(contentsOf: folder.appendingPathComponent("META-INF/container.xml"))
        guard let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw SwitchelError("\(url.lastPathComponent) isn't a valid EPUB")
        }
        let opfURL = folder.appendingPathComponent(opfPath)
        let opf = try XMLDocument(contentsOf: opfURL)
        var hrefs: [String: String] = [:]
        for item in try opf.nodes(forXPath: "//*[local-name()='item']") {
            guard let element = item as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue else { continue }
            hrefs[id] = href
        }
        let base = opfURL.deletingLastPathComponent()
        let chapters = try opf.nodes(forXPath: "//*[local-name()='itemref']/@idref").compactMap { node -> URL? in
            guard let id = node.stringValue, let href = hrefs[id]?.removingPercentEncoding else { return nil }
            return base.appendingPathComponent(href)
        }
        return (chapters, folder)
    }

    // MARK: XLSX

    /// How a cell looks. nil fields mean Excel's defaults.
    struct CellFormat: Hashable {
        var bold = false
        var italic = false
        var font: String?
        var size: CGFloat?
        var color: String?  // "RRGGBB"
        var fill: String?
        var alignment: String?  // "left", "center", "right"
        var border = false
    }

    /// Writes values exactly as given: text stays text (leading zeros, long IDs, codes), and numbers keep
    /// their written decimals. Optional formats style cells; columns are sized to fit their contents.
    static func writeXLSX(_ table: Table, to url: URL, formats: [[CellFormat?]]? = nil, columnWidths: [CGFloat]? = nil) async throws {
        // Styles are deduplicated: index 0 is Excel's default.
        struct Key: Hashable { var format: CellFormat; var decimals: Int }
        var keys: [Key] = [Key(format: CellFormat(), decimals: 0)]
        var index: [Key: Int] = [keys[0]: 0]
        func style(_ format: CellFormat?, decimals: Int) -> Int {
            let key = Key(format: format ?? CellFormat(), decimals: decimals)
            if let existing = index[key] { return existing }
            keys.append(key)
            index[key] = keys.count - 1
            return keys.count - 1
        }

        var rows = ""
        for (r, row) in table.enumerated() {
            var cells = ""
            for (c, value) in row.enumerated() {
                let format = formats.flatMap { r < $0.count && c < $0[r].count ? $0[r][c] : nil }
                let ref = "\(columnName(c))\(r + 1)"
                if let decimals = numericDecimals(value) {
                    let s = style(format, decimals: decimals)
                    cells += "<c r=\"\(ref)\"\(s > 0 ? " s=\"\(s)\"" : "")><v>\(value)</v></c>"
                } else if !value.isEmpty || format != nil {
                    let s = style(format, decimals: 0)
                    cells += "<c r=\"\(ref)\" t=\"inlineStr\"\(s > 0 ? " s=\"\(s)\"" : "")><is><t xml:space=\"preserve\">\(value.xmlEscaped)</t></is></c>"
                }
            }
            rows += "<row r=\"\(r + 1)\">\(cells)</row>"
        }

        // Column widths in characters: given, or the longest line in each column.
        let columnCount = table.map(\.count).max() ?? 0
        let widths: [CGFloat] = columnWidths ?? (0..<columnCount).map { c in
            let longest = table.map { c < $0.count ? $0[c].components(separatedBy: "\n").map(\.count).max() ?? 0 : 0 }.max() ?? 0
            return min(max(CGFloat(longest) * 1.1 + 2, 8), 80)
        }
        let cols = widths.isEmpty ? "" : "<cols>" + widths.enumerated().map { "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\(String(format: "%.1f", $0.element))\" customWidth=\"1\"/>" }.joined() + "</cols>"

        // Fonts, fills and number formats each get their own deduplicated lists.
        var fonts: [String] = ["<font><sz val=\"11\"/><name val=\"Calibri\"/></font>"]
        var fills: [String] = ["<fill><patternFill patternType=\"none\"/></fill>", "<fill><patternFill patternType=\"gray125\"/></fill>"]
        var numberFormats: [Int: String] = [:]
        var xfs: [String] = []
        for key in keys {
            let f = key.format
            var font = "<font>" + (f.bold ? "<b/>" : "") + (f.italic ? "<i/>" : "")
            font += "<sz val=\"\(f.size.map { String(format: "%g", $0) } ?? "11")\"/>" + (f.color.map { "<color rgb=\"FF\($0)\"/>" } ?? "")
            font += "<name val=\"\((f.font ?? "Calibri").xmlEscaped)\"/></font>"
            let fontId = fonts.firstIndex(of: font) ?? { fonts.append(font); return fonts.count - 1 }()
            var fillId = 0
            if let color = f.fill {
                let fill = "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF\(color)\"/><bgColor indexed=\"64\"/></patternFill></fill>"
                fillId = fills.firstIndex(of: fill) ?? { fills.append(fill); return fills.count - 1 }()
            }
            let numFmtId = key.decimals > 0 ? 163 + key.decimals : 0
            if key.decimals > 0 { numberFormats[numFmtId] = "0." + String(repeating: "0", count: key.decimals) }
            let alignment = f.alignment.map { "<alignment horizontal=\"\($0)\" vertical=\"top\" wrapText=\"1\"/>" } ?? ""
            xfs.append("<xf numFmtId=\"\(numFmtId)\" fontId=\"\(fontId)\" fillId=\"\(fillId)\" borderId=\"\(f.border ? 1 : 0)\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\" applyAlignment=\"1\">\(alignment)</xf>")
        }
        let side = { (name: String) in "<\(name) style=\"thin\"><color rgb=\"FF808080\"/></\(name)>" }
        let numFmts = numberFormats.isEmpty ? "" : "<numFmts count=\"\(numberFormats.count)\">" + numberFormats.sorted { $0.key < $1.key }.map { "<numFmt numFmtId=\"\($0.key)\" formatCode=\"\($0.value)\"/>" }.joined() + "</numFmts>"
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\(numFmts)<fonts count="\(fonts.count)">\(fonts.joined())</fonts><fills count="\(fills.count)">\(fills.joined())</fills><borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border>\(side("left"))\(side("right"))\(side("top"))\(side("bottom"))<diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="\(xfs.count)">\(xfs.joined())</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """

        let ns = "http://schemas.openxmlformats.org"
        try await writePackage([
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="\(ns)/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
            """,
            "_rels/.rels": relationships([("rId1", "officeDocument", "xl/workbook.xml")]),
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="\(ns)/spreadsheetml/2006/main" xmlns:r="\(ns)/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": relationships([("rId1", "worksheet", "worksheets/sheet1.xml"), ("rId2", "styles", "styles.xml")]),
            "xl/styles.xml": styles,
            "xl/worksheets/sheet1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="\(ns)/spreadsheetml/2006/main">\(cols)<sheetData>\(rows)</sheetData></worksheet>
            """,
        ], to: url)
    }

    /// Reads the first sheet as Excel displays it: dates, percentages and currency come out formatted.
    static func readXLSX(_ url: URL) async throws -> Table {
        let folder = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Zip.extract(url, to: folder)

        var shared: [String] = []
        if let strings = try? XMLDocument(contentsOf: folder.appendingPathComponent("xl/sharedStrings.xml")) {
            shared = try strings.nodes(forXPath: "//*[local-name()='si']").map { item in
                try item.nodes(forXPath: ".//*[local-name()='t']").compactMap(\.stringValue).joined()
            }
        }
        // Each cell style's number format code.
        var formatCodes: [String] = []
        if let styles = try? XMLDocument(contentsOf: folder.appendingPathComponent("xl/styles.xml")) {
            var custom: [Int: String] = [:]
            for node in try styles.nodes(forXPath: "//*[local-name()='numFmt']") {
                guard let element = node as? XMLElement, let id = element.attribute(forName: "numFmtId")?.stringValue.flatMap(Int.init),
                      let code = element.attribute(forName: "formatCode")?.stringValue else { continue }
                custom[id] = code
            }
            formatCodes = try styles.nodes(forXPath: "//*[local-name()='cellXfs']/*[local-name()='xf']").map { node in
                let id = (node as? XMLElement)?.attribute(forName: "numFmtId")?.stringValue.flatMap(Int.init) ?? 0
                return custom[id] ?? ExcelFormat.builtIn[id] ?? "General"
            }
        }

        let sheets = folder.appendingPathComponent("xl/worksheets")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sheets.path)) ?? []
        guard let first = names.filter({ $0.hasSuffix(".xml") }).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).first else {
            throw SwitchelError("\(url.lastPathComponent) has no sheets")
        }
        let sheet = try XMLDocument(contentsOf: sheets.appendingPathComponent(first))

        var table: Table = []
        for rowNode in try sheet.nodes(forXPath: "//*[local-name()='row']") {
            guard let row = rowNode as? XMLElement else { continue }
            let index = (row.attribute(forName: "r")?.stringValue).flatMap(Int.init).map { $0 - 1 } ?? table.count
            var cells: [String] = []
            for cellNode in try row.nodes(forXPath: "./*[local-name()='c']") {
                guard let cell = cellNode as? XMLElement else { continue }
                let column = (cell.attribute(forName: "r")?.stringValue).map(columnIndex) ?? cells.count
                let raw = try cell.nodes(forXPath: "./*[local-name()='v']").first?.stringValue
                let value: String
                switch cell.attribute(forName: "t")?.stringValue {
                case "s": value = raw.flatMap(Int.init).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                case "inlineStr": value = try cell.nodes(forXPath: ".//*[local-name()='t']").compactMap(\.stringValue).joined()
                case "b": value = raw == "1" ? "TRUE" : "FALSE"
                case "str", "e": value = raw ?? ""
                default:
                    let style = (cell.attribute(forName: "s")?.stringValue).flatMap(Int.init) ?? 0
                    let code = formatCodes.indices.contains(style) ? formatCodes[style] : "General"
                    value = raw.map { ExcelFormat.display($0, format: code) } ?? ""
                }
                while cells.count < column { cells.append("") }
                cells.append(value)
            }
            while table.count < index { table.append([]) }
            table.append(cells)
        }
        return table
    }

    static func columnName(_ index: Int) -> String {
        var name = "", n = index + 1
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    /// "AB12" → 27
    private static func columnIndex(_ reference: String) -> Int {
        reference.prefix { $0.isLetter }.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    /// The decimal places of a plain number Excel can store without changing how it reads,
    /// or nil for anything that must stay text: leading zeros, more than 15 digits, signs, separators, exponents.
    static func numericDecimals(_ value: String) -> Int? {
        guard value.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        guard value.filter(\.isNumber).count <= 15 else { return nil }
        return value.split(separator: ".").dropFirst().first?.count ?? 0
    }

    static func isNumber(_ value: String) -> Bool { numericDecimals(value) != nil }

    // MARK: ODS

    static func writeODS(_ table: Table, to url: URL) async throws {
        let rows = table.map { row in
            let cells = row.map { value -> String in
                if isNumber(value) {
                    return "<table:table-cell office:value-type=\"float\" office:value=\"\(value)\"><text:p>\(value)</text:p></table:table-cell>"
                }
                return "<table:table-cell office:value-type=\"string\"><text:p>\(value.xmlEscaped)</text:p></table:table-cell>"
            }.joined()
            return "<table:table-row>\(cells)</table:table-row>"
        }.joined()
        let mime = "application/vnd.oasis.opendocument.spreadsheet"
        try await writePackage([
            "mimetype": mime,
            "META-INF/manifest.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="\(mime)"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
            """,
            "content.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet><table:table table:name="Sheet1">\(rows)</table:table></office:spreadsheet></office:body></office:document-content>
            """,
        ], to: url, storedFirst: "mimetype")
    }

    static func readODS(_ url: URL) async throws -> Table {
        let folder = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Zip.extract(url, to: folder)
        let content = try XMLDocument(contentsOf: folder.appendingPathComponent("content.xml"))
        guard let sheet = try content.nodes(forXPath: "//*[local-name()='table']").first else { return [] }

        var table: Table = []
        for rowNode in try sheet.nodes(forXPath: ".//*[local-name()='table-row']") {
            guard let row = rowNode as? XMLElement else { continue }
            var cells: [String] = []
            for cellNode in try row.nodes(forXPath: "./*[local-name()='table-cell' or local-name()='covered-table-cell']") {
                guard let cell = cellNode as? XMLElement else { continue }
                let text = try cell.nodes(forXPath: "./*[local-name()='p']").compactMap(\.stringValue).joined(separator: "\n")
                // Empty trailing cells are stored as one cell repeated hundreds of times.
                let repeats = min(Int(cell.attribute(forName: "table:number-columns-repeated")?.stringValue ?? "") ?? 1, text.isEmpty ? 1 : 1000)
                cells += Array(repeating: text, count: repeats)
            }
            while cells.last == "" { cells.removeLast() }
            let repeats = Int(row.attribute(forName: "table:number-rows-repeated")?.stringValue ?? "") ?? 1
            table += Array(repeating: cells, count: cells.isEmpty ? 1 : min(repeats, 1000))
        }
        while table.last?.isEmpty == true { table.removeLast() }
        return table
    }

    // MARK: PPTX

    enum Slide {
        /// A full-bleed JPEG: looks exactly like the page, but isn't editable.
        case picture(Data)
        /// Editable text; headings are set larger.
        case text([RichText.Paragraph])
    }

    /// `slideSize` is in points.
    static func writePPTX(slides: [Slide], slideSize: CGSize, to url: URL) async throws {
        // Slides are 13.33" wide; PowerPoint allows 1"–56" on each side.
        let emuPerPoint = 12_192_000 / max(slideSize.width, 1)
        let cx = 12_192_000, cy = min(max(Int(slideSize.height * emuPerPoint), 914_400), 51_206_400)
        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        let pml = "application/vnd.openxmlformats-officedocument.presentationml"

        var files: [String: String] = [:]
        var slideOverrides = "", slideIDs = ""
        var presentationRels: [(String, String, String)] = [("rId1", "slideMaster", "slideMasters/slideMaster1.xml"), ("rId2", "theme", "theme/theme1.xml")]
        var pictures: [Int: Data] = [:]
        for (offset, slide) in slides.enumerated() {
            let i = offset + 1
            slideOverrides += "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"\(pml).slide+xml\"/>"
            slideIDs += "<p:sldId id=\"\(255 + i)\" r:id=\"rId\(i + 2)\"/>"
            presentationRels.append(("rId\(i + 2)", "slide", "slides/slide\(i).xml"))
            var rels: [(String, String, String)] = [("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]
            let content: String
            switch slide {
            case .picture(let jpeg):
                pictures[i] = jpeg
                rels.append(("rId2", "image", "../media/image\(i).jpeg"))
                content = "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Page \(i)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
            case .text(let paragraphs):
                let margin = 457_200
                let body = paragraphs.map { paragraph -> String in
                    let size = [1600, 3200, 2600, 2000][min(paragraph.heading, 3)]
                    let runs = paragraph.runs.map { run in
                        "<a:r><a:rPr lang=\"en-US\" sz=\"\(size)\" b=\"\(run.bold || paragraph.heading > 0 ? 1 : 0)\" i=\"\(run.italic ? 1 : 0)\"/><a:t>\(run.text.xmlEscaped)</a:t></a:r>"
                    }.joined()
                    let bullet = paragraph.listMarker == nil ? "<a:pPr><a:buNone/></a:pPr>" : "<a:pPr marL=\"342900\" indent=\"-342900\"><a:buChar char=\"•\"/></a:pPr>"
                    return "<a:p>\(bullet)\(runs)</a:p>"
                }.joined()
                content = "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Text \(i)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(margin)\" y=\"\(margin)\"/><a:ext cx=\"\(cx - margin * 2)\" cy=\"\(cy - margin * 2)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr wrap=\"square\"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(body.isEmpty ? "<a:p/>" : body)</p:txBody></p:sp>"
            }
            files["ppt/slides/slide\(i).xml"] = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld \(ns)><p:cSld><p:spTree>\(group)\(content)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """
            files["ppt/slides/_rels/slide\(i).xml.rels"] = relationships(rels)
        }
        files["[Content_Types].xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/><Override PartName="/ppt/presentation.xml" ContentType="\(pml).presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="\(pml).slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="\(pml).slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\(slideOverrides)</Types>
        """
        files["_rels/.rels"] = relationships([("rId1", "officeDocument", "ppt/presentation.xml")])
        files["ppt/presentation.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(cx)" cy="\(cy)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """
        files["ppt/_rels/presentation.xml.rels"] = relationships(presentationRels)
        files["ppt/slideMasters/slideMaster1.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster \(ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\(group)</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
        """
        files["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = relationships([
            ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml"),
        ])
        files["ppt/slideLayouts/slideLayout1.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout \(ns) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """
        files["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = relationships([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")])
        files["ppt/theme/theme1.xml"] = theme

        let folder = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(files, into: folder)
        let media = folder.appendingPathComponent("ppt/media")
        if !pictures.isEmpty { try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true) }
        for (i, jpeg) in pictures {
            try jpeg.write(to: media.appendingPathComponent("image\(i).jpeg"))
        }
        try await Zip.create(url, fromContentsOf: folder)
    }

    // MARK: DOCX

    /// Editable Word document rebuilt from a PDF: fonts, sizes, colours, styles, alignment, indents,
    /// spacing, links, pictures and tables with their borders and shading, on the PDF's page size.
    static func writeDOCX(_ document: PDFLayout.Document, to url: URL) async throws {
        let ns = "http://schemas.openxmlformats.org"
        let twips = { (points: CGFloat) in Int((points * 20).rounded()) }
        let margins = document.margins
        let textWidth = document.pageSize.width - margins.left - margins.right
        var rels: [(String, String, String)] = [("rId1", "styles", "styles.xml")]
        var links: [URL: String] = [:]
        var media: [(String, Data)] = []

        func run(_ run: PDFLayout.Run, bold forcedBold: Bool = false) -> String {
            let style = run.style
            // Word rejects run properties out of schema order: rFonts, b, i, color, sz, szCs, u.
            var props = "<w:rFonts w:ascii=\"\(style.font.xmlEscaped)\" w:hAnsi=\"\(style.font.xmlEscaped)\" w:cs=\"\(style.font.xmlEscaped)\"/>"
            if style.bold || forcedBold { props += "<w:b/>" }
            if style.italic { props += "<w:i/>" }
            if let color = style.color { props += "<w:color w:val=\"\(color)\"/>" }
            let halfPoints = Int((style.size * 2).rounded())
            props += "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/>"
            if style.underline { props += "<w:u w:val=\"single\"/>" }
            let xml = "<w:r><w:rPr>\(props)</w:rPr><w:t xml:space=\"preserve\">\(run.text.xmlEscaped)</w:t></w:r>"
            guard let link = style.link else { return xml }
            let id = links[link] ?? {
                let id = "rId\(rels.count + 1)"
                rels.append((id, "hyperlink", link.absoluteString))
                links[link] = id
                return id
            }()
            return "<w:hyperlink r:id=\"\(id)\">\(xml)</w:hyperlink>"
        }
        func justification(_ alignment: PDFLayout.Alignment) -> String {
            switch alignment {
            case .left: ""
            case .center: "<w:jc w:val=\"center\"/>"
            case .right: "<w:jc w:val=\"right\"/>"
            case .justified: "<w:jc w:val=\"both\"/>"
            }
        }

        var body = ""
        var startOfPage = true
        for block in document.blocks {
            switch block {
            case .paragraph(let paragraph):
                // Word rejects paragraph properties out of schema order: keepNext, spacing, ind, jc, outlineLvl.
                var props = paragraph.heading > 0 ? "<w:keepNext/>" : ""
                let line = paragraph.lineSpacing.map { " w:line=\"\(twips($0))\" w:lineRule=\"atLeast\"" } ?? ""
                props += "<w:spacing w:before=\"\(startOfPage ? 0 : twips(paragraph.spaceBefore))\" w:after=\"0\"\(line)/>"
                let first = paragraph.firstLineIndent
                if paragraph.indent > 0.5 || abs(first) > 0.5 {
                    let indent = paragraph.indent + min(first, 0)
                    props += "<w:ind w:left=\"\(twips(max(indent, 0)))\"" + (first >= 0 ? " w:firstLine=\"\(twips(first))\"" : " w:hanging=\"\(twips(-first))\"") + "/>"
                }
                props += justification(paragraph.alignment)
                if paragraph.heading > 0 { props += "<w:outlineLvl w:val=\"\(paragraph.heading - 1)\"/>" }
                body += "<w:p><w:pPr>\(props)</w:pPr>\(paragraph.runs.map { run($0) }.joined())</w:p>"
            case .table(let table):
                // The PDF's own column widths, shrunk only if the table wouldn't fit between the margins.
                let natural = table.columnWidths
                let fit = min(1, (textWidth - table.indent) / max(natural.reduce(0, +), 1))
                let columns = natural.map { max(twips($0 * fit), 200) }
                let line = { (side: String) in
                    table.borders ? "<w:\(side) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"808080\"/>" : "<w:\(side) w:val=\"nil\"/>"
                }
                if table.spaceBefore > 1 && !startOfPage {
                    body += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"\(twips(table.spaceBefore))\" w:lineRule=\"exact\"/></w:pPr></w:p>"
                }
                body += "<w:tbl><w:tblPr><w:tblW w:w=\"\(columns.reduce(0, +))\" w:type=\"dxa\"/><w:tblInd w:w=\"\(twips(table.indent))\" w:type=\"dxa\"/><w:tblBorders>"
                    + ["top", "left", "bottom", "right", "insideH", "insideV"].map(line).joined()
                    + "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:left w:w=\"60\" w:type=\"dxa\"/><w:right w:w=\"60\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
                    + columns.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
                for (r, row) in table.rows.enumerated() {
                    let isHeader = table.header && r == 0
                    body += "<w:tr>" + (isHeader ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
                    for (c, cell) in row.enumerated() {
                        let fill = r < table.shading.count && c < table.shading[r].count ? table.shading[r][c] : nil
                        let shading = fill.map { "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\($0)\"/>" } ?? ""
                        let props = "<w:spacing w:before=\"20\" w:after=\"20\"/>" + justification(table.alignments[min(c, table.alignments.count - 1)])
                        body += "<w:tc><w:tcPr><w:tcW w:w=\"\(columns[min(c, columns.count - 1)])\" w:type=\"dxa\"/>\(shading)</w:tcPr><w:p><w:pPr>\(props)</w:pPr>\(cell.map { run($0) }.joined())</w:p></w:tc>"
                    }
                    body += "</w:tr>"
                }
                body += "</w:tbl>"
            case .picture(let picture):
                let id = "rId\(rels.count + 1)", index = media.count + 1
                rels.append((id, "image", "media/picture\(index).jpeg"))
                media.append(("picture\(index).jpeg", picture.jpeg))
                let scale = min(1, textWidth / max(picture.size.width, 1))
                let cx = Int(picture.size.width * scale * 12_700), cy = Int(picture.size.height * scale * 12_700)
                body += """
                <w:p><w:pPr><w:spacing w:before="\(startOfPage ? 0 : twips(picture.spaceBefore))" w:after="0"/><w:ind w:left="\(twips(min(picture.indent, textWidth - picture.size.width * scale)))"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(index)" name="Picture \(index)"/><a:graphic><a:graphicData uri="\(ns)/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(index)" name="picture\(index).jpeg"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                """
            case .pageBreak:
                body += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr><w:r><w:br w:type=\"page\"/></w:r></w:p>"
                startOfPage = true
                continue
            }
            startOfPage = false
        }

        let relationshipXML = rels.map { id, type, target in
            let external = type == "hyperlink" ? " TargetMode=\"External\"" : ""
            return "<Relationship Id=\"\(id)\" Type=\"\(ns)/officeDocument/2006/relationships/\(type)\" Target=\"\(target.xmlEscaped)\"\(external)/>"
        }.joined()
        let folder = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write([
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="\(ns)/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\(wordOverrides)</Types>
            """,
            "_rels/.rels": wordRootRelationships,
            "word/_rels/document.xml.rels": "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"\(ns)/package/2006/relationships\">\(relationshipXML)\(wordDocumentRelationships(after: rels.count))</Relationships>",
            "word/styles.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="\(ns)/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style></w:styles>
            """,
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="\(ns)/wordprocessingml/2006/main" xmlns:r="\(ns)/officeDocument/2006/relationships" xmlns:wp="\(ns)/drawingml/2006/wordprocessingDrawing" xmlns:a="\(ns)/drawingml/2006/main" xmlns:pic="\(ns)/drawingml/2006/picture"><w:body>\(body)<w:sectPr><w:pgSz w:w="\(twips(document.pageSize.width))" w:h="\(twips(document.pageSize.height))"/><w:pgMar w:top="\(twips(margins.top))" w:right="\(twips(margins.right))" w:bottom="\(twips(margins.bottom))" w:left="\(twips(margins.left))" w:header="360" w:footer="360" w:gutter="0"/></w:sectPr></w:body></w:document>
            """,
        ].merging(wordParts(title: url.deletingPathExtension().lastPathComponent)) { $1 }, into: folder)
        let mediaFolder = folder.appendingPathComponent("word/media")
        if !media.isEmpty { try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true) }
        for (name, data) in media { try data.write(to: mediaFolder.appendingPathComponent(name)) }
        try await Zip.create(url, fromContentsOf: folder)
    }

    /// One picture per page at the page's own size, with no margins: an exact copy that isn't editable.
    static func writePictureDOCX(pages: [(jpeg: Data, size: CGSize)], to url: URL) async throws {
        guard let first = pages.first else { throw SwitchelError("There are no pages") }
        let ns = "http://schemas.openxmlformats.org"
        var paragraphs = "", rels: [(String, String, String)] = []
        for (offset, page) in pages.enumerated() {
            let i = offset + 1
            // Scale each page to fit the first page's size, a hair smaller so it never spills onto a blank page.
            let scale = min(first.size.width / page.size.width, first.size.height / page.size.height) * 0.995
            let cx = Int(page.size.width * scale * 12_700), cy = Int(page.size.height * scale * 12_700)
            rels.append(("rId\(i)", "image", "media/page\(i).jpeg"))
            let breakBefore = offset > 0 ? "<w:pageBreakBefore/>" : ""
            paragraphs += """
            <w:p><w:pPr>\(breakBefore)<w:spacing w:before="0" w:after="0"/><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(i)" name="Page \(i)"/><a:graphic><a:graphicData uri="\(ns)/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(i)" name="page\(i).jpeg"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId\(i)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            """
        }
        let twips = { (points: CGFloat) in Int(points * 20) }
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="\(ns)/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\(wordOverrides)</Types>
            """,
            "_rels/.rels": wordRootRelationships,
            "word/_rels/document.xml.rels": relationships(rels).replacingOccurrences(of: "</Relationships>", with: wordDocumentRelationships(after: rels.count) + "</Relationships>"),
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="\(ns)/wordprocessingml/2006/main" xmlns:r="\(ns)/officeDocument/2006/relationships" xmlns:wp="\(ns)/drawingml/2006/wordprocessingDrawing" xmlns:a="\(ns)/drawingml/2006/main" xmlns:pic="\(ns)/drawingml/2006/picture"><w:body>\(paragraphs)<w:sectPr><w:pgSz w:w="\(twips(first.size.width))" w:h="\(twips(first.size.height))"/><w:pgMar w:top="0" w:right="0" w:bottom="0" w:left="0" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr></w:body></w:document>
            """,
        ]
        let folder = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(files.merging(wordParts(title: url.deletingPathExtension().lastPathComponent)) { $1 }, into: folder)
        let media = folder.appendingPathComponent("word/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for (offset, page) in pages.enumerated() {
            try page.jpeg.write(to: media.appendingPathComponent("page\(offset + 1).jpeg"))
        }
        try await Zip.create(url, fromContentsOf: folder)
    }

    private static let theme: String = {
        let solid = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let colors = [("dk2", "1F497D"), ("lt2", "EEECE1"), ("accent1", "4F81BD"), ("accent2", "C0504D"), ("accent3", "9BBB59"),
                      ("accent4", "8064A2"), ("accent5", "4BACC6"), ("accent6", "F79646"), ("hlink", "0000FF"), ("folHlink", "800080")]
            .map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let font = "<a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Switchel"><a:themeElements><a:clrScheme name="Switchel"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\(colors)</a:clrScheme><a:fontScheme name="Switchel"><a:majorFont>\(font)</a:majorFont><a:minorFont>\(font)</a:minorFont></a:fontScheme><a:fmtScheme name="Switchel"><a:fillStyleLst>\(solid)\(solid)\(solid)</a:fillStyleLst><a:lnStyleLst><a:ln w="9525">\(solid)</a:ln><a:ln w="25400">\(solid)</a:ln><a:ln w="38100">\(solid)</a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>\(solid)\(solid)\(solid)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """
    }()

    // MARK: Word package parts

    /// The parts Word always writes beside the document. Without settings.xml Word opens files in
    /// Compatibility Mode; the properties and font table make the package look like Word's own.
    private static let wordOverrides = [
        ("/word/settings.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"),
        ("/word/fontTable.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"),
        ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
        ("/docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml"),
    ].map { "<Override PartName=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined()

    private static let wordRootRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
    """

    /// Settings and font table relationships, numbered after the document's own.
    private static func wordDocumentRelationships(after count: Int) -> String {
        let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        return "<Relationship Id=\"rId\(count + 1)\" Type=\"\(base)/settings\" Target=\"settings.xml\"/><Relationship Id=\"rId\(count + 2)\" Type=\"\(base)/fontTable\" Target=\"fontTable.xml\"/>"
    }

    private static func wordParts(title: String) -> [String: String] {
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let now = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return [
            "word/settings.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:settings xmlns:w="\(w)"><w:zoom w:percent="100"/><w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/><w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/><w:compatSetting w:name="overrideTableStyleFontSizeAndJustification" w:uri="http://schemas.microsoft.com/office/word" w:val="1"/><w:compatSetting w:name="enableOpenTypeFeatures" w:uri="http://schemas.microsoft.com/office/word" w:val="1"/><w:compatSetting w:name="doNotFlipMirrorIndents" w:uri="http://schemas.microsoft.com/office/word" w:val="1"/></w:compat></w:settings>
            """,
            "word/fontTable.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:fonts xmlns:w="\(w)"><w:font w:name="Helvetica"><w:panose1 w:val="020B0604020202020204"/><w:charset w:val="00"/><w:family w:val="swiss"/><w:pitch w:val="variable"/></w:font></w:fonts>
            """,
            "docProps/core.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(title.xmlEscaped)</dc:title><dc:creator>Switchel</dc:creator><cp:lastModifiedBy>Switchel</cp:lastModifiedBy><cp:revision>1</cp:revision><dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
            """,
            "docProps/app.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Microsoft Office Word</Application><DocSecurity>0</DocSecurity><AppVersion>16.0000</AppVersion></Properties>
            """,
        ]
    }

    // MARK: Helpers

    private static func relationships(_ items: [(id: String, type: String, target: String)]) -> String {
        let entries = items.map {
            "<Relationship Id=\"\($0.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\($0.type)\" Target=\"\($0.target)\"/>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(entries)</Relationships>"
    }

    private static func writePackage(_ files: [String: String], to url: URL, storedFirst: String? = nil) async throws {
        let folder = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(files, into: folder)
        try await Zip.create(url, fromContentsOf: folder, storedFirst: storedFirst)
    }

    private static func write(_ files: [String: String], into folder: URL) throws {
        for (path, contents) in files {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
    }
}
