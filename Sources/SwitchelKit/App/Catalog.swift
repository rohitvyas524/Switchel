import AppKit

/// One slice of the wheel. `run` returns the files it created.
struct WheelItem {
    let title: String
    let symbol: String
    /// Opens its own window, so no progress toast is shown up front.
    var interactive = false
    let run: @MainActor ([URL]) async throws -> [URL]
}

enum Catalog {
    static func items(for mode: Mode, urls: [URL]) -> [WheelItem] {
        switch mode {
        case .convert: convert(urls)
        case .tools: tools(urls)
        case .actions: actions()
        }
    }

    // MARK: Convert

    static func convert(_ urls: [URL]) -> [WheelItem] {
        let own = Set(urls.map(Output.normalizedExtension))
        func targets<F: RawRepresentable & CaseIterable>(_: F.Type, excluding: Set<String> = []) -> [F] where F.RawValue == String {
            F.allCases.filter { !own.contains($0.rawValue) && !excluding.contains($0.rawValue) }
        }
        func slice(_ title: String, _ symbol: String, _ body: @escaping @MainActor (URL) async throws -> URL) -> WheelItem {
            eachAsync(title.uppercased(), symbol, body)
        }

        switch FileKind.common(urls) {
        case .image:
            return targets(ImageFormat.self).map { format in
                slice(format.rawValue, format == .pdf ? "doc.richtext" : "photo") { try await ImageConverter.convert($0, to: format) }
            }
        case .video:
            return targets(VideoFormat.self).map { format in
                slice(format.rawValue, format == .mp3 ? "waveform" : format == .gif ? "photo.stack" : "film") {
                    try await MediaConverter.convert($0, to: format)
                }
            }
        case .audio:
            return targets(AudioFormat.self).map { format in
                slice(format.rawValue, "waveform") { try await MediaConverter.convert($0, to: format) }
            }
        case .pdf:
            return targets(PDFFormat.self).map { format in
                let symbol: String = switch format {
                case .jpg, .png: "photo"
                case .pptx: "rectangle.on.rectangle"
                case .xlsx: "tablecells"
                case .epub: "book"
                default: "doc.text"
                }
                // Word, Pages and PowerPoint ask whether to keep text editable or pages exact.
                if [.docx, .pages, .pptx].contains(format) {
                    return WheelItem(title: format.rawValue.uppercased(), symbol: symbol, interactive: true) {
                        try await PDFEditors.convertToOffice($0, format: format)
                    }
                }
                return slice(format.rawValue, symbol) { try await PDFConverter.convert($0, to: format) }
            }
        case .document:
            return targets(DocumentFormat.self).map { format in
                slice(format.rawValue, format == .pdf ? "doc.richtext" : format == .epub ? "book" : "doc.text") {
                    try await DocumentConverter.convert($0, to: format)
                }
            }
        case .spreadsheet:
            return targets(SpreadsheetFormat.self).map { format in
                slice(format.rawValue, format == .pdf ? "doc.richtext" : "tablecells") { try await SpreadsheetConverter.convert($0, to: format) }
            }
        case .presentation:
            return targets(PresentationFormat.self).map { format in
                slice(format.rawValue, format == .pdf ? "doc.richtext" : "photo") { try await PresentationConverter.convert($0, to: format) }
            }
        case .subtitle:
            return targets(SubtitleFormat.self).map { format in
                slice(format.rawValue, "captions.bubble") { try SubtitleConverter.convert($0, to: format) }
            }
        case .archive:
            let own = Set(urls.map { $0.lastPathComponent.lowercased().hasSuffix(".tar.gz") || $0.pathExtension.lowercased() == "tgz" ? "gz" : Output.normalizedExtension($0) })
            return ArchiveFormat.allCases.filter { !own.contains($0.rawValue) }.map { format in
                slice(format == .gz ? "tar.gz" : format.rawValue, "archivebox") { try await ArchiveConverter.convert($0, to: format) }
            }
        case .folder:
            return ArchiveFormat.allCases.map { format in
                slice(format == .gz ? "tar.gz" : format.rawValue, "archivebox") { try await ArchiveConverter.convert($0, to: format) }
            }
        case .other:
            return []
        }
    }

    // MARK: Tools

    static func tools(_ urls: [URL]) -> [WheelItem] {
        let many = urls.count > 1
        switch FileKind.common(urls) {
        case .image:
            var items = [
                editor("Compress", "arrow.down.right.and.arrow.up.left", ImageEditors.compress),
                editor("Crop", "crop") { try await ImageEditors.crop($0[0]) },
                editor("Adjust", "slider.horizontal.3") { try await ImageEditors.adjust($0[0]) },
                editor("Annotate", "pencil.tip.crop.circle") { try await ImageEditors.annotate($0[0]) },
                editor("Redact", "eye.slash") { try await ImageEditors.redact($0[0]) },
                editor("Background", "person.crop.rectangle") { try await ImageEditors.background($0[0]) },
                editor("Frame", "rectangle.inset.filled") { try await ImageEditors.frame($0[0]) },
                editor("Metadata", "info.circle") { try await ImageEditors.metadata($0[0]) },
                editor("QR Code", "qrcode.viewfinder", ImageEditors.qrCodes),
                editor("Icon", "app.dashed") { try await ImageEditors.icon($0[0]) },
                eachAsync("Rotate", "rotate.right") { try await ImageTools.rotateClockwise($0) },
                all(many ? "Combine PDF" : "Make PDF", "doc.richtext", ImageTools.combineIntoPDF),
            ]
            if many { items.insert(editor("Collage", "square.grid.2x2", ImageEditors.collage), at: 1) }
            return items
        case .video:
            var items = [
                editor("Compress", "arrow.down.right.and.arrow.up.left", MediaEditors.compressVideo),
                editor("Crop", "crop") { try await MediaEditors.cropVideo($0[0]) },
                editor("Trim", "timeline.selection") { try await MediaEditors.trimVideo($0[0]) },
                editor("Split", "scissors") { try await MediaEditors.splitVideo($0[0]) },
                editor("Speed", "gauge.with.dots.needle.67percent") { try await MediaEditors.speed($0[0]) },
                editor("GIF", "photo.stack") { try await MediaEditors.gif($0[0]) },
                editor("Redact", "eye.slash") { try await MediaEditors.redactVideo($0[0]) },
                editor("Snapshots", "camera") { try await MediaEditors.snapshots($0[0]) },
                eachAsync("Mute", "speaker.slash") { try await VideoTools.removeAudio($0) },
            ]
            if many { items.insert(WheelItem(title: "Merge", symbol: "rectangle.stack") { [try await VideoTools.merge($0)] }, at: 1) }
            return items
        case .audio:
            var items = [
                editor("Compress", "arrow.down.right.and.arrow.up.left", MediaEditors.compressAudio),
                editor("Trim", "timeline.selection") { try await MediaEditors.trimAudio($0[0]) },
                editor("Normalize", "speaker.wave.3", MediaEditors.normalize),
                editor("Channels", "headphones") { try await MediaEditors.channels($0[0]) },
                editor("Bleep", "speaker.badge.exclamationmark") { try await MediaEditors.bleep($0[0]) },
                editor("Visualize", "waveform.path.ecg.rectangle") { try await MediaEditors.visualize($0[0]) },
            ]
            if many { items.insert(WheelItem(title: "Merge", symbol: "rectangle.stack") { [try await AudioTools.merge($0)] }, at: 1) }
            return items
        case .pdf:
            var items = [
                each("Compress", "arrow.down.right.and.arrow.up.left", PDFTools.compress),
                editor("Organize", "square.grid.3x3") { try await PDFEditors.organize($0[0]) },
                editor("Split", "scissors") { try await PDFEditors.split($0[0]) },
            ]
            if many { items.insert(all("Merge", "doc.on.doc", PDFTools.merge), at: 0) }
            return items
        case .archive:
            return [eachAsync("Extract", "archivebox") { try await ArchiveConverter.extract($0) }]
        case .document:
            let plain = urls.allSatisfy { TextTools.isPlain($0) }
            var items = [
                editor("Word Count", "textformat.123", DocumentEditors.wordCount),
                editor("Find & Replace", "magnifyingglass", DocumentEditors.findAndReplace),
                editor("Change Case", "textformat", DocumentEditors.changeCase),
            ]
            if plain { items.append(editor("Clean Up", "sparkles", DocumentEditors.cleanUp)) }
            if many { items.append(WheelItem(title: "Merge", symbol: "doc.on.doc") { [try await TextTools.merge($0)] }) }
            items += [
                eachAsync("Make PDF", "doc.richtext") { try await DocumentConverter.convert($0, to: .pdf) },
                zip,
            ]
            return items
        case .spreadsheet:
            var items = [eachAsync("Make PDF", "doc.richtext") { try await SpreadsheetConverter.convert($0, to: .pdf) }]
            if many { items.append(WheelItem(title: "Merge", symbol: "tablecells") { [try await SpreadsheetConverter.merge($0)] }) }
            return items + [zip]
        case .presentation:
            return [eachAsync("Make PDF", "doc.richtext") { try await PresentationConverter.convert($0, to: .pdf) }, zip]
        case .subtitle:
            return [
                editor("Shift Timing", "clock.arrow.2.circlepath", DocumentEditors.shiftSubtitles),
                eachAsync("Make TXT", "text.alignleft") { try SubtitleConverter.convert($0, to: .txt) },
                zip,
            ]
        case .folder, .other:
            return [zip]
        }
    }

    /// Every Tools wheel can at least zip what was dragged.
    private static var zip: WheelItem {
        WheelItem(title: "ZIP", symbol: "doc.zipper") { [try await ArchiveConverter.zip($0)] }
    }

    // MARK: Actions

    /// Actions work on anything, including folders and mixed selections.
    static func actions() -> [WheelItem] {
        [
            WheelItem(title: "AirDrop", symbol: "dot.radiowaves.left.and.right") { try FileActions.airDrop($0); return [] },
            WheelItem(title: "Float", symbol: "rectangle.on.rectangle.angled") { FloatShelf.shared.create(with: $0); return [] },
            WheelItem(title: "Copy", symbol: "doc.on.clipboard") { FileActions.copyFiles($0); return [] },
            WheelItem(title: "Move", symbol: "folder.badge.plus", interactive: true) { try FileActions.move($0) },
            WheelItem(title: "Copy Path", symbol: "link") { FileActions.copyPaths($0); return [] },
            WheelItem(title: "Terminal", symbol: "terminal") { try FileActions.openInTerminal($0); return [] },
        ]
    }

    // MARK: Builders

    private static func editor(_ title: String, _ symbol: String, _ open: @escaping @MainActor ([URL]) async throws -> [URL]) -> WheelItem {
        WheelItem(title: title, symbol: symbol, interactive: true, run: open)
    }

    /// Runs a synchronous per-file job off the main thread.
    private static func each(_ title: String, _ symbol: String, _ body: @escaping (URL) throws -> URL) -> WheelItem {
        WheelItem(title: title, symbol: symbol) { urls in
            try await Task.detached { try urls.map(body) }.value
        }
    }

    private static func eachAsync(_ title: String, _ symbol: String, _ body: @escaping @MainActor (URL) async throws -> URL) -> WheelItem {
        WheelItem(title: title, symbol: symbol) { urls in
            var outputs: [URL] = []
            for url in urls { outputs.append(try await body(url)) }
            return outputs
        }
    }

    /// Runs one job over the whole selection off the main thread.
    private static func all(_ title: String, _ symbol: String, _ body: @escaping ([URL]) throws -> URL) -> WheelItem {
        WheelItem(title: title, symbol: symbol) { urls in
            [try await Task.detached { try body(urls) }.value]
        }
    }
}
