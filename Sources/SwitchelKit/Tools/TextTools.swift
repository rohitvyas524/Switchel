import AppKit

/// Tools for text and documents. Plain formats (TXT, Markdown, CSV…) are edited as text;
/// rich ones (DOCX, RTF, ODT, HTML, Pages) keep their formatting.
@MainActor
enum TextTools {
    /// Formats edited character for character, so Markdown keeps its syntax.
    nonisolated static let plainExtensions: Set<String> = ["txt", "md", "csv", "tsv", "srt", "vtt"]

    nonisolated static func isPlain(_ url: URL) -> Bool { plainExtensions.contains(Output.normalizedExtension(url)) }

    // MARK: Count

    struct Stats: Equatable {
        var words = 0
        var characters = 0
        var charactersWithoutSpaces = 0
        var lines = 0
        var paragraphs = 0
        /// At 200 words a minute.
        var readingMinutes: Double { Double(words) / 200 }
    }

    static func stats(of text: String) -> Stats {
        var stats = Stats()
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in stats.words += 1 }
        stats.characters = text.count
        stats.charactersWithoutSpaces = text.filter { !$0.isWhitespace }.count
        let unified = text.unifiedLineEndings
        let lines = unified.components(separatedBy: .newlines)
        stats.lines = text.isEmpty ? 0 : lines.count - (unified.hasSuffix("\n") ? 1 : 0)
        stats.paragraphs = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return stats
    }

    static func stats(of url: URL) async throws -> Stats {
        stats(of: try await DocumentConverter.read(url).string)
    }

    // MARK: Find and replace

    struct Replacement: Equatable {
        var find = ""
        var replace = ""
        var caseSensitive = false
        var regularExpression = false
        var wholeWords = false

        /// The pattern as a regular expression, whichever mode is on.
        func expression() throws -> NSRegularExpression {
            let pattern = regularExpression ? find : NSRegularExpression.escapedPattern(for: find)
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            do {
                // Checked alone first, because the group below could balance a pattern like "a)|(b".
                let plain = try NSRegularExpression(pattern: pattern, options: options)
                return wholeWords ? try NSRegularExpression(pattern: "\\b(?:\(pattern))\\b", options: options) : plain
            } catch {
                throw SwitchelError("“\(find)” isn't a valid regular expression")
            }
        }
    }

    static func matches(in text: String, _ replacement: Replacement) -> Int {
        guard !replacement.find.isEmpty, let expression = try? replacement.expression() else { return 0 }
        return expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Saves a copy with every match replaced, keeping formatting in rich documents.
    static func findAndReplace(_ url: URL, _ replacement: Replacement) async throws -> URL {
        guard !replacement.find.isEmpty else { throw SwitchelError("Enter something to find") }
        let expression = try replacement.expression()
        let template = replacement.regularExpression ? replacement.replace : NSRegularExpression.escapedTemplate(for: replacement.replace)
        let word = try await rewriteWord(url, suffix: "edited") { paragraphs in
            let count = paragraphs.reduce(0) { $0 + $1.replaceMatches(of: expression, template: template) }
            guard count > 0 else { throw SwitchelError("“\(replacement.find)” wasn't found") }
        }
        if let word { return word }
        return try await rewrite(url, suffix: "edited") { text in
            // Back to front, so earlier ranges stay valid.
            let matches = expression.matches(in: text.string, range: NSRange(location: 0, length: text.length))
            guard !matches.isEmpty else { throw SwitchelError("“\(replacement.find)” wasn't found") }
            for match in matches.reversed() {
                let substitute = expression.replacementString(for: match, in: text.string, offset: 0, template: template)
                text.replaceCharacters(in: match.range, with: substitute)
            }
        }
    }

    // MARK: Case

    enum Case: String, CaseIterable, Identifiable {
        case upper, lower, title, sentence
        var id: Self { self }

        var title: String {
            switch self {
            case .upper: "UPPERCASE"
            case .lower: "lowercase"
            case .title: "Title Case"
            case .sentence: "Sentence case"
            }
        }

        func apply(_ text: String) -> String {
            var capitalizeNext = true
            return apply(text, capitalizeNext: &capitalizeNext)
        }

        /// One piece of a longer text. `capitalizeNext` carries over, so a word or sentence
        /// that spans differently formatted runs still comes out right.
        func apply(_ text: String, capitalizeNext: inout Bool) -> String {
            switch self {
            case .upper: return text.uppercased()
            case .lower: return text.lowercased()
            case .title:
                var result = ""
                for character in text {
                    result += capitalizeNext ? character.uppercased() : character.lowercased()
                    if character.isLetter || character.isNumber {
                        capitalizeNext = false
                    } else if !"'’".contains(character) {
                        capitalizeNext = true
                    }
                }
                return result
            case .sentence:
                var result = ""
                for character in text {
                    if capitalizeNext && character.isLetter {
                        result += character.uppercased()
                        capitalizeNext = false
                    } else {
                        result += character.lowercased()
                    }
                    if ".!?".contains(character) || character.isNewline { capitalizeNext = true }
                }
                return result
            }
        }
    }

    static func changeCase(_ url: URL, to style: Case) async throws -> URL {
        let word = try await rewriteWord(url, suffix: style.rawValue) { paragraphs in
            for paragraph in paragraphs {
                var capitalizeNext = true
                paragraph.mapText { style.apply($0, capitalizeNext: &capitalizeNext) }
            }
        }
        if let word { return word }
        return try await rewrite(url, suffix: style.rawValue) { text in
            // Run by run, so each keeps its formatting.
            var runs: [NSRange] = []
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { _, range, _ in runs.append(range) }
            var capitalizeNext = true
            let replacements = runs.map { style.apply((text.string as NSString).substring(with: $0), capitalizeNext: &capitalizeNext) }
            for (range, replacement) in zip(runs, replacements).reversed() {
                text.replaceCharacters(in: range, with: replacement)
            }
        }
    }

    // MARK: Clean up

    struct Cleanup: Equatable {
        var trimTrailingSpaces = true
        var collapseBlankLines = true
        var removeDuplicateLines = false
        var sortLines = false
    }

    static func clean(_ text: String, _ options: Cleanup) -> String {
        var lines = text.unifiedLineEndings.components(separatedBy: .newlines)
        if options.trimTrailingSpaces {
            lines = lines.map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }
        }
        if options.removeDuplicateLines {
            var seen = Set<String>()
            lines = lines.filter { $0.isEmpty || seen.insert($0).inserted }
        }
        if options.sortLines {
            lines = lines.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        if options.collapseBlankLines {
            lines = lines.enumerated().filter { $0.offset == 0 || !($0.element.isEmpty && lines[$0.offset - 1].isEmpty) }.map(\.element)
        }
        return lines.joined(separator: "\n")
    }

    static func cleanUp(_ url: URL, _ options: Cleanup) async throws -> URL {
        let original = try String(readingText: url)
        let out = Output.url(for: url, ext: url.pathExtension, suffix: "clean")
        try clean(original, options).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    // MARK: Merge

    /// Joins the files in name order. Plain text stays plain; rich documents become one DOCX.
    static func merge(_ urls: [URL]) async throws -> URL {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if sorted.allSatisfy(isPlain) {
            let ext = sorted[0].pathExtension
            let out = Output.url(for: sorted[0], ext: ext, suffix: "merged")
            let parts = try sorted.map { try String(readingText: $0).trimmingCharacters(in: .newlines) }
            try (parts.joined(separator: "\n\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        // Joined as Word files, so pictures and tables come along.
        let scratch = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var merged: WordDocument?
        for (index, url) in sorted.enumerated() {
            let document = try await WordDocument(try await wordFile(for: url, in: scratch, index: index))
            if let merged { try merged.append(document) } else { merged = document }
        }
        let out = Output.url(for: sorted[0], ext: "docx", suffix: "merged")
        try await merged?.save(to: out)
        return out
    }

    // MARK: Helpers

    /// A Word file with the document's content: itself, Pages' faithful export, or else the text system's.
    private static func wordFile(for url: URL, in folder: URL, index: Int) async throws -> URL {
        let ext = Output.normalizedExtension(url)
        if ext == "docx" { return url }
        let docx = folder.appendingPathComponent("\(index).docx")
        if ext == "pages" || (ext == "doc" && IWork.canUse(.pages)) {
            try await IWork.export(url, with: .pages, to: docx, as: "Microsoft Word")
        } else {
            try await DocumentConverter.write(try await DocumentConverter.read(url), as: .docx, to: docx, title: Output.baseName(url))
        }
        return docx
    }

    /// Edits Word and Pages files through Word's XML, keeping pictures and tables the text system would drop.
    /// Returns nil for other formats. Pages files go through Pages, and come back as Pages files.
    private static func rewriteWord(_ url: URL, suffix: String, _ edit: ([WordDocument.Paragraph]) throws -> Void) async throws -> URL? {
        let ext = Output.normalizedExtension(url)
        guard ext == "docx" || ext == "pages" || (ext == "doc" && IWork.canUse(.pages)) else { return nil }
        let scratch = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let document = try await WordDocument(try await wordFile(for: url, in: scratch, index: 0))
        try edit(try document.paragraphs())
        guard ext == "pages" else {
            let out = Output.url(for: url, ext: "docx", suffix: suffix)
            try await document.save(to: out)
            return out
        }
        let edited = scratch.appendingPathComponent("\(Output.baseName(url)).docx")
        try await document.save(to: edited)
        let out = Output.url(for: url, ext: "pages", suffix: suffix)
        try await IWork.save(edited, with: .pages, to: out)
        return out
    }

    /// Reads, edits and writes a copy in the same format.
    private static func rewrite(_ url: URL, suffix: String, _ edit: (NSMutableAttributedString) throws -> Void) async throws -> URL {
        if isPlain(url) {
            let text = NSMutableAttributedString(string: try String(readingText: url))
            try edit(text)
            let out = Output.url(for: url, ext: url.pathExtension, suffix: suffix)
            try text.string.write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        let text = NSMutableAttributedString(attributedString: try await DocumentConverter.read(url))
        try edit(text)
        // Keep the source format when we can write it; otherwise DOCX.
        let format = DocumentFormat(rawValue: Output.normalizedExtension(url)).flatMap { [.epub, .pdf].contains($0) ? nil : $0 } ?? .docx
        let out = Output.url(for: url, ext: format.rawValue, suffix: suffix)
        try await DocumentConverter.write(text, as: format, to: out, title: Output.baseName(url))
        return out
    }
}

enum SubtitleTools {
    /// Moves every cue by `seconds` (negative is earlier). Cues that end before zero are dropped;
    /// ones that straddle it start at zero.
    static func shift(_ url: URL, by seconds: Double) throws -> URL {
        let original = SubtitleConverter.parse(try String(readingText: url))
        let cues = original.compactMap { cue -> SubtitleConverter.Cue? in
            guard cue.end + seconds > 0 else { return nil }
            return SubtitleConverter.Cue(start: max(cue.start + seconds, 0), end: cue.end + seconds, text: cue.text)
        }
        guard !cues.isEmpty || original.isEmpty else {
            throw SwitchelError("Shifting by \(seconds) seconds would move every subtitle before the start")
        }
        let format = SubtitleFormat(rawValue: Output.normalizedExtension(url)) ?? .srt
        let out = Output.url(for: url, ext: format.rawValue, suffix: "shifted")
        try SubtitleConverter.write(cues, as: format).write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

extension SpreadsheetConverter {
    /// Stacks the sheets' rows into one XLSX, keeping a shared header row only once.
    @MainActor
    static func merge(_ urls: [URL]) async throws -> URL {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var merged: Table = []
        for url in sorted {
            var table = try await read(url)
            if let header = merged.first, table.first == header { table.removeFirst() }
            merged += table
        }
        let out = Output.url(for: sorted[0], ext: "xlsx", suffix: "merged")
        try await Packages.writeXLSX(merged, to: out)
        return out
    }
}

extension ArchiveConverter {
    /// Zips any files and folders together. One item is named after itself; several, after their folder.
    static func zip(_ urls: [URL]) async throws -> URL {
        let parent = urls[0].deletingLastPathComponent()
        let name = urls.count == 1 ? Output.baseName(urls[0]) : parent.lastPathComponent
        let out = Output.url(for: parent.appendingPathComponent(name), ext: "zip")
        // zip stores paths relative to where it runs, so files from different folders are linked into one.
        if urls.allSatisfy({ $0.deletingLastPathComponent() == parent }) {
            try await pack(urls.map(\.lastPathComponent), in: parent, to: out, as: .zip)
        } else {
            let scratch = try Output.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: scratch) }
            var used = Set<String>()
            var names: [String] = []
            for url in urls {
                let name = uniqueName(for: url, taken: &used)
                try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent(name), withDestinationURL: url)
                names.append("./\(name)")
            }
            // "./" keeps a name starting with "-" from being read as an option.
            try await Shell.run("/usr/bin/zip", ["-rq", out.path] + names, in: scratch)
        }
        return out
    }

    /// "a.txt", then "a 2.txt". Compared ignoring case, as most Mac disks do.
    private static func uniqueName(for url: URL, taken: inout Set<String>) -> String {
        var name = url.lastPathComponent, n = 2
        while !taken.insert(name.lowercased()).inserted {
            let base = url.deletingPathExtension().lastPathComponent
            name = url.pathExtension.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(url.pathExtension)"
            n += 1
        }
        return name
    }
}
