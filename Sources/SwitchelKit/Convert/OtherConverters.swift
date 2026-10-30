import AppKit

// MARK: Spreadsheets

enum SpreadsheetFormat: String, CaseIterable {
    case xlsx, ods, csv, tsv, pdf
}

enum SpreadsheetConverter {
    @MainActor
    static func convert(_ url: URL, to format: SpreadsheetFormat) async throws -> URL {
        let out = Output.url(for: url, ext: format.rawValue)
        // Numbers keeps fonts, colours, borders, merged cells and number formats that a plain table can't.
        let source = Output.normalizedExtension(url)
        if ["xlsx", "xls", "numbers"].contains(source), IWork.canUse(.numbers), format == .pdf || (format == .xlsx && source != "xlsx") {
            do {
                try await IWork.export(url, with: .numbers, to: out, as: format == .pdf ? "PDF" : "Microsoft Excel")
                return out
            } catch where source == "xlsx" {
                // Without Automation permission, fall back to the built-in conversion.
            }
        }
        let table = try await read(url)
        switch format {
        case .xlsx: try await Packages.writeXLSX(table, to: out)
        case .ods: try await Packages.writeODS(table, to: out)
        case .csv: try CSV.format(table, separator: ",").write(to: out, atomically: true, encoding: .utf8)
        case .tsv: try CSV.format(table, separator: "\t").write(to: out, atomically: true, encoding: .utf8)
        case .pdf: try DocumentConverter.writePDF(try DocumentConverter.html(Data(htmlTable(table).utf8)), to: out)
        }
        return out
    }

    static func read(_ url: URL) async throws -> Table {
        switch Output.normalizedExtension(url) {
        case "csv": return CSV.parse(try String(contentsOf: url), separator: ",")
        case "tsv": return CSV.parse(try String(contentsOf: url), separator: "\t")
        case "xlsx": return try await Packages.readXLSX(url)
        case "ods": return try await Packages.readODS(url)
        default:
            // .xls and .numbers: Numbers re-saves them as XLSX.
            let folder = try Output.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let xlsx = folder.appendingPathComponent("export.xlsx")
            try await IWork.export(url, with: .numbers, to: xlsx, as: "Microsoft Excel")
            return try await Packages.readXLSX(xlsx)
        }
    }

    static func htmlTable(_ table: Table) -> String {
        let rows = table.enumerated().map { index, row in
            let tag = index == 0 ? "th" : "td"
            return "<tr>" + row.map { "<\(tag)>\($0.xmlEscaped)</\(tag)>" }.joined() + "</tr>"
        }.joined(separator: "\n")
        return """
        <html><head><meta charset="utf-8"><style>
        table { border-collapse: collapse; font: 9pt Helvetica; } td, th { border: 1px solid #999; padding: 2px 4px; } th { background: #eee; }
        </style></head><body><table>\(rows)</table></body></html>
        """
    }
}

/// RFC 4180: quoted fields may contain separators, quotes ("") and newlines.
enum CSV {
    static func parse(_ text: String, separator: Character) -> Table {
        var table: Table = [], row: [String] = [], field = ""
        var quoted = false, iterator = text.makeIterator()
        var pending = iterator.next()
        while let character = pending {
            pending = iterator.next()
            if quoted {
                if character == "\"" {
                    if pending == "\"" { field.append("\""); pending = iterator.next() } else { quoted = false }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == separator {
                row.append(field); field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field); table.append(row); row = []; field = ""
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); table.append(row) }
        return table
    }

    static func format(_ table: Table, separator: Character) -> String {
        table.map { row in
            row.map { field in
                field.contains(separator) || field.contains("\"") || field.contains("\n")
                    ? "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\"" : field
            }.joined(separator: String(separator))
        }.joined(separator: "\n") + "\n"
    }
}

// MARK: Presentations

enum PresentationFormat: String, CaseIterable {
    case pdf, jpg, png
}

/// PowerPoint, Keynote and OpenDocument slides go through Keynote.
enum PresentationConverter {
    static func convert(_ url: URL, to format: PresentationFormat) async throws -> URL {
        if format == .pdf {
            let out = Output.url(for: url, ext: "pdf")
            try await IWork.export(url, with: .keynote, to: out, as: "PDF")
            return out
        }
        let scratch = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let exported = scratch.appendingPathComponent("slides")
        try await IWork.export(url, with: .keynote, to: exported, as: "slide images",
                               properties: "{image format:\(format == .png ? "PNG" : "JPEG")}")
        let images = try FileManager.default.contentsOfDirectory(at: exported, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !images.isEmpty else { throw SwitchelError("Keynote didn't export any slides") }

        let base = Output.baseName(url)
        if images.count == 1 {
            let out = Output.url(for: url, ext: format.rawValue)
            try FileManager.default.moveItem(at: images[0], to: out)
            return out
        }
        let folder = Output.url(for: url, ext: nil, suffix: "slides")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, image) in images.enumerated() {
            try FileManager.default.moveItem(at: image, to: folder.appendingPathComponent("\(base) \(i + 1).\(format.rawValue)"))
        }
        return folder
    }
}

// MARK: Subtitles

enum SubtitleFormat: String, CaseIterable {
    case srt, vtt, txt
}

enum SubtitleConverter {
    struct Cue: Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    static func convert(_ url: URL, to format: SubtitleFormat) throws -> URL {
        let cues = parse(try String(contentsOf: url))
        let out = Output.url(for: url, ext: format.rawValue)
        try write(cues, as: format).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// Reads both SRT and WebVTT: blocks separated by blank lines, timed by an "a --> b" line.
    static func parse(_ text: String) -> [Cue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0]),
                  let end = seconds(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "") else { return nil }
            return Cue(start: start, end: end, text: lines[(timing + 1)...].joined(separator: "\n"))
        }
    }

    /// "01:02:03,456", "01:02:03.456" or WebVTT's short "02:03.456".
    static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    static func write(_ cues: [Cue], as format: SubtitleFormat) -> String {
        func stamp(_ seconds: Double, _ separator: String) -> String {
            let ms = Int((seconds * 1000).rounded())
            return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
        }
        switch format {
        case .srt:
            return cues.enumerated().map { "\($0.offset + 1)\n\(stamp($0.element.start, ",")) --> \(stamp($0.element.end, ","))\n\($0.element.text)" }
                .joined(separator: "\n\n") + "\n"
        case .vtt:
            return "WEBVTT\n\n" + cues.map { "\(stamp($0.start, ".")) --> \(stamp($0.end, "."))\n\($0.text)" }.joined(separator: "\n\n") + "\n"
        case .txt:
            return cues.map(\.text).joined(separator: "\n") + "\n"
        }
    }
}

// MARK: Archives

enum ArchiveFormat: String, CaseIterable {
    case zip, tar, gz

    var fileExtension: String { self == .gz ? "tar.gz" : rawValue }
}

/// bsdtar reads ZIP, TAR, GZIP, RAR, 7z and more.
enum ArchiveConverter {
    static func extract(_ url: URL) async throws -> URL {
        let folder = Output.url(for: url, ext: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try await Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", folder.path])
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// Archives a folder, or repacks another archive.
    static func convert(_ url: URL, to format: ArchiveFormat) async throws -> URL {
        let out = Output.url(for: url, ext: format.fileExtension)
        if FileKind(url) == .folder {
            try await pack([url.lastPathComponent], in: url.deletingLastPathComponent(), to: out, as: format)
            return out
        }
        let scratch = try Output.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", scratch.path])
        let items = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0 != ".DS_Store" }
        try await pack(items, in: scratch, to: out, as: format)
        return out
    }

    static func pack(_ items: [String], in folder: URL, to out: URL, as format: ArchiveFormat) async throws {
        switch format {
        case .zip: try await Shell.run("/usr/bin/zip", ["-rqy", out.path] + items, in: folder)
        case .tar: try await Shell.run("/usr/bin/tar", ["-cf", out.path, "-C", folder.path] + items)
        case .gz: try await Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", folder.path] + items)
        }
    }
}
