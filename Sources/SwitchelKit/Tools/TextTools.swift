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
        let lines = text.components(separatedBy: .newlines)
        stats.lines = text.isEmpty ? 0 : lines.count - (text.hasSuffix("\n") ? 1 : 0)
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
            var pattern = regularExpression ? find : NSRegularExpression.escapedPattern(for: find)
            if wholeWords { pattern = "\\b\(pattern)\\b" }
            do {
                return try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
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
            switch self {
            case .upper: return text.uppercased()
            case .lower: return text.lowercased()
            case .title: return text.capitalized
            case .sentence:
                var result = "", capitalizeNext = true
                for character in text.lowercased() {
                    if capitalizeNext && character.isLetter {
                        result += character.uppercased()
                        capitalizeNext = false
                    } else {
                        result.append(character)
                    }
                    if ".!?\n".contains(character) { capitalizeNext = true }
                }
                return result
            }
        }
    }

    static func changeCase(_ url: URL, to style: Case) async throws -> URL {
        try await rewrite(url, suffix: style.rawValue) { text in
            if style == .sentence {
                text.replaceCharacters(in: NSRange(location: 0, length: text.length), with: style.apply(text.string))
                return
            }
            // Run by run, so each keeps its formatting.
            var runs: [NSRange] = []
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { _, range, _ in runs.append(range) }
            for range in runs.reversed() {
                text.replaceCharacters(in: range, with: style.apply((text.string as NSString).substring(with: range)))
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
        var lines = text.components(separatedBy: .newlines)
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
        let original = try String(contentsOf: url)
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
            let parts = try sorted.map { try String(contentsOf: $0).trimmingCharacters(in: .newlines) }
            try (parts.joined(separator: "\n\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        let combined = NSMutableAttributedString()
        for url in sorted {
            if combined.length > 0 { combined.append(NSAttributedString(string: "\n\n")) }
            combined.append(try await DocumentConverter.read(url))
        }
        let out = Output.url(for: sorted[0], ext: "docx", suffix: "merged")
        try await DocumentConverter.write(combined, as: .docx, to: out, title: Output.baseName(sorted[0]))
        return out
    }

    // MARK: Helpers

    /// Reads, edits and writes a copy in the same format.
    private static func rewrite(_ url: URL, suffix: String, _ edit: (NSMutableAttributedString) throws -> Void) async throws -> URL {
        if isPlain(url) {
            var encoding = String.Encoding.utf8
            let text = NSMutableAttributedString(string: try String(contentsOf: url, usedEncoding: &encoding))
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
    /// Moves every cue by `seconds` (negative is earlier), never before zero.
    static func shift(_ url: URL, by seconds: Double) throws -> URL {
        let cues = SubtitleConverter.parse(try String(contentsOf: url)).map { cue in
            SubtitleConverter.Cue(start: max(cue.start + seconds, 0), end: max(cue.end + seconds, 0), text: cue.text)
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
            for url in urls {
                try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent(url.lastPathComponent), withDestinationURL: url)
            }
            try await Shell.run("/usr/bin/zip", ["-rq", out.path] + urls.map(\.lastPathComponent), in: scratch)
        }
        return out
    }
}
