import Foundation
import UniformTypeIdentifiers

struct SwitchelError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum FileKind: Hashable {
    case image, video, audio, pdf, document, spreadsheet, presentation, subtitle, archive, folder, other

    init(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        let ext = Output.normalizedExtension(url)
        if let kind = Self.byExtension[ext] {
            self = kind
        } else if values?.isDirectory == true && values?.isPackage != true {
            self = .folder
        } else if let type = values?.contentType ?? UTType(filenameExtension: ext) {
            if type.conforms(to: .pdf) { self = .pdf }
            else if type.conforms(to: .image) { self = .image }
            else if type.conforms(to: .movie) { self = .video }
            else if type.conforms(to: .audio) { self = .audio }
            else if type.conforms(to: .plainText) { self = .document }
            else { self = .other }
        } else {
            self = .other
        }
    }

    private static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        let groups: [(FileKind, [String])] = [
            (.image, ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "gif", "svg", "ico", "icns", "psd", "tga", "jp2", "exr"]),
            (.video, ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts", "m2ts", "ogv"]),
            (.audio, ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma", "aac", "caf", "amr", "m4b", "alac"]),
            (.pdf, ["pdf"]),
            (.document, ["docx", "doc", "odt", "rtf", "rtfd", "html", "txt", "md", "epub", "pages", "textclipping"]),
            (.spreadsheet, ["xlsx", "xls", "ods", "csv", "tsv", "numbers"]),
            (.presentation, ["pptx", "ppt", "key", "odp"]),
            (.subtitle, ["srt", "vtt"]),
            (.archive, ["zip", "tar", "gz", "rar", "7z", "bz2", "xz", "tgz"]),
        ]
        for (kind, extensions) in groups {
            for ext in extensions { map[ext] = kind }
        }
        return map
    }()

    /// The kind shared by every file, or `.other` for mixed selections.
    static func common(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(FileKind.init))
        return kinds.count == 1 ? kinds.first! : .other
    }
}

enum Output {
    /// Where results go; nil saves next to the original. Set from Settings.
    static var folderOverride: URL?

    /// A free URL for a result of `source`: "photo.png" → "photo compressed.jpg", then "photo compressed 2.jpg".
    /// A nil `ext` names a folder.
    static func url(for source: URL, ext: String?, suffix: String? = nil) -> URL {
        let folder = folderOverride ?? source.deletingLastPathComponent()
        var base = baseName(source)
        if let suffix { base += " \(suffix)" }
        func candidate(_ name: String) -> URL {
            folder.appendingPathComponent(ext.map { "\(name).\($0)" } ?? name)
        }
        var url = candidate(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate("\(base) \(n)")
            n += 1
        }
        return url
    }

    /// The file name without its extension, treating ".tar.gz" as one extension.
    static func baseName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.lowercased().hasSuffix(".tar") ? String(name.dropLast(4)) : name
    }

    /// Lowercased extension with common aliases folded, so "photo.JPEG" isn't offered JPG.
    static func normalizedExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let aliases = [
            "jpeg": "jpg", "tif": "tiff", "aif": "aiff", "htm": "html", "heif": "heic", "text": "txt",
            "markdown": "md", "oga": "ogg", "xhtml": "html",
        ]
        return aliases[ext] ?? ext
    }

    /// A fresh scratch folder, removed by the caller when done.
    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Switchel", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
