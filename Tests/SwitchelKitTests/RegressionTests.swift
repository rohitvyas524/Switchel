import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SwitchelKit

/// Each test here reproduces a reported bug through the app's existing entry points.
final class RegressionTests: FixtureCase {
    // MARK: Line endings

    @MainActor
    func testWindowsLineEndingsCountOnce() {
        XCTAssertEqual(TextTools.clean("one  \r\ntwo\r\n\r\n\r\nthree\r\n", .init()), "one\ntwo\n\nthree\n")
        XCTAssertEqual(TextTools.stats(of: "one\r\ntwo\r\nthree\r\n").lines, 3)
        XCTAssertEqual(TextTools.stats(of: "one\r\ntwo\r\nthree\r\n").paragraphs, 3)
        XCTAssertEqual(Markdown.html("one\r\ntwo"), Markdown.html("one\ntwo"))
    }

    // MARK: Spreadsheets

    /// Builds an .ods from table rows given as XML.
    private func makeODS(_ rows: String) async throws -> URL {
        let package = folder.appendingPathComponent("ods", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:spreadsheet><table:table table:name="S">\(rows)</table:table></office:spreadsheet></office:body></office:document-content>
        """.write(to: package.appendingPathComponent("content.xml"), atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("sheet.ods")
        try await Zip.create(url, fromContentsOf: package)
        return url
    }

    func testODSKeepsMiddleBlanksAndDropsTrailingOnes() async throws {
        func cell(_ text: String) -> String { "<table:table-cell><text:p>\(text)</text:p></table:table-cell>" }
        func blanks(_ n: Int) -> String { "<table:table-cell table:number-columns-repeated=\"\(n)\"/>" }
        let url = try await makeODS("""
        <table:table-row>\(cell("A"))\(blanks(3))\(cell("E"))\(blanks(1000))</table:table-row>
        <table:table-row table:number-rows-repeated="2">\(blanks(1024))</table:table-row>
        <table:table-row table:number-rows-repeated="2">\(cell("x"))</table:table-row>
        <table:table-row table:number-rows-repeated="1048000">\(blanks(1024))</table:table-row>
        """)
        let table = try await Packages.readODS(url)
        XCTAssertEqual(table, [["A", "", "", "", "E"], [], [], ["x"], ["x"]])
    }

    /// A workbook whose XML files are out of step with its tabs: the first tab lives in sheet2.xml.
    private func makeWorkbook(sheets: String, relationships: String) async throws -> URL {
        let package = folder.appendingPathComponent("xlsx", isDirectory: true)
        let parts: [String: String] = [
            "xl/workbook.xml": #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\#(sheets)</sheets></workbook>"#,
            "xl/_rels/workbook.xml.rels": #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(relationships)</Relationships>"#,
            "xl/worksheets/sheet1.xml": Self.worksheet("Second tab"),
            "xl/worksheets/sheet2.xml": Self.worksheet("First tab"),
            "xl/worksheets/sheet3.xml": Self.worksheet("Hidden tab"),
        ]
        for (path, contents) in parts {
            let file = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        let url = folder.appendingPathComponent("book.xlsx")
        try await Zip.create(url, fromContentsOf: package)
        return url
    }

    private static func worksheet(_ text: String) -> String {
        #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>\#(text)</t></is></c></row></sheetData></worksheet>"#
    }

    func testExcelReadsFirstTabNotFirstFile() async throws {
        let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
        let url = try await makeWorkbook(
            sheets: #"<sheet name="Hidden" sheetId="3" state="hidden" r:id="rId3"/><sheet name="First" sheetId="2" r:id="rId2"/><sheet name="Second" sheetId="1" r:id="rId1"/>"#,
            relationships: #"<Relationship Id="rId1" Type="\#(type)" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="\#(type)" Target="/xl/worksheets/sheet2.xml"/><Relationship Id="rId3" Type="\#(type)" Target="worksheets/sheet3.xml"/>"#)
        let table = try await Packages.readXLSX(url)
        XCTAssertEqual(table, [["First tab"]])
    }

    // MARK: Keyboard shortcut

    func testSameShortcutRegistersAfterReleasingTheOldOne() throws {
        let json = #"{"keyCode":7,"modifiers":6912,"display":"X"}"#
        let combo = try JSONDecoder().decode(KeyCombo.self, from: Data(json.utf8))
        try MainActor.assumeIsolated {
            var key = HotKey(combo)
            try XCTSkipIf(key == nil, "This session can't register system shortcuts")
            XCTAssertNil(HotKey(combo), "the system refuses a duplicate, which is why order matters")
            key = nil
            XCTAssertNotNil(HotKey(combo))
        }
    }

    // MARK: Word documents

    private static let wordXMLNS = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml""#

    /// A picture wrapped the way Word writes one.
    private static func picture(id: Int, relationship: String) -> String {
        #"<w:p><w:r><w:drawing><wp:inline><wp:docPr id="\#(id)" name="Picture"/><a:graphic><a:graphicData><a:blip r:embed="\#(relationship)"/></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"#
    }

    /// A Word file with split runs, a picture, a table, a list, a hyperlink and a header.
    private func makeDocx(_ name: String, body: String, footnotes: String? = nil, extraNamespace: String = "") async throws -> URL {
        let package = folder.appendingPathComponent("pkg-\(name)", isDirectory: true)
        let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var overrides = #"<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>"#
        var relationships = #"<Relationship Id="rId1" Type="\#(relType)/image" Target="media/image1.png"/><Relationship Id="rId2" Type="\#(relType)/hyperlink" Target="https://example.com/\#(name)" TargetMode="External"/><Relationship Id="rId3" Type="\#(relType)/header" Target="header1.xml"/><Relationship Id="rId4" Type="\#(relType)/numbering" Target="numbering.xml"/><Relationship Id="rId5" Type="\#(relType)/styles" Target="styles.xml"/>"#
        var parts: [String: String] = [
            "[Content_Types].xml": #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\#(overrides)</Types>"#,
            "_rels/.rels": #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(relType)/officeDocument" Target="word/document.xml"/></Relationships>"#,
            "word/document.xml": #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document \#(Self.wordXMLNS) \#(extraNamespace) mc:Ignorable="w14"><w:body>\#(body)<w:sectPr><w:headerReference w:type="default" r:id="rId3"/><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body></w:document>"#,
            "word/header1.xml": #"<?xml version="1.0" encoding="UTF-8"?><w:hdr \#(Self.wordXMLNS)><w:p><w:r><w:t>hello from the header</w:t></w:r></w:p></w:hdr>"#,
            "word/numbering.xml": #"<?xml version="1.0" encoding="UTF-8"?><w:numbering \#(Self.wordXMLNS)><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>"#,
            "word/styles.xml": #"<?xml version="1.0" encoding="UTF-8"?><w:styles \#(Self.wordXMLNS)><w:style w:type="paragraph" w:styleId="Shared\#(name)"><w:name w:val="Shared \#(name)"/></w:style></w:styles>"#,
        ]
        if let footnotes {
            overrides += #"<Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>"#
            relationships += #"<Relationship Id="rId6" Type="\#(relType)/footnotes" Target="footnotes.xml"/>"#
            parts["[Content_Types].xml"] = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\#(overrides)</Types>"#
            parts["word/_rels/footnotes.xml.rels"] = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId2" Type="\#(relType)/hyperlink" Target="https://example.com/\#(name)" TargetMode="External"/></Relationships>"#
            parts["word/footnotes.xml"] = #"<?xml version="1.0" encoding="UTF-8"?><w:footnotes \#(Self.wordXMLNS)><w:footnote w:type="separator" w:id="-1"><w:p/></w:footnote>\#(footnotes)</w:footnotes>"#
        }
        parts["word/_rels/document.xml.rels"] = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(relationships)</Relationships>"#
        for (path, contents) in parts {
            let file = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        let image = try ImageConverter.load(try makePNG("\(name).png"))
        try FileManager.default.createDirectory(at: package.appendingPathComponent("word/media"), withIntermediateDirectories: true)
        try ImageConverter.write(image, to: package.appendingPathComponent("word/media/image1.png"), type: .png)
        let url = folder.appendingPathComponent("\(name).docx")
        try await Zip.create(url, fromContentsOf: package)
        return url
    }

    private static let richBody = """
    <w:p><w:r><w:t>hel</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>lo WORLD. second</w:t></w:r><w:r><w:t xml:space="preserve"> SENTENCE &amp; more</w:t></w:r></w:p>\
    \(picture(id: 1, relationship: "rId1"))\
    <w:tbl><w:tr><w:tc><w:p><w:r><w:t>hello cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>\
    <w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr><w:hyperlink r:id="rId2"><w:r><w:t>a link</w:t></w:r></w:hyperlink><w:r><w:tab/><w:t>tabbed</w:t></w:r></w:p>
    """

    private func unzip(_ docx: URL) async throws -> URL {
        let out = folder.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await Zip.extract(docx, to: out)
        return out
    }

    /// Fails if the document's markup can't be parsed or a picture or link has lost its target.
    private func assertWellFormed(_ package: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let document = try XMLDocument(contentsOf: package.appendingPathComponent("word/document.xml"))
        let rels = try XMLDocument(contentsOf: package.appendingPathComponent("word/_rels/document.xml.rels"))
        var targets: [String: XMLElement] = [:]
        for case let rel as XMLElement in try rels.nodes(forXPath: "//*[local-name()='Relationship']") {
            let id = try XCTUnwrap(rel.attribute(forName: "Id")?.stringValue)
            XCTAssertNil(targets[id], "duplicate relationship \(id)", file: file, line: line)
            targets[id] = rel
        }
        for node in try document.nodes(forXPath: "//@*[namespace-uri()='http://schemas.openxmlformats.org/officeDocument/2006/relationships']") {
            let rel = try XCTUnwrap(targets[node.stringValue ?? ""], "\(node.stringValue ?? "") has no relationship", file: file, line: line)
            guard rel.attribute(forName: "TargetMode")?.stringValue != "External", let target = rel.attribute(forName: "Target")?.stringValue else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "word/\(target)"
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent(path).path), "\(path) is missing", file: file, line: line)
        }
    }

    private func documentXML(_ package: URL) throws -> String {
        try String(contentsOf: package.appendingPathComponent("word/document.xml"), encoding: .utf8)
    }

    @MainActor
    func testFindAndReplaceKeepsPicturesAndTables() async throws {
        let source = try await makeDocx("memo", body: Self.richBody)
        let edited = try await TextTools.findAndReplace(source, .init(find: "hello", replace: "Goodbye & co"))
        XCTAssertEqual(edited.lastPathComponent, "memo edited.docx")

        let package = try await unzip(edited)
        try assertWellFormed(package)
        let xml = try documentXML(package)
        XCTAssertTrue(xml.contains("<w:tbl>"), "table kept")
        XCTAssertTrue(xml.contains("<w:drawing>"), "picture kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("word/media/image1.png").path))
        XCTAssertTrue(xml.contains("Goodbye &amp; co cell"), "inside a table")
        XCTAssertTrue(xml.contains("mc:Ignorable=\"w14\"") && xml.contains("xmlns:w14"), "Word refuses files missing these: \(xml.prefix(400))")
        XCTAssertTrue(xml.hasPrefix("<?xml"), "keeps its declaration")
        let header = try String(contentsOf: package.appendingPathComponent("word/header1.xml"), encoding: .utf8)
        XCTAssertTrue(header.contains("Goodbye &amp; co from the header"), "headers are searched too")

        // A match spanning runs takes the formatting of its first run; the bold run keeps the rest.
        let text = try NSAttributedString(url: edited, options: [:], documentAttributes: nil)
        XCTAssertTrue(text.string.hasPrefix("Goodbye & co WORLD. second SENTENCE & more"), text.string)
        let font = text.attribute(.font, at: (text.string as NSString).range(of: "WORLD").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false, "bold stays bold")

        do {
            _ = try await TextTools.findAndReplace(source, .init(find: "absent", replace: "x"))
            XCTFail("should report no match")
        } catch {}
    }

    @MainActor
    func testFindAndReplaceCanRemoveATab() async throws {
        let source = try await makeDocx("tabs", body: Self.richBody)
        let edited = try await TextTools.findAndReplace(source, .init(find: #"link\ttabbed"#, replace: "joined", regularExpression: true))
        let package = try await unzip(edited)
        try assertWellFormed(package)
        let xml = try documentXML(package)
        XCTAssertTrue(xml.contains(">joined<") || xml.contains("a joined"), xml)
        XCTAssertFalse(xml.contains("<w:tab/>"), "the matched tab is gone")
        XCTAssertTrue(xml.contains(#"<w:tab w:val="left""#), "a tab stop isn't text")
    }

    @MainActor
    func testChangeCaseAcrossRunsKeepsPicturesAndFormatting() async throws {
        let source = try await makeDocx("case", body: Self.richBody)
        let sentence = try await TextTools.changeCase(source, to: .sentence)
        let package = try await unzip(sentence)
        try assertWellFormed(package)
        let xml = try documentXML(package)
        XCTAssertTrue(xml.contains("<w:drawing>") && xml.contains("<w:tbl>"))
        XCTAssertTrue(xml.contains(">Hel<"), xml)
        XCTAssertTrue(xml.contains("<w:b/>"), "bold run kept")
        XCTAssertTrue(xml.contains(">lo world. Second<"), "the sentence continues across the run: \(xml)")
        XCTAssertTrue(xml.contains("> sentence &amp; more<"), xml)

        let title = try await TextTools.changeCase(source, to: .title)
        let titleXML = try documentXML(try await unzip(title))
        XCTAssertTrue(titleXML.contains(">Hel<") && titleXML.contains(">lo World. Second<"), "no capital mid-word at a run break: \(titleXML)")
    }

    @MainActor
    func testMergeKeepsEveryPictureListAndNote() async throws {
        let note = #"<w:p><w:r><w:footnoteReference w:id="1"/></w:r><w:r><w:t>noted</w:t></w:r></w:p>"#
        let list = #"<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr><w:pStyle w:val="Sharedb"/></w:pPr><w:bookmarkStart w:id="0" w:name="mark"/><w:r><w:t>item</w:t></w:r><w:bookmarkEnd w:id="0"/></w:p>"#
        let footnote = #"<w:footnote w:id="1"><w:p><w:hyperlink r:id="rId2"><w:r><w:t>see this</w:t></w:r></w:hyperlink></w:p></w:footnote>"#
        let a = try await makeDocx("a", body: Self.richBody + list + note, footnotes: footnote)
        let b = try await makeDocx("b", body: Self.richBody + list + note + #"<w:p><w:commentRangeStart w:id="0"/><w:r><w:t>commented</w:t></w:r><w:commentRangeEnd w:id="0"/><w:r><w:commentReference w:id="0"/></w:r></w:p>"#,
                                   footnotes: footnote, extraNamespace: #"xmlns:w16="http://schemas.microsoft.com/office/word/2018/wordml""#)
        let merged = try await TextTools.merge([a, b])
        XCTAssertEqual(merged.lastPathComponent, "a merged.docx")

        let package = try await unzip(merged)
        try assertWellFormed(package)
        let document = try XMLDocument(contentsOf: package.appendingPathComponent("word/document.xml"))
        func count(_ xpath: String) throws -> Int { try document.nodes(forXPath: xpath).count }
        XCTAssertEqual(try count("//*[local-name()='drawing']"), 2)
        XCTAssertEqual(try count("//*[local-name()='tbl']"), 2)
        XCTAssertEqual(try count("//*[local-name()='body']/*[local-name()='sectPr']"), 1)
        XCTAssertEqual(document.rootElement()?.children?.compactMap { $0 as? XMLElement }.first?.children?.last?.localName, "sectPr", "page setup stays last")
        XCTAssertEqual(try count("//*[local-name()='commentReference' or local-name()='commentRangeStart' or local-name()='commentRangeEnd']"), 0, "no dangling comment anchors")
        XCTAssertNotNil(document.rootElement()?.namespace(forPrefix: "w16"), "the other document's namespaces come along")

        // Pictures each keep their own file, and it's registered.
        let embeds = try document.nodes(forXPath: "//*[local-name()='blip']/@*[local-name()='embed']").compactMap(\.stringValue)
        XCTAssertEqual(Set(embeds).count, 2)
        let types = try String(contentsOf: package.appendingPathComponent("[Content_Types].xml"), encoding: .utf8)
        XCTAssertTrue(types.contains("Extension=\"png\""))

        // Lists, bookmarks and drawing ids don't collide.
        let numIds = try document.nodes(forXPath: "//*[local-name()='numId']/@*[local-name()='val']").compactMap(\.stringValue)
        XCTAssertEqual(Set(numIds).count, 2, "\(numIds)")
        let numbering = try XMLDocument(contentsOf: package.appendingPathComponent("word/numbering.xml"))
        for id in numIds {
            XCTAssertEqual(try numbering.nodes(forXPath: "//*[local-name()='num'][@*[local-name()='numId']='\(id)']").count, 1)
        }
        let order = numbering.rootElement()?.children?.compactMap(\.localName) ?? []
        XCTAssertEqual(order, ["abstractNum", "abstractNum", "num", "num"], "the schema's required order")
        let bookmarks = try document.nodes(forXPath: "//*[local-name()='bookmarkStart']/@*[local-name()='id']").compactMap(\.stringValue)
        XCTAssertEqual(Set(bookmarks).count, 2)
        let drawings = try document.nodes(forXPath: "//*[local-name()='docPr']/@id").compactMap(\.stringValue)
        XCTAssertEqual(Set(drawings).count, 2)

        // Footnotes are renumbered, with their own links intact.
        let references = try document.nodes(forXPath: "//*[local-name()='footnoteReference']/@*[local-name()='id']").compactMap(\.stringValue)
        XCTAssertEqual(Set(references).count, 2, "\(references)")
        let notes = try XMLDocument(contentsOf: package.appendingPathComponent("word/footnotes.xml"))
        XCTAssertEqual(try notes.nodes(forXPath: "//*[local-name()='footnote']").count, 3, "one separator and two notes")
        let noteLinks = try notes.nodes(forXPath: "//*[local-name()='hyperlink']/@*[local-name()='id']").compactMap(\.stringValue)
        let noteRels = try XMLDocument(contentsOf: package.appendingPathComponent("word/_rels/footnotes.xml.rels"))
        for id in noteLinks.suffix(1) {
            XCTAssertEqual(try noteRels.nodes(forXPath: "//*[@Id='\(id)']/@Target").first?.stringValue, "https://example.com/b")
        }

        // Styles only one document had come along.
        let styles = try String(contentsOf: package.appendingPathComponent("word/styles.xml"), encoding: .utf8)
        XCTAssertTrue(styles.contains("Shareda") && styles.contains("Sharedb"))

        // macOS can read the result.
        let text = try NSAttributedString(url: merged, options: [:], documentAttributes: nil).string
        XCTAssertEqual(text.components(separatedBy: "noted").count - 1, 2, text)
    }

    @MainActor
    func testMergeMixedFormatsBecomesWord() async throws {
        let docx = try await makeDocx("a", body: Self.richBody)
        let rtf = folder.appendingPathComponent("b.rtf")
        let text = NSAttributedString(string: "From RTF", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)
        let merged = try await TextTools.merge([docx, rtf])
        let package = try await unzip(merged)
        try assertWellFormed(package)
        let xml = try documentXML(package)
        XCTAssertTrue(xml.contains("<w:drawing>") && xml.contains("From RTF"))
    }

    // MARK: Case in rich documents

    @MainActor
    func testSentenceCaseKeepsFormattingInRTF() async throws {
        let source = folder.appendingPathComponent("memo.rtf")
        let text = NSMutableAttributedString(string: "FIRST ", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        text.append(NSAttributedString(string: "BOLD. NEXT", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
        text.append(NSAttributedString(string: " PLAIN", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: source)

        let out = try await TextTools.changeCase(source, to: .sentence)
        let back = try NSAttributedString(url: out, options: [:], documentAttributes: nil)
        XCTAssertEqual(back.string, "First bold. Next plain")
        func isBold(_ word: String) -> Bool {
            let font = back.attribute(.font, at: (back.string as NSString).range(of: word).location, effectiveRange: nil) as? NSFont
            return font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        }
        XCTAssertFalse(isBold("First"))
        XCTAssertTrue(isBold("bold"))
        XCTAssertTrue(isBold("Next"))
        XCTAssertFalse(isBold("plain"))
    }

    @MainActor
    func testSentenceCaseAfterWindowsLineEnding() async throws {
        let note = folder.appendingPathComponent("note.txt")
        try "ONE\r\nTWO".write(to: note, atomically: true, encoding: .utf8)
        let out = try await TextTools.changeCase(note, to: .sentence)
        XCTAssertEqual(try String(contentsOf: out), "One\r\nTwo")
    }

    // MARK: Find and replace

    @MainActor
    func testWholeWordsGroupsAlternatives() throws {
        var replacement = TextTools.Replacement(find: "cat|dog", wholeWords: true)
        replacement.regularExpression = true
        XCTAssertEqual(TextTools.matches(in: "catalog hotdog", replacement), 0)
        XCTAssertEqual(TextTools.matches(in: "cat dog", replacement), 2)
        // Capture groups keep their numbers, and a pattern can't be balanced by the wrapping.
        XCTAssertThrowsError(try TextTools.Replacement(find: "a)|(b", regularExpression: true, wholeWords: true).expression())
    }

    // MARK: Metadata

    func testCropRotateCompressKeepCaptureDetails() async throws {
        let photo = try makePhoto()
        let cropped = try await ImageTools.crop(photo, to: CGRect(x: 0, y: 0, width: 300, height: 200))
        let rotated = try await ImageTools.rotateClockwise(photo)
        let compressed = try await ImageTools.compress(photo)
        let toSize = try await ImageTools.compress(photo, .init(target: .maxBytes(200_000), maxDimension: nil, format: .jpg))
        for url in [cropped, rotated, compressed, toSize] {
            let entries = ImageTools.metadata(of: url)
            XCTAssertTrue(entries.contains { $0.group == "GPS" }, "\(url.lastPathComponent) lost its location")
            XCTAssertEqual(entries.first { $0.key == "Make" }?.value, "TestCam", url.lastPathComponent)
        }
        XCTAssertLessThanOrEqual((try toSize.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? .max, 200_000)
    }

    /// With no TIFF tags to update, ImageIO stores these as XMP, which reads back under IPTC names.
    private func value(_ entries: [ImageTools.MetadataEntry], _ keys: String...) -> String? {
        entries.first { keys.contains($0.key) }?.value
    }

    /// A 1×1 lossy WebP.
    private func makeWebP() throws -> URL {
        let url = folder.appendingPathComponent("tiny.webp")
        try XCTUnwrap(Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")).write(to: url)
        return url
    }

    func testWebPMetadataEditsApply() async throws {
        let webp = try makeWebP()
        let edited = try await ImageTools.editMetadata(webp, .init(description: "A pixel", artist: "Ada", copyright: "Mine"))
        XCTAssertEqual(edited.lastPathComponent, "tiny edited.webp")
        var entries = ImageTools.metadata(of: edited)
        XCTAssertEqual(value(entries, "Artist", "Byline"), "Ada", "\(entries)")
        XCTAssertEqual(value(entries, "ImageDescription", "Caption/Abstract"), "A pixel", "\(entries)")
        XCTAssertEqual(value(entries, "Copyright", "CopyrightNotice"), "Mine", "\(entries)")
        XCTAssertEqual(entries.first { $0.key == "PixelWidth" }?.value, "1")
        XCTAssertNoThrow(try ImageConverter.load(edited), "still decodes")

        // Edits build on what's there, and the image bytes aren't re-encoded.
        let again = try await ImageTools.editMetadata(edited, .init(copyright: "Theirs"))
        entries = ImageTools.metadata(of: again)
        XCTAssertEqual(value(entries, "Artist", "Byline"), "Ada", "\(entries)")
        XCTAssertEqual(value(entries, "Copyright", "CopyrightNotice"), "Theirs", "\(entries)")
        let original = try Data(contentsOf: webp), result = try Data(contentsOf: again)
        XCTAssertNotNil(result.range(of: original.suffix(from: 12)), "the VP8 chunk is carried over byte for byte")

        let clean = try await ImageTools.editMetadata(again, .init(removeAll: true))
        XCTAssertNil(value(ImageTools.metadata(of: clean), "Artist", "Byline"))
        XCTAssertNoThrow(try ImageConverter.load(clean))
    }

    // MARK: Zip

    @MainActor
    func testZipSameNamesFromDifferentFolders() async throws {
        let one = folder.appendingPathComponent("one", isDirectory: true), two = folder.appendingPathComponent("two", isDirectory: true)
        for directory in [one, two] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let a = one.appendingPathComponent("report.txt"), b = two.appendingPathComponent("report.txt"), dash = two.appendingPathComponent("-odd.txt")
        for (url, text) in [(a, "first"), (b, "second"), (dash, "third")] { try text.write(to: url, atomically: true, encoding: .utf8) }

        let zip = try await ArchiveConverter.zip([a, b, dash])
        let out = folder.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await Zip.extract(zip, to: out)
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(names, ["-odd.txt", "report 2.txt", "report.txt"])
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("report.txt")), "first")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("report 2.txt")), "second")
    }

    // MARK: Subtitles

    func testShiftingEarlierDropsCuesBeforeTheStart() throws {
        let srt = folder.appendingPathComponent("film.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nGone\n\n2\n00:00:03,000 --> 00:00:05,000\nClipped\n\n3\n00:00:10,000 --> 00:00:11,000\nMoved\n".write(to: srt, atomically: true, encoding: .utf8)
        let cues = SubtitleConverter.parse(try String(contentsOf: try SubtitleTools.shift(srt, by: -4)))
        XCTAssertEqual(cues.map(\.text), ["Clipped", "Moved"])
        XCTAssertEqual(cues.first?.start, 0)
        XCTAssertEqual(cues.first?.end, 1)
        XCTAssertThrowsError(try SubtitleTools.shift(srt, by: -100), "shouldn't write an empty file")
    }
}
