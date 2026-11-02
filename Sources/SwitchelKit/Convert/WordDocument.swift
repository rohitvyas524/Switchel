import Foundation

/// A Word file edited through its XML, so whatever isn't the text being changed (pictures, tables,
/// styles, lists, headers) survives. macOS's own Word reader and writer lose those.
final class WordDocument {
    private let folder: URL
    /// The main part's path in the package, normally "word/document.xml".
    private let mainPart: String
    /// Parsed parts by package path, written back on save.
    private var parts: [String: XMLDocument] = [:]
    private var mergeCount = 0

    init(_ docx: URL) async throws {
        folder = try Output.temporaryFolder()
        do {
            try await Zip.extract(docx, to: folder)
            mainPart = try Self.findMainPart(in: folder, of: docx)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func save(to url: URL) async throws {
        for (path, document) in parts {
            try document.xmlData(options: [.nodePreserveAll]).write(to: file(path))
        }
        try await Zip.create(url, fromContentsOf: folder)
    }

    private static func findMainPart(in folder: URL, of docx: URL) throws -> String {
        let rels = try? XMLDocument(contentsOf: folder.appendingPathComponent("_rels/.rels"))
        let nodes = (try? rels?.nodes(forXPath: "//*[local-name()='Relationship']")) ?? []
        let target = nodes.compactMap { $0 as? XMLElement }
            .first { $0.attribute(forName: "Type")?.stringValue?.hasSuffix("/officeDocument") == true }?
            .attribute(forName: "Target")?.stringValue
        let path = target.map { resolve($0, from: "") } ?? "word/document.xml"
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) else {
            throw SwitchelError("\(docx.lastPathComponent) isn't a Word document Switchel can read")
        }
        return path
    }

    // MARK: Text

    /// One paragraph's text, gathered across the runs Word splits it into.
    final class Paragraph {
        private final class Piece {
            let node: XMLElement
            let isText: Bool
            let start: Int
            let length: Int
            let content: NSMutableString
            var changed = false

            init(node: XMLElement, isText: Bool, value: String, start: Int) {
                self.node = node
                self.isText = isText
                self.start = start
                length = (value as NSString).length
                content = NSMutableString(string: value)
            }
        }

        private var pieces: [Piece] = []
        private(set) var text = ""

        fileprivate init(_ element: XMLElement) { collect(element) }

        private func collect(_ element: XMLElement) {
            for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) {
                // A text box's paragraphs are visited on their own.
                if isWord(child, "p") { continue }
                if isWord(child, "t") {
                    add(child, isText: true, value: child.stringValue ?? "")
                } else if isWord(element, "r"), isWord(child, "tab") {
                    add(child, isText: false, value: "\t")
                } else if isWord(element, "r"), isWord(child, "br") || isWord(child, "cr") {
                    add(child, isText: false, value: "\n")
                } else {
                    collect(child)
                }
            }
        }

        private func add(_ node: XMLElement, isText: Bool, value: String) {
            pieces.append(Piece(node: node, isText: isText, value: value, start: (text as NSString).length))
            text += value
        }

        /// Replaces every match, giving each replacement the formatting of the text it replaces.
        func replaceMatches(of expression: NSRegularExpression, template: String) -> Int {
            guard pieces.contains(where: \.isText) else { return 0 }
            let matches = expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            // Back to front, so earlier ranges stay valid.
            for match in matches.reversed() {
                replace(match.range, with: expression.replacementString(for: match, in: text, offset: 0, template: template))
            }
            pieces.filter(\.changed).forEach(Self.commit)
            return matches.count
        }

        private func replace(_ range: NSRange, with substitute: String) {
            func overlap(_ piece: Piece) -> NSRange { NSIntersectionRange(range, NSRange(location: piece.start, length: piece.length)) }
            let texts = pieces.filter(\.isText)
            let target = texts.first { overlap($0).length > 0 }
                ?? texts.first { $0.start <= range.location && range.location <= $0.start + $0.length }
                ?? texts.first { $0.start >= range.location }
                ?? texts[texts.count - 1]
            for piece in pieces.reversed() where overlap(piece).length > 0 {
                if piece.isText {
                    piece.content.deleteCharacters(in: NSRange(location: overlap(piece).location - piece.start, length: overlap(piece).length))
                    piece.changed = true
                } else {
                    piece.node.detach()
                }
            }
            target.content.insert(substitute, at: min(max(range.location - target.start, 0), target.content.length))
            target.changed = true
        }

        /// Runs every piece of text through `transform` in order, so it can keep state across runs.
        func mapText(_ transform: (String) -> String) {
            for piece in pieces {
                let result = transform(piece.content as String)
                guard piece.isText else { continue }
                piece.content.setString(result)
                Self.commit(piece)
            }
        }

        private static func commit(_ piece: Piece) {
            piece.node.stringValue = piece.content as String
            piece.node.removeAttribute(forName: "xml:space")
            if let space = XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as? XMLNode {
                piece.node.addAttribute(space)
            }
        }
    }

    /// Every paragraph in the body, headers, footers, footnotes and endnotes, including tables and text boxes.
    func paragraphs() throws -> [Paragraph] {
        let directory = (mainPart as NSString).deletingLastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: file(directory).path)) ?? []
        let extras = names.filter { name in
            name.hasSuffix(".xml") && (name.hasPrefix("header") || name.hasPrefix("footer") || name == "footnotes.xml" || name == "endnotes.xml")
        }.sorted()
        var result: [Paragraph] = []
        for path in [mainPart] + extras.map({ (directory as NSString).appendingPathComponent($0) }) {
            guard let root = try part(path).rootElement() else { continue }
            forEachElement(in: root) { if isWord($0, "p") { result.append(Paragraph($0)) } }
        }
        return result
    }

    // MARK: Merging

    /// Appends another document's content. The first document's page setup and same-named styles win.
    func append(_ other: WordDocument) throws {
        mergeCount += 1
        guard let body = try bodyElement(), let otherBody = try other.bodyElement() else {
            throw SwitchelError("A Word document has no body")
        }
        let moved = (otherBody.children ?? []).compactMap { $0 as? XMLElement }.filter { !isWord($0, "sectPr") }
        var mapping = Mapping()
        mapping.numbering = try mergeNumbering(from: other)
        try mergeStyles(from: other, numbering: mapping.numbering)
        if moved.contains(where: { contains($0, "footnoteReference") }) {
            mapping.footnotes = try mergeNotes(from: other, relationship: "footnotes", note: "footnote")
        }
        if moved.contains(where: { contains($0, "endnoteReference") }) {
            mapping.endnotes = try mergeNotes(from: other, relationship: "endnotes", note: "endnote")
        }
        mapping.bookmarkOffset = try maxAttribute(of: mainPart) { isWord($0, "bookmarkStart") ? "w:id" : nil } + 1
        mapping.drawingOffset = try maxAttribute(of: mainPart) { $0.localName == "docPr" ? "id" : nil } + 1

        guard let root = try part(mainPart).rootElement(), let otherRoot = try other.part(other.mainPart).rootElement() else { return }
        adoptNamespaces(of: otherRoot, into: root)

        // Page setup stays last in the body.
        var index = (body.children ?? []).lastIndex { ($0 as? XMLElement).map { isWord($0, "sectPr") } ?? false } ?? body.childCount
        let separator = XMLElement(name: "w:p", uri: Self.wordNamespace)
        body.insertChild(separator, at: index)
        index += 1
        for element in moved {
            guard let copy = element.copy() as? XMLElement else { continue }
            try rewrite(copy, from: other, ownerPart: mainPart, otherPart: other.mainPart, mapping)
            guard !isCommentMarkup(copy) else { continue }
            body.insertChild(copy, at: index)
            index += 1
        }
    }

    private struct Mapping {
        var numbering: [String: String] = [:]
        var footnotes: [String: String] = [:]
        var endnotes: [String: String] = [:]
        var bookmarkOffset = 0
        var drawingOffset = 0
    }

    private func bodyElement() throws -> XMLElement? {
        (try part(mainPart).rootElement()?.children ?? []).compactMap { $0 as? XMLElement }.first { isWord($0, "body") }
    }

    /// Points a moved element's references at their new homes and copies what they refer to.
    private func rewrite(_ root: XMLElement, from other: WordDocument, ownerPart: String, otherPart: String, _ mapping: Mapping) throws {
        var relationshipMap: [String: String] = [:]
        var comments: [XMLElement] = []
        var failure: Error?
        forEachElement(in: root) { element in
            for attribute in element.attributes ?? [] where attribute.uri?.contains("relationships") == true {
                guard let old = attribute.stringValue else { continue }
                do {
                    if let new = relationshipMap[old] {
                        attribute.stringValue = new
                    } else if let new = try self.copyRelationship(old, from: other, otherPart: otherPart, toPart: ownerPart) {
                        relationshipMap[old] = new
                        attribute.stringValue = new
                    }
                } catch { failure = error }
            }
            if isWord(element, "numId") { Self.remap(element, "w:val", mapping.numbering) }
            if isWord(element, "footnoteReference") { Self.remap(element, "w:id", mapping.footnotes) }
            if isWord(element, "endnoteReference") { Self.remap(element, "w:id", mapping.endnotes) }
            if isWord(element, "bookmarkStart") || isWord(element, "bookmarkEnd") { Self.offset(element, "w:id", by: mapping.bookmarkOffset) }
            if element.localName == "docPr" { Self.offset(element, "id", by: mapping.drawingOffset) }
            if self.isCommentMarkup(element) { comments.append(element) }
        }
        if let failure { throw failure }
        // Comments aren't brought across, so their anchors mustn't dangle.
        comments.forEach { $0.detach() }
    }

    private func isCommentMarkup(_ element: XMLElement) -> Bool {
        isWord(element, "commentRangeStart") || isWord(element, "commentRangeEnd") || isWord(element, "commentReference")
    }

    private static func remap(_ element: XMLElement, _ name: String, _ map: [String: String]) {
        guard let attribute = element.attribute(forName: name), let value = attribute.stringValue, let new = map[value] else { return }
        attribute.stringValue = new
    }

    private static func offset(_ element: XMLElement, _ name: String, by amount: Int) {
        guard let attribute = element.attribute(forName: name), let value = attribute.stringValue.flatMap(Int.init) else { return }
        attribute.stringValue = String(value + amount)
    }

    private func maxAttribute(of path: String, _ name: (XMLElement) -> String?) throws -> Int {
        guard let root = try part(path).rootElement() else { return 0 }
        var highest = 0
        forEachElement(in: root) { element in
            if let key = name(element), let value = element.attribute(forName: key)?.stringValue.flatMap(Int.init) { highest = max(highest, value) }
        }
        return highest
    }

    private func adoptNamespaces(of source: XMLElement, into target: XMLElement) {
        for namespace in source.namespaces ?? [] {
            guard let prefix = namespace.name, !prefix.isEmpty, target.namespace(forPrefix: prefix) == nil,
                  let copy = namespace.copy() as? XMLNode else { continue }
            target.addNamespace(copy)
        }
        guard let incoming = source.attribute(forName: "mc:Ignorable")?.stringValue else { return }
        let existing = target.attribute(forName: "mc:Ignorable")?.stringValue ?? ""
        var tokens = existing.split(separator: " ").map(String.init)
        for token in incoming.split(separator: " ").map(String.init) where !tokens.contains(token) { tokens.append(token) }
        target.removeAttribute(forName: "mc:Ignorable")
        if let attribute = XMLNode.attribute(withName: "mc:Ignorable", stringValue: tokens.joined(separator: " ")) as? XMLNode {
            target.addAttribute(attribute)
        }
    }

    // MARK: Merging: shared parts

    /// Adds the other document's lists under fresh ids and returns old list id → new.
    private func mergeNumbering(from other: WordDocument) throws -> [String: String] {
        guard let source = try other.relatedPart("numbering") else { return [:] }
        guard let path = try relatedPart("numbering") else {
            try adoptSharedPart(source, type: "numbering", from: other)
            return [:]
        }
        guard let root = try part(path).rootElement(), let otherRoot = try other.part(source).rootElement() else { return [:] }
        adoptNamespaces(of: otherRoot, into: root)
        let abstractOffset = try maxAttribute(of: path) { isWord($0, "abstractNum") ? "w:abstractNumId" : nil } + 1
        let numberOffset = try maxAttribute(of: path) { isWord($0, "num") ? "w:numId" : nil } + 1
        var map: [String: String] = [:]
        // The schema wants every abstractNum before every num.
        func children() -> [XMLElement] { (root.children ?? []).compactMap { $0 as? XMLElement } }
        for element in (otherRoot.children ?? []).compactMap({ $0 as? XMLElement }) {
            guard let copy = element.copy() as? XMLElement else { continue }
            if isWord(element, "abstractNum") {
                Self.offset(copy, "w:abstractNumId", by: abstractOffset)
                let index = children().firstIndex { isWord($0, "num") || isWord($0, "numIdMacAtCleanup") } ?? root.childCount
                root.insertChild(copy, at: index)
            } else if isWord(element, "num"), let old = element.attribute(forName: "w:numId")?.stringValue {
                Self.offset(copy, "w:numId", by: numberOffset)
                map[old] = copy.attribute(forName: "w:numId")?.stringValue
                for child in (copy.children ?? []).compactMap({ $0 as? XMLElement }) where isWord(child, "abstractNumId") {
                    Self.offset(child, "w:val", by: abstractOffset)
                }
                let index = children().firstIndex { isWord($0, "numIdMacAtCleanup") } ?? root.childCount
                root.insertChild(copy, at: index)
            }
        }
        return map
    }

    /// Adds the other document's styles that this one doesn't have.
    private func mergeStyles(from other: WordDocument, numbering: [String: String]) throws {
        guard let source = try other.relatedPart("styles") else { return }
        guard let path = try relatedPart("styles") else {
            let new = try adoptSharedPart(source, type: "styles", from: other)
            if let root = try part(new).rootElement() {
                forEachElement(in: root) { if isWord($0, "numId") { Self.remap($0, "w:val", numbering) } }
            }
            return
        }
        guard let root = try part(path).rootElement(), let otherRoot = try other.part(source).rootElement() else { return }
        adoptNamespaces(of: otherRoot, into: root)
        let styles = (root.children ?? []).compactMap { $0 as? XMLElement }.filter { isWord($0, "style") }
        var known = Set(styles.compactMap { $0.attribute(forName: "w:styleId")?.stringValue })
        for style in (otherRoot.children ?? []).compactMap({ $0 as? XMLElement }) where isWord(style, "style") {
            guard let id = style.attribute(forName: "w:styleId")?.stringValue, known.insert(id).inserted,
                  let copy = style.copy() as? XMLElement else { continue }
            forEachElement(in: copy) { if isWord($0, "numId") { Self.remap($0, "w:val", numbering) } }
            root.addChild(copy)
        }
    }

    /// Adds the other document's footnotes or endnotes and returns old note id → new.
    private func mergeNotes(from other: WordDocument, relationship: String, note: String) throws -> [String: String] {
        guard let source = try other.relatedPart(relationship) else { return [:] }
        guard let path = try relatedPart(relationship) else {
            try adoptSharedPart(source, type: relationship, from: other)
            return [:]
        }
        guard let root = try part(path).rootElement(), let otherRoot = try other.part(source).rootElement() else { return [:] }
        adoptNamespaces(of: otherRoot, into: root)
        var next = try maxAttribute(of: path) { isWord($0, note) ? "w:id" : nil } + 1
        var map: [String: String] = [:]
        for element in (otherRoot.children ?? []).compactMap({ $0 as? XMLElement }) where isWord(element, note) {
            // Separators are part of every notes file, not content.
            guard ["normal", nil].contains(element.attribute(forName: "w:type")?.stringValue),
                  let old = element.attribute(forName: "w:id")?.stringValue,
                  let copy = element.copy() as? XMLElement else { continue }
            copy.attribute(forName: "w:id")?.stringValue = String(next)
            map[old] = String(next)
            next += 1
            try rewrite(copy, from: other, ownerPart: path, otherPart: source, Mapping())
            root.addChild(copy)
        }
        return map
    }

    /// Brings over a part this document lacks, wired up as one of its own.
    @discardableResult
    private func adoptSharedPart(_ source: String, type: String, from other: WordDocument) throws -> String {
        let new = try copyPart(source, from: other)
        let rel = try other.relationships(of: other.mainPart).first { $0.attribute(forName: "Type")?.stringValue?.hasSuffix("/\(type)") == true }
        _ = try addRelationship(to: mainPart, type: rel?.attribute(forName: "Type")?.stringValue ?? "", target: "/\(new)", external: false)
        return new
    }

    // MARK: Package plumbing

    private func file(_ path: String) -> URL { folder.appendingPathComponent(path) }

    private func part(_ path: String) throws -> XMLDocument {
        if let loaded = parts[path] { return loaded }
        let document = try XMLDocument(contentsOf: file(path), options: [.nodePreserveAll])
        parts[path] = document
        return document
    }

    /// The package path of the part the main document relates to with this type.
    private func relatedPart(_ type: String) throws -> String? {
        let rel = try relationships(of: mainPart).first {
            $0.attribute(forName: "Type")?.stringValue?.hasSuffix("/\(type)") == true && $0.attribute(forName: "TargetMode")?.stringValue != "External"
        }
        guard let target = rel?.attribute(forName: "Target")?.stringValue else { return nil }
        let path = Self.resolve(target, from: mainPart)
        return FileManager.default.fileExists(atPath: file(path).path) ? path : nil
    }

    private static func relationshipsPath(of part: String) -> String {
        let name = (part as NSString).lastPathComponent
        return ((part as NSString).deletingLastPathComponent as NSString).appendingPathComponent("_rels/\(name).rels")
    }

    private func relationships(of part: String) throws -> [XMLElement] {
        let path = Self.relationshipsPath(of: part)
        guard parts[path] != nil || FileManager.default.fileExists(atPath: file(path).path) else { return [] }
        return (try self.part(path).rootElement()?.children ?? []).compactMap { $0 as? XMLElement }
    }

    /// A package path for a relationship target, confined to the package however many ".."s it has.
    private static func resolve(_ target: String, from part: String) -> String {
        let decoded = target.removingPercentEncoding ?? target
        let joined = decoded.hasPrefix("/") ? decoded : "/" + ((part as NSString).deletingLastPathComponent as NSString).appendingPathComponent(decoded)
        return String(URL(fileURLWithPath: joined).standardized.path.dropFirst())
    }

    /// Copies relationship `id` and what it points to. Returns the new id, or nil if there's no such relationship.
    private func copyRelationship(_ id: String, from other: WordDocument, otherPart: String, toPart: String) throws -> String? {
        guard let rel = try other.relationships(of: otherPart).first(where: { $0.attribute(forName: "Id")?.stringValue == id }),
              let type = rel.attribute(forName: "Type")?.stringValue, let target = rel.attribute(forName: "Target")?.stringValue else { return nil }
        if rel.attribute(forName: "TargetMode")?.stringValue == "External" {
            return try addRelationship(to: toPart, type: type, target: target, external: true)
        }
        let new = try copyPart(Self.resolve(target, from: otherPart), from: other)
        return try addRelationship(to: toPart, type: type, target: "/\(new)", external: false)
    }

    /// Copies a part and everything it relates to under a folder of its own, so names can't clash.
    private func copyPart(_ source: String, from other: WordDocument) throws -> String {
        let new = "word/merged\(mergeCount)/\(source)"
        guard !FileManager.default.fileExists(atPath: file(new).path) else { return new }
        guard FileManager.default.fileExists(atPath: other.file(source).path) else {
            throw SwitchelError("A Word document is missing \(source)")
        }
        try FileManager.default.createDirectory(at: file(new).deletingLastPathComponent(), withIntermediateDirectories: true)
        if let parsed = other.parts[source] {
            try parsed.xmlData(options: [.nodePreserveAll]).write(to: file(new))
        } else {
            try FileManager.default.copyItem(at: other.file(source), to: file(new))
        }
        try copyContentType(of: source, as: new, from: other)
        let relationships = try other.relationships(of: source)
        guard !relationships.isEmpty else { return new }
        let path = Self.relationshipsPath(of: new)
        try FileManager.default.createDirectory(at: file(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = XMLDocument(rootElement: XMLElement(name: "Relationships", uri: Self.relationshipsNamespace))
        document.rootElement()?.addNamespace(XMLNode.namespace(withName: "", stringValue: Self.relationshipsNamespace) as! XMLNode)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        parts[path] = document
        for rel in relationships {
            guard let copy = rel.copy() as? XMLElement else { continue }
            if rel.attribute(forName: "TargetMode")?.stringValue != "External", let target = rel.attribute(forName: "Target")?.stringValue {
                let copied = try copyPart(Self.resolve(target, from: source), from: other)
                copy.attribute(forName: "Target")?.stringValue = Self.encoded("/\(copied)")
            }
            document.rootElement()?.addChild(copy)
        }
        return new
    }

    private static func encoded(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    private func addRelationship(to part: String, type: String, target: String, external: Bool) throws -> String {
        let path = Self.relationshipsPath(of: part)
        let document: XMLDocument
        if parts[path] != nil || FileManager.default.fileExists(atPath: file(path).path) {
            document = try self.part(path)
        } else {
            try FileManager.default.createDirectory(at: file(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            let root = XMLElement(name: "Relationships", uri: Self.relationshipsNamespace)
            root.addNamespace(XMLNode.namespace(withName: "", stringValue: Self.relationshipsNamespace) as! XMLNode)
            document = XMLDocument(rootElement: root)
            document.version = "1.0"
            document.characterEncoding = "UTF-8"
            parts[path] = document
        }
        guard let root = document.rootElement() else { throw SwitchelError("Couldn't update the Word document") }
        let existing = Set((root.children ?? []).compactMap { ($0 as? XMLElement)?.attribute(forName: "Id")?.stringValue })
        var number = existing.count + 1
        while existing.contains("rIdMerged\(number)") { number += 1 }
        let id = "rIdMerged\(number)"
        let element = XMLElement(name: "Relationship", uri: Self.relationshipsNamespace)
        var attributes = ["Id": id, "Type": type, "Target": external ? target : Self.encoded(target)]
        if external { attributes["TargetMode"] = "External" }
        element.setAttributesWith(attributes)
        root.addChild(element)
        return id
    }

    private func copyContentType(of source: String, as new: String, from other: WordDocument) throws {
        let name = "[Content_Types].xml"
        guard let root = try part(name).rootElement(), let otherRoot = try other.part(name).rootElement() else { return }
        let otherEntries = (otherRoot.children ?? []).compactMap { $0 as? XMLElement }
        if let override = otherEntries.first(where: { $0.localName == "Override" && $0.attribute(forName: "PartName")?.stringValue == "/\(source)" }),
           let copy = override.copy() as? XMLElement {
            copy.attribute(forName: "PartName")?.stringValue = Self.encoded("/\(new)")
            root.addChild(copy)
            return
        }
        let ext = (source as NSString).pathExtension.lowercased()
        let known = (root.children ?? []).compactMap { $0 as? XMLElement }.contains {
            $0.localName == "Default" && $0.attribute(forName: "Extension")?.stringValue?.lowercased() == ext
        }
        guard !known, let entry = otherEntries.first(where: {
            $0.localName == "Default" && $0.attribute(forName: "Extension")?.stringValue?.lowercased() == ext
        }), let copy = entry.copy() as? XMLElement else { return }
        // Defaults come before overrides.
        root.insertChild(copy, at: 0)
    }

    private static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relationshipsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
}

// MARK: XML helpers

/// A WordprocessingML element, in either the transitional or the strict namespace.
private func isWord(_ element: XMLElement, _ name: String) -> Bool {
    element.localName == name && element.uri?.contains("wordprocessingml") == true
}

private func forEachElement(in element: XMLElement, _ visit: (XMLElement) -> Void) {
    visit(element)
    for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) { forEachElement(in: child, visit) }
}

private func contains(_ element: XMLElement, _ name: String) -> Bool {
    var found = false
    forEachElement(in: element) { if isWord($0, name) { found = true } }
    return found
}
