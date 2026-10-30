import AVFoundation
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import SwitchelKit

/// Shared fixtures; each test gets a fresh folder.
class FixtureCase: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Output.folderOverride = nil
        IWork.automationEnabled = false
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A 400×300 PNG with a transparent left half.
    func makePNG(_ name: String = "photo.png") throws -> URL {
        let ctx = try ImageConverter.context(width: 400, height: 300, alpha: true)
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        let url = folder.appendingPathComponent(name)
        try ImageConverter.write(ctx.makeImage()!, to: url, type: .png)
        return url
    }

    /// A noisy 1200×900 JPEG (compresses like a photo) with camera and GPS metadata.
    func makePhoto(_ name: String = "camera.jpg") throws -> URL {
        let noise = CIFilter.randomGenerator().outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let image = CIContext().createCGImage(noise, from: noise.extent)!
        let url = folder.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "One"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func makePDF(_ name: String, pages: Int) throws -> URL {
        let image = try ImageConverter.load(try makePNG("page-\(name).png"))
        let url = folder.appendingPathComponent(name)
        try ImageConverter.writePDF(Array(repeating: image, count: pages), to: url)
        return url
    }

    /// A text PDF with a heading and a two-column table, printed by the text system.
    @MainActor
    func makeTextPDF() throws -> URL {
        let text = NSMutableAttributedString(string: "Quarterly Report\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 28)])
        text.append(NSAttributedString(string: "Region    Sales\nNorth    120\nSouth    95\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let url = folder.appendingPathComponent("report.pdf")
        try DocumentConverter.writePDF(text, to: url)
        return url
    }

    /// One second of a 440 Hz stereo sine, with half a second of silence either side.
    func makeWAV(_ name: String = "tone.wav") throws -> URL {
        let url = folder.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let frames = 88200
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let value: Float = (22050..<66150).contains(i) ? sin(Float(i) * 2 * .pi * 440 / 44100) * 0.5 : 0
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value * 0.5
        }
        try file.write(from: buffer)
        return url
    }

    /// A 2-second 640×360 clip with sound, made by Homebrew's ffmpeg.
    func makeVideo(_ name: String = "clip.mov", size: String = "640x360") async throws -> URL {
        try XCTSkipUnless(FFmpeg.isAvailable, "needs ffmpeg")
        let url = folder.appendingPathComponent(name)
        try await FFmpeg.run(["-f", "lavfi", "-i", "testsrc=size=\(size):rate=30:duration=2", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                              "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path])
        return url
    }

    func pixelSize(_ url: URL) -> (Int, Int) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int)
    }

    func typeOf(_ url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    func duration(_ url: URL) async throws -> Double {
        try await FFmpeg.duration(of: url)
    }

    func expectDuration(_ url: URL, _ expected: Double, accuracy: Double = 0.1, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let seconds = try await duration(url)
        XCTAssertEqual(seconds, expected, accuracy: accuracy, message, file: file, line: line)
    }

    func zipEntries(_ url: URL) async throws -> [String] {
        let listing = try await Shell.run("/usr/bin/zipinfo", ["-1", url.path])
        return String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

// MARK: Files and catalog

final class FileTests: FixtureCase {
    func testOutputNamesNeverOverwrite() throws {
        let source = try makePNG()
        let first = Output.url(for: source, ext: "jpg", suffix: "compressed")
        XCTAssertEqual(first.lastPathComponent, "photo compressed.jpg")
        try Data().write(to: first)
        XCTAssertEqual(Output.url(for: source, ext: "jpg", suffix: "compressed").lastPathComponent, "photo compressed 2.jpg")
        XCTAssertEqual(Output.url(for: source, ext: "png").lastPathComponent, "photo 2.png")
        XCTAssertEqual(Output.url(for: folder.appendingPathComponent("site.tar.gz"), ext: "zip").lastPathComponent, "site.zip")
    }

    func testOutputFolderOverride() throws {
        let source = try makePNG()
        let elsewhere = folder.appendingPathComponent("out", isDirectory: true)
        Output.folderOverride = elsewhere
        defer { Output.folderOverride = nil }
        XCTAssertEqual(Output.url(for: source, ext: "jpg").deletingLastPathComponent().lastPathComponent, "out")
    }

    func testFileKinds() throws {
        let cases: [(String, FileKind)] = [
            ("a.JPEG", .image), ("a.webp", .image), ("a.svg", .image), ("a.mkv", .video), ("a.webm", .video),
            ("a.opus", .audio), ("a.wma", .audio), ("a.pdf", .pdf), ("a.docx", .document), ("a.pages", .document),
            ("a.md", .document), ("a.epub", .document), ("a.xlsx", .spreadsheet), ("a.numbers", .spreadsheet),
            ("a.pptx", .presentation), ("a.key", .presentation), ("a.srt", .subtitle), ("a.rar", .archive),
            ("a.tar.gz", .archive), ("a.xyz", .other),
        ]
        for (name, kind) in cases {
            XCTAssertEqual(FileKind(folder.appendingPathComponent(name)), kind, name)
        }
        XCTAssertEqual(FileKind(folder), .folder)
        XCTAssertEqual(FileKind.common([try makePNG("a.png"), try makeWAV()]), .other)
    }

    func testCatalogCoversEveryKind() throws {
        func titles(_ mode: Mode, _ names: [String]) -> [String] {
            Catalog.items(for: mode, urls: names.map { folder.appendingPathComponent($0) }).map(\.title)
        }
        XCTAssertEqual(titles(.convert, ["a.png"]), ["JPG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "GIF", "PDF"])
        XCTAssertEqual(titles(.convert, ["a.mkv"]), ["MP4", "MOV", "WEBM", "AVI", "WMV", "GIF", "MP3"])
        XCTAssertEqual(titles(.convert, ["a.flac"]), ["MP3", "M4A", "WAV", "OGG", "OPUS", "AIFF", "WMA"])
        XCTAssertEqual(titles(.convert, ["a.pdf"]), ["DOCX", "PAGES", "PPTX", "XLSX", "JPG", "PNG", "EPUB", "TXT", "MD"])
        XCTAssertEqual(titles(.convert, ["a.docx"]), ["PAGES", "MD", "TXT", "EPUB", "HTML", "RTF", "ODT", "PDF"])
        XCTAssertEqual(titles(.convert, ["a.txt"]), ["DOCX", "PAGES", "MD", "EPUB", "HTML", "RTF", "ODT", "PDF"])
        XCTAssertEqual(titles(.convert, ["a.xls"]), ["XLSX", "ODS", "CSV", "TSV", "PDF"])
        XCTAssertEqual(titles(.convert, ["a.pptx"]), ["PDF", "JPG", "PNG"])
        XCTAssertEqual(titles(.convert, ["a.srt"]), ["VTT", "TXT"])
        XCTAssertEqual(titles(.convert, ["a.rar"]), ["ZIP", "TAR", "TAR.GZ"])
        XCTAssertEqual(titles(.convert, ["a.tar.gz"]), ["ZIP", "TAR"])
        XCTAssertEqual(Catalog.items(for: .convert, urls: [folder]).map(\.title), ["ZIP", "TAR", "TAR.GZ"])

        XCTAssertTrue(titles(.tools, ["a.png", "b.png"]).contains("Collage"))
        XCTAssertFalse(titles(.tools, ["a.png"]).contains("Collage"))
        XCTAssertEqual(titles(.tools, ["a.mp4"]), ["Compress", "Crop", "Trim", "Split", "Speed", "GIF", "Redact", "Snapshots", "Mute"])
        XCTAssertEqual(titles(.tools, ["a.png"]), ["Compress", "Crop", "Adjust", "Annotate", "Redact", "Background", "Frame", "Metadata", "QR Code", "Icon", "Rotate", "Make PDF"])
        XCTAssertEqual(titles(.tools, ["a.wav"]), ["Compress", "Trim", "Normalize", "Channels", "Bleep", "Visualize"])
        XCTAssertEqual(titles(.tools, ["a.pdf"]), ["Compress", "Organize", "Split"])
        XCTAssertEqual(titles(.tools, ["a.mp3", "b.mp3"]).first(where: { $0 == "Merge" }), "Merge")
        XCTAssertEqual(titles(.tools, ["a.pdf", "b.pdf"]).first, "Merge")
        XCTAssertEqual(titles(.tools, ["a.zip"]), ["Extract"])
        XCTAssertEqual(titles(.actions, ["a.xyz"]), ["AirDrop", "Float", "Copy", "Move", "Copy Path", "Terminal"])
    }
}

// MARK: Images

final class ImageTests: FixtureCase {
    func testImageConversions() async throws {
        let source = try makePNG()
        for format in ImageFormat.allCases where format != .png {
            if format == .webp && Shell.tool("cwebp") == nil { continue }
            let out = try await ImageConverter.convert(source, to: format)
            XCTAssertEqual(out.pathExtension, format.rawValue)
            if format == .pdf {
                XCTAssertEqual(PDFDocument(url: out)?.pageCount, 1)
            } else {
                XCTAssertEqual(typeOf(out), format.type.identifier, "\(format)")
                XCTAssertEqual(pixelSize(out).0, 400, "\(format)")
            }
        }
    }

    func testCompressByQualityAndTargetSize() async throws {
        let photo = try makePhoto()
        let byQuality = try await ImageTools.compress(photo, .init(target: .quality(0.4), maxDimension: 800))
        XCTAssertEqual(max(pixelSize(byQuality).0, pixelSize(byQuality).1), 800)
        XCTAssertLessThan(size(byQuality), size(photo))

        let limit = 120_000
        let bySize = try await ImageTools.compress(photo, .init(target: .maxBytes(limit), maxDimension: nil, format: .jpg))
        XCTAssertLessThanOrEqual(size(bySize), limit)
        XCTAssertGreaterThan(size(bySize), limit / 4, "should use most of the budget")

        let transparent = try await ImageTools.compress(try makePNG())
        XCTAssertEqual(transparent.pathExtension, "heic")
    }

    func testCropRotate() async throws {
        let source = try makePNG()
        let cropped = try await ImageTools.crop(source, to: CGRect(x: 50, y: 20, width: 100, height: 80))
        XCTAssertEqual(pixelSize(cropped).0, 100)
        XCTAssertEqual(pixelSize(cropped).1, 80)
        let rotated = try await ImageTools.rotateClockwise(source)
        XCTAssertEqual(pixelSize(rotated).0, 300)
        XCTAssertEqual(pixelSize(rotated).1, 400)
    }

    func testAnnotateAndRedactChangePixels() throws {
        let image = try ImageConverter.load(try makePNG())
        let marks = [
            ImageTools.Mark(shape: .rectangle(CGRect(x: 250, y: 50, width: 100, height: 100)), color: .blue, lineWidth: 8),
            ImageTools.Mark(shape: .arrow(CGPoint(x: 10, y: 10), CGPoint(x: 150, y: 150)), color: .red, lineWidth: 6),
            ImageTools.Mark(shape: .text("Hi", CGPoint(x: 220, y: 200)), color: .black, lineWidth: 5),
        ]
        let annotated = try ImageTools.annotate(image, with: marks)
        XCTAssertNotEqual(pixel(annotated, 250, 100), pixel(image, 250, 100))

        for style in ImageTools.RedactionStyle.allCases {
            let redacted = try ImageTools.redact(image, regions: [CGRect(x: 180, y: 0, width: 40, height: 300)], style: style)
            XCTAssertEqual(redacted.width, image.width)
            if style == .black { XCTAssertEqual(pixel(redacted, 200, 150).prefix(3), [0, 0, 0]) }
        }
    }

    /// RGBA at (x, y) with a top-left origin.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let ctx = try! ImageConverter.context(width: image.width, height: image.height, alpha: true)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * ctx.bytesPerRow) + x * 4
        return (0..<4).map { data[offset + $0] }
    }

    func testFrameCollageIcon() throws {
        let image = try ImageConverter.load(try makePNG())
        var options = ImageTools.FrameOptions()
        options.ratio = .square
        let framed = try ImageTools.frame(image, options)
        XCTAssertEqual(framed.width, framed.height)
        XCTAssertGreaterThan(framed.width, 400)

        let collage = try ImageTools.collage([image, image, image], .init())
        XCTAssertEqual(collage.width, 2400)

        let icon = try ImageTools.icon(image, .init())
        let icns = folder.appendingPathComponent("icon.icns")
        try ImageTools.writeICNS(icon, to: icns)
        XCTAssertGreaterThanOrEqual(CGImageSourceGetCount(CGImageSourceCreateWithURL(icns as CFURL, nil)!), 5)
    }

    func testMetadataEditingIsLossless() async throws {
        let photo = try makePhoto()
        XCTAssertTrue(ImageTools.metadata(of: photo).contains { $0.group == "GPS" })

        let noLocation = try await ImageTools.editMetadata(photo, .init(artist: "Ada", removeLocation: true))
        let entries = ImageTools.metadata(of: noLocation)
        XCTAssertFalse(entries.contains { $0.group == "GPS" })
        XCTAssertEqual(entries.first { $0.key == "Artist" }?.value, "Ada")
        XCTAssertEqual(entries.first { $0.key == "Make" }?.value, "TestCam")

        let clean = try await ImageTools.editMetadata(photo, .init(removeAll: true))
        let remaining = ImageTools.metadata(of: clean)
        XCTAssertFalse(remaining.contains { $0.group == "GPS" || $0.key == "Make" })
        // Same pixels: copying the image source doesn't re-encode.
        XCTAssertEqual(abs(size(clean) - size(photo)) < size(photo) / 50, true)
    }

    func testReadsQRCodes() throws {
        let qr = CIFilter.qrCodeGenerator()
        qr.message = Data("https://example.com/switchel".utf8)
        let code = qr.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let padded = code.composited(over: CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -60, dy: -60)))
        let url = folder.appendingPathComponent("qr.png")
        try ImageConverter.write(CIContext().createCGImage(padded, from: padded.extent)!, to: url, type: .png)
        XCTAssertEqual(try ImageTools.readCodes(url), ["https://example.com/switchel"])
    }
}

// MARK: PDF

final class PDFTests: FixtureCase {
    @MainActor
    func testPDFToImages() async throws {
        let single = try makePDF("one.pdf", pages: 1)
        let png = try await PDFConverter.convert(single, to: .png)
        XCTAssertEqual(pixelSize(png).0, 400 * 300 / 72)

        let triple = try makePDF("three.pdf", pages: 3)
        let pages = try await PDFConverter.convert(triple, to: .jpg)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pages.path).count, 3)
    }

    @MainActor
    func testPDFToDocuments() async throws {
        let pdf = try makeTextPDF()
        let md = try String(contentsOf: try await PDFConverter.convert(pdf, to: .md))
        XCTAssertTrue(md.contains("# Quarterly Report"), md)

        let docx = try await PDFConverter.convert(pdf, to: .docx)
        XCTAssertTrue(try NSAttributedString(url: docx, options: [:], documentAttributes: nil).string.contains("North"))

        let epub = try await PDFConverter.convert(pdf, to: .epub)
        let epubText = try await DocumentConverter.read(epub).string
        XCTAssertTrue(epubText.contains("Quarterly Report"))

        let xlsx = try await PDFConverter.convert(pdf, to: .xlsx)
        let table = try await Packages.readXLSX(xlsx)
        XCTAssertTrue(table.contains(["North", "120"]), "\(table)")

        let txt = try String(contentsOf: try await PDFConverter.convert(pdf, to: .txt))
        XCTAssertTrue(txt.contains("South"))
    }

    @MainActor
    func testPDFToPowerPoint() async throws {
        let pptx = try await PDFConverter.convert(try makePDF("deck.pdf", pages: 2), to: .pptx, layout: .exact)
        let entries = try await zipEntries(pptx)
        for part in ["[Content_Types].xml", "ppt/presentation.xml", "ppt/slides/slide1.xml", "ppt/slides/slide2.xml",
                     "ppt/media/image2.jpeg", "ppt/theme/theme1.xml", "ppt/slideMasters/slideMaster1.xml"] {
            XCTAssertTrue(entries.contains(part), part)
        }
        // Every XML part must be well-formed.
        let scratch = try Output.temporaryFolder()
        try await Zip.extract(pptx, to: scratch)
        for entry in entries where entry.hasSuffix(".xml") || entry.hasSuffix(".rels") {
            XCTAssertNoThrow(try XMLDocument(contentsOf: scratch.appendingPathComponent(entry)), entry)
        }
    }

    func testMergeSplitRearrangeCompress() throws {
        let triple = try makePDF("three.pdf", pages: 3)
        let single = try makePDF("one.pdf", pages: 1)
        let merged = try PDFTools.merge([triple, single])
        XCTAssertEqual(merged.lastPathComponent, "one merged.pdf")
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, 4)

        let everyPage = try PDFTools.split(merged, .everyPage)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: everyPage.path).count, 4)
        let ranges = try PDFTools.split(merged, .ranges("1-3, 4"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ranges.path).sorted(), ["one merged p1-3.pdf", "one merged p4.pdf"])
        XCTAssertThrowsError(try PDFTools.parseRanges("2-9", pageCount: 4))

        let edited = try PDFTools.rearrange(triple, pages: [.init(source: triple, index: 2, rotation: 90), .init(source: single, index: 0), .init(source: triple, index: 0)])
        let doc = PDFDocument(url: edited)!
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertEqual(doc.page(at: 0)?.rotation, 90)
        XCTAssertEqual(edited.lastPathComponent, "three edited.pdf")

        XCTAssertNotNil(PDFDocument(url: try PDFTools.compress(triple)))
    }
}

// MARK: Documents, spreadsheets, subtitles, archives

final class DocumentTests: FixtureCase {
    @MainActor
    func testDocumentFormats() async throws {
        let source = folder.appendingPathComponent("notes.rtf")
        let text = NSMutableAttributedString(string: "Big Title\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 26)])
        text.append(NSAttributedString(string: "Hello Switchel, with ", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        text.append(NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
        text.append(NSAttributedString(string: " words.\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: source)

        for format in DocumentFormat.allCases where ![.rtf, .pages].contains(format) {
            let out = try await DocumentConverter.convert(source, to: format)
            XCTAssertEqual(out.pathExtension, format.rawValue)
            let back = format == .pdf ? PDFDocument(url: out)?.string ?? "" : try await DocumentConverter.read(out).string
            XCTAssertTrue(back.contains("Hello Switchel"), "\(format): \(back)")
        }
        let md = try String(contentsOf: folder.appendingPathComponent("notes.md"))
        XCTAssertTrue(md.hasPrefix("# Big Title"), md)
        XCTAssertTrue(md.contains("**bold**"), md)
    }

    func testMarkdown() {
        let html = Markdown.html("# Title\n\nSome *em* and **strong** and `code` and [a link](https://x.y).\n\n- one\n- two\n\n1. first\n\n```\nlet x = 1 < 2\n```")
        for fragment in ["<h1>Title</h1>", "<em>em</em>", "<strong>strong</strong>", "<code>code</code>",
                         "<a href=\"https://x.y\">a link</a>", "<ul>\n<li>one</li>\n<li>two</li>\n</ul>", "<ol>", "let x = 1 &lt; 2"] {
            XCTAssertTrue(html.contains(fragment), fragment)
        }
    }

    @MainActor
    func testMarkdownSource() async throws {
        let source = folder.appendingPathComponent("readme.md")
        try "# Hello\n\nA **bold** move.\n".write(to: source, atomically: true, encoding: .utf8)
        let docx = try await DocumentConverter.convert(source, to: .docx)
        let text = try NSAttributedString(url: docx, options: [:], documentAttributes: nil)
        XCTAssertTrue(text.string.contains("A bold move."))
    }

    @MainActor
    func testTextClipping() async throws {
        let url = folder.appendingPathComponent("snippet.textClipping")
        let plist: [String: Any] = ["UTI-Data": ["public.utf8-plain-text": Data("Clipped words".utf8)]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
        let clipped = try await DocumentConverter.read(url).string
        XCTAssertEqual(clipped, "Clipped words")
    }

    @MainActor
    func testSpreadsheets() async throws {
        let csv = folder.appendingPathComponent("data.csv")
        try "name,qty,note\n\"Smith, J\",7,\"said \"\"hi\"\"\"\nZip,007,\"two\nlines\"\n".write(to: csv, atomically: true, encoding: .utf8)
        let expected: Table = [["name", "qty", "note"], ["Smith, J", "7", "said \"hi\""], ["Zip", "007", "two\nlines"]]
        let parsed = try await SpreadsheetConverter.read(csv)
        XCTAssertEqual(parsed, expected)

        for format in SpreadsheetFormat.allCases where format != .csv {
            let out = try await SpreadsheetConverter.convert(csv, to: format)
            if format == .pdf {
                XCTAssertTrue(PDFDocument(url: out)?.string?.contains("Smith, J") ?? false)
            } else {
                let roundTripped = try await SpreadsheetConverter.read(out)
                XCTAssertEqual(roundTripped, expected, "\(format)")
            }
        }
    }

    func testSubtitles() throws {
        let srt = folder.appendingPathComponent("movie.srt")
        try "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:01:02,250 --> 00:01:04,000\nTwo\nlines\n".write(to: srt, atomically: true, encoding: .utf8)
        let vtt = try SubtitleConverter.convert(srt, to: .vtt)
        let vttText = try String(contentsOf: vtt)
        XCTAssertTrue(vttText.hasPrefix("WEBVTT"))
        XCTAssertTrue(vttText.contains("00:01:02.250 --> 00:01:04.000"))
        XCTAssertEqual(SubtitleConverter.parse(vttText), SubtitleConverter.parse(try String(contentsOf: srt)))
        XCTAssertEqual(SubtitleConverter.seconds("01:02.5"), 62.5)
        XCTAssertEqual(try String(contentsOf: try SubtitleConverter.convert(srt, to: .txt)), "Hello\nTwo\nlines\n")
    }

    func testArchives() async throws {
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "hello".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let zip = try await ArchiveConverter.convert(project, to: .zip)
        let entries = try await zipEntries(zip)
        XCTAssertTrue(entries.contains("project/a.txt"))
        let gz = try await ArchiveConverter.convert(project, to: .gz)
        XCTAssertEqual(gz.lastPathComponent, "project.tar.gz")
        let tar = try await ArchiveConverter.convert(zip, to: .tar)
        XCTAssertEqual(tar.lastPathComponent, "project.tar")

        let extracted = try await ArchiveConverter.extract(gz)
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("project/a.txt")), "hello")
    }
}

// MARK: Audio and video

final class MediaTests: FixtureCase {
    func testAudioConversions() async throws {
        try XCTSkipUnless(FFmpeg.isAvailable, "needs ffmpeg")
        let source = try makeWAV()
        for format in AudioFormat.allCases where format != .wav {
            let out = try await MediaConverter.convert(source, to: format)
            let seconds = try await duration(out)
            XCTAssertEqual(seconds, 2, accuracy: 0.15, "\(format)")
        }
    }

    func testAudioTools() async throws {
        try XCTSkipUnless(FFmpeg.isAvailable, "needs ffmpeg")
        let source = try makeWAV()
        try await expectDuration(AudioTools.trim(source, 0.5...1.0), 0.5, accuracy: 0.05)
        try await expectDuration(AudioTools.trimSilence(source), 1)
        try await expectDuration(AudioTools.normalize(source), 2)
        let mono = try await AudioTools.changeChannels(source, mode: .mono)
        XCTAssertEqual(try AVAudioFile(forReading: mono).fileFormat.channelCount, 1)
        let swapped = try await AudioTools.changeChannels(source, mode: .swap)
        XCTAssertEqual(try AVAudioFile(forReading: swapped).fileFormat.channelCount, 2)
        try await expectDuration(AudioTools.bleep(source, ranges: [0.6...0.9], beep: true), 2)
        try await expectDuration(AudioTools.merge([source, source]), 4)
        let compressed = try await AudioTools.compress(source, kbps: 64, mono: true)
        XCTAssertEqual(compressed.pathExtension, "m4a")
        XCTAssertLessThan(size(compressed), size(source))

        var visual = AudioTools.Visualization()
        visual.width = 320
        visual.height = 180
        for style in AudioTools.Visualization.Style.allCases {
            visual.style = style
            let video = try await AudioTools.visualize(source, visual)
            try await expectDuration(video, 2, accuracy: 0.2, "\(style)")
        }
    }

    func testVideoConversions() async throws {
        let source = try await makeVideo()
        for format in VideoFormat.allCases where format != .mov {
            let out = try await MediaConverter.convert(source, to: format)
            try await expectDuration(out, 2, accuracy: 0.25, "\(format)")
        }
    }

    func testVideoTools() async throws {
        let source = try await makeVideo()
        let target = try await VideoTools.compress(source, .init(targetMegabytes: 0.2, maxHeight: 240))
        let compressedSize = try await VideoTools.dimensions(of: target)
        XCTAssertEqual(compressedSize.h, 240)

        try await expectDuration(VideoTools.trim(source, 0.5...1.5), 1)
        let parts = try await VideoTools.split(source, at: [0.8])
        XCTAssertEqual(parts.map(\.lastPathComponent), ["clip part 1.mov", "clip part 2.mov"])
        try await expectDuration(VideoTools.changeSpeed(source, by: 2), 1)
        try await expectDuration(VideoTools.changeSpeed(source, by: 0.25), 8, accuracy: 0.3)

        for style in ImageTools.RedactionStyle.allCases {
            let region = VideoTools.Redaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), start: 0.5, end: 1.5)
            try await expectDuration(VideoTools.redact(source, [region, region], style: style), 2, accuracy: 0.2, "\(style)")
        }

        let shots = try await VideoTools.snapshots(source, at: [0.5, 1.5], as: .jpg)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shots[0].path).count, 2)
        let shot = try await VideoTools.snapshots(source, at: [1], as: .png)
        XCTAssertEqual(pixelSize(shot[0]).0, 640)

        let other = try await makeVideo("other.mov", size: "320x240")
        try await expectDuration(VideoTools.merge([source, other]), 4, accuracy: 0.3)
        let muted = try await VideoTools.removeAudio(source)
        let mutedHasAudio = await FFmpeg.hasAudio(muted)
        XCTAssertFalse(mutedHasAudio)
    }
}

// MARK: Tangerine parity additions

final class ParityTests: FixtureCase {
    func testAdjustAndTiltedFrame() throws {
        let image = try ImageConverter.load(try makePhoto())
        var adjustments = ImageTools.Adjustments()
        XCTAssertTrue(adjustments.isIdentity)
        adjustments.exposure = 1
        adjustments.warmth = 0.5
        adjustments.sharpness = 0.5
        let brighter = try ImageTools.adjust(image, adjustments)
        XCTAssertEqual(brighter.width, image.width)
        XCTAssertGreaterThan(averageLuma(brighter), averageLuma(image))

        var frame = ImageTools.FrameOptions()
        frame.padding = 0
        frame.rotation = 90
        let tilted = try ImageTools.frame(image, frame)
        XCTAssertEqual(tilted.width, image.height, accuracy: 1)
        XCTAssertEqual(tilted.height, image.width, accuracy: 1)
    }

    private func averageLuma(_ image: CGImage) -> Double {
        let ctx = try! ImageConverter.context(width: 32, height: 32, alpha: false)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(32 * 32)).reduce(0.0) { $0 + Double(data[$1 * 4]) + Double(data[$1 * 4 + 1]) + Double(data[$1 * 4 + 2]) } / Double(32 * 32 * 3)
    }

    @MainActor
    func testPDFExactAndEditableOffice() async throws {
        let pdf = try makeTextPDF()
        let exact = try await PDFConverter.convert(pdf, to: .docx, layout: .exact)
        let entries = try await zipEntries(exact)
        XCTAssertTrue(entries.contains("word/media/page1.jpeg"))
        let scratch = try Output.temporaryFolder()
        try await Zip.extract(exact, to: scratch)
        XCTAssertNoThrow(try XMLDocument(contentsOf: scratch.appendingPathComponent("word/document.xml")))

        let editable = try await PDFConverter.convert(pdf, to: .pptx, layout: .editable)
        let slides = try await zipEntries(editable)
        XCTAssertFalse(slides.contains { $0.hasPrefix("ppt/media/") }, "editable slides are text, not pictures")
        let slideFolder = try Output.temporaryFolder()
        try await Zip.extract(editable, to: slideFolder)
        let slide = try String(contentsOf: slideFolder.appendingPathComponent("ppt/slides/slide1.xml"))
        XCTAssertNoThrow(try XMLDocument(xmlString: slide))
        XCTAssertTrue(slide.contains("Quarterly Report"))
        XCTAssertTrue(slide.contains("sz=\"3200\""), "the heading is set large")
    }

    func testVideoCropKeepGIF() async throws {
        let source = try await makeVideo()
        let cropped = try await VideoTools.crop(source, to: CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5))
        let size = try await VideoTools.dimensions(of: cropped)
        XCTAssertEqual(size.w, 320)
        XCTAssertEqual(size.h, 180)

        try await expectDuration(VideoTools.keep(source, [0...0.5, 1.2...2]), 1.3, accuracy: 0.15)

        let gif = try await VideoTools.makeGIF(source, .init(fps: 10, width: 200, range: 0.5...1.5))
        let frames = CGImageSourceGetCount(CGImageSourceCreateWithURL(gif as CFURL, nil)!)
        XCTAssertEqual(frames, 10, accuracy: 1)
        XCTAssertEqual(pixelSize(gif).0, 200)
    }

    func testNormalizeTarget() async throws {
        try XCTSkipUnless(FFmpeg.isAvailable, "needs ffmpeg")
        let quiet = try await AudioTools.normalize(try makeWAV(), target: -30)
        let loud = try await AudioTools.normalize(try makeWAV("tone2.wav"), target: -12)
        XCTAssertLessThan(try peak(quiet), try peak(loud))
    }

    private func peak(_ url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (0..<Int(buffer.frameLength)).reduce(0) { max($0, abs(buffer.floatChannelData![0][$1])) }
    }
}

// MARK: Text and document tools

final class TextToolTests: FixtureCase {
    func testNoToolsWheelIsEmpty() {
        for name in ["a.txt", "a.md", "a.docx", "a.rtf", "a.pages", "a.xlsx", "a.csv", "a.pptx", "a.srt", "a.xyz", "a.png", "a.mp4", "a.mp3", "a.pdf", "a.zip"] {
            XCTAssertFalse(Catalog.items(for: .tools, urls: [folder.appendingPathComponent(name)]).isEmpty, name)
        }
        XCTAssertFalse(Catalog.items(for: .tools, urls: [folder]).isEmpty)
        let text = Catalog.items(for: .tools, urls: [folder.appendingPathComponent("a.txt")]).map(\.title)
        XCTAssertEqual(text, ["Word Count", "Find & Replace", "Change Case", "Clean Up", "Make PDF", "ZIP"])
        let docx = Catalog.items(for: .tools, urls: ["a.docx", "b.docx"].map { folder.appendingPathComponent($0) }).map(\.title)
        XCTAssertEqual(docx, ["Word Count", "Find & Replace", "Change Case", "Merge", "Make PDF", "ZIP"])
    }

    @MainActor
    func testStatsCaseReplaceCleanMerge() async throws {
        let note = folder.appendingPathComponent("note.txt")
        try "Hello world.  \nthis is a test.\n\n\n\nhello world.  \n".write(to: note, atomically: true, encoding: .utf8)

        let stats = try await TextTools.stats(of: note)
        XCTAssertEqual(stats.words, 8)
        XCTAssertEqual(stats.paragraphs, 3)

        let sentence = try String(contentsOf: try await TextTools.changeCase(note, to: .sentence))
        XCTAssertTrue(sentence.hasPrefix("Hello world.  \nThis is a test."), sentence)
        let upper = try await TextTools.changeCase(note, to: .upper)
        XCTAssertTrue(try String(contentsOf: upper).hasPrefix("HELLO WORLD"))

        var replacement = TextTools.Replacement(find: "hello", replace: "Goodbye")
        XCTAssertEqual(TextTools.matches(in: try String(contentsOf: note), replacement), 2)
        replacement.caseSensitive = true
        let replaced = try String(contentsOf: try await TextTools.findAndReplace(note, replacement))
        XCTAssertTrue(replaced.contains("Hello world.") && replaced.contains("Goodbye world."))
        replacement.find = "nothing here"
        do { _ = try await TextTools.findAndReplace(note, replacement); XCTFail("should report no match") } catch {}

        let regex = TextTools.Replacement(find: #"w(or)ld"#, replace: "W$1LD", regularExpression: true)
        let regexed = try await TextTools.findAndReplace(note, regex)
        XCTAssertTrue(try String(contentsOf: regexed).contains("WorLD"))

        let clean = try String(contentsOf: try await TextTools.cleanUp(note, .init(removeDuplicateLines: false)))
        XCTAssertEqual(clean, "Hello world.\nthis is a test.\n\nhello world.\n")
        XCTAssertEqual(TextTools.clean("b\na\nb\n", .init(removeDuplicateLines: true, sortLines: true)), "a\nb")

        let other = folder.appendingPathComponent("another.txt")
        try "Second file".write(to: other, atomically: true, encoding: .utf8)
        let merged = try await TextTools.merge([note, other])
        XCTAssertEqual(merged.lastPathComponent, "another merged.txt")
        XCTAssertTrue(try String(contentsOf: merged).hasPrefix("Second file\n\nHello world."))
    }

    @MainActor
    func testRichDocumentsKeepFormatting() async throws {
        let source = folder.appendingPathComponent("memo.rtf")
        let text = NSMutableAttributedString(string: "Draft ", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        text.append(NSAttributedString(string: "Important", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: source)

        let upper = try await TextTools.changeCase(source, to: .upper)
        XCTAssertEqual(upper.pathExtension, "rtf")
        let back = try NSAttributedString(url: upper, options: [:], documentAttributes: nil)
        XCTAssertEqual(back.string, "DRAFT IMPORTANT")
        let font = back.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false, "bold run stays bold")

        let merged = try await TextTools.merge([source, upper])
        XCTAssertEqual(merged.pathExtension, "docx")
    }

    @MainActor
    func testSubtitlesSpreadsheetsZip() async throws {
        let srt = folder.appendingPathComponent("film.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nHi\n".write(to: srt, atomically: true, encoding: .utf8)
        let shifted = SubtitleConverter.parse(try String(contentsOf: try SubtitleTools.shift(srt, by: -1.5)))
        XCTAssertEqual(shifted.first?.start, 0)
        XCTAssertEqual(shifted.first?.end, 0.5)

        let a = folder.appendingPathComponent("a.csv"), b = folder.appendingPathComponent("b.csv")
        try "name,qty\nx,1\n".write(to: a, atomically: true, encoding: .utf8)
        try "name,qty\ny,2\n".write(to: b, atomically: true, encoding: .utf8)
        let merged = try await SpreadsheetConverter.merge([b, a])
        let table = try await Packages.readXLSX(merged)
        XCTAssertEqual(table, [["name", "qty"], ["x", "1"], ["y", "2"]])

        let zip = try await ArchiveConverter.zip([a, b])
        let entries = try await zipEntries(zip)
        XCTAssertEqual(Set(entries), ["a.csv", "b.csv"])
    }
}

// MARK: PDF formatting

final class PDFFormattingTests: FixtureCase {
    /// A one-page report: a coloured heading, a paragraph with bold, red and a link, a picture,
    /// and a ruled table with a shaded header row, right-aligned numbers and a wrapped cell.
    static func makeReport(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("report.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPage(mediaBox: &box)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let blue = NSColor(srgbRed: 0.1, green: 0.3, blue: 0.7, alpha: 1), red = NSColor(srgbRed: 0.8, green: 0, blue: 0, alpha: 1)
        func font(_ size: CGFloat, bold: Bool = false) -> NSFont { NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)! }
        func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 11, bold: Bool = false, color: NSColor = .black, right: Bool = false) {
            let string = NSAttributedString(string: text, attributes: [.font: font(size, bold: bold), .foregroundColor: color])
            string.draw(at: NSPoint(x: right ? x - string.size().width : x, y: y))
        }
        draw("Quarterly Sales", x: 72, y: 700, size: 24, bold: true, color: blue)
        let sentence = NSMutableAttributedString(string: "Revenue grew ", attributes: [.font: font(11)])
        sentence.append(NSAttributedString(string: "strongly", attributes: [.font: font(11, bold: true)]))
        sentence.append(NSAttributedString(string: " but costs were ", attributes: [.font: font(11)]))
        sentence.append(NSAttributedString(string: "higher", attributes: [.font: font(11), .foregroundColor: red]))
        sentence.append(NSAttributedString(string: ". See the website.", attributes: [.font: font(11)]))
        sentence.draw(at: NSPoint(x: 72, y: 670))
        // "website" underlined, as links usually are.
        ctx.setFillColor(NSColor.black.cgColor)
        let linkStart = 72 + sentence.attributedSubstring(from: NSRange(location: 0, length: (sentence.string as NSString).range(of: "website").location)).size().width
        let linkWidth = NSAttributedString(string: "website", attributes: [.font: font(11)]).size().width
        ctx.fill(CGRect(x: linkStart, y: 671.5, width: linkWidth, height: 0.8))

        // A picture.
        let swatch = try! ImageConverter.context(width: 120, height: 80, alpha: false)
        swatch.setFillColor(NSColor.orange.cgColor)
        swatch.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        ctx.draw(swatch.makeImage()!, in: CGRect(x: 72, y: 560, width: 120, height: 80))

        // The table: shaded header, ruled grid.
        ctx.setFillColor(NSColor(srgbRed: 0.87, green: 0.87, blue: 0.87, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 66, y: 514, width: 424, height: 18))
        ctx.setStrokeColor(NSColor.gray.cgColor)
        ctx.setLineWidth(0.5)
        for y: CGFloat in [532, 514, 496, 466, 448] { ctx.stroke(CGRect(x: 66, y: y, width: 424, height: 0)) }
        for x: CGFloat in [66, 194, 400, 490] { ctx.stroke(CGRect(x: x, y: 448, width: 0, height: 84)) }
        draw("Region", x: 72, y: 518, bold: true); draw("Product", x: 200, y: 518, bold: true); draw("Revenue", x: 484, y: 518, bold: true, right: true)
        draw("North", x: 72, y: 500); draw("Widgets", x: 200, y: 500); draw("1,200", x: 484, y: 500, right: true)
        draw("South", x: 72, y: 482); draw("Gadgets and", x: 200, y: 482); draw("95", x: 484, y: 482, right: true)
        draw("accessories", x: 200, y: 469)
        draw("East", x: 72, y: 452); draw("Gizmos", x: 200, y: 452); draw("12,450", x: 484, y: 452, right: true)
        draw("Totals are unaudited.", x: 72, y: 410)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPage()
        ctx.closePDF()

        let doc = PDFDocument(url: url)!
        let link = PDFAnnotation(bounds: CGRect(x: linkStart, y: 668, width: linkWidth, height: 14), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        doc.page(at: 0)!.addAnnotation(link)
        doc.write(to: url)
        return url
    }

    func testRebuildsFormatting() throws {
        let layout = PDFLayout.document(PDFDocument(url: try Self.makeReport(in: folder))!)
        let paragraphs = layout.blocks.compactMap { block -> PDFLayout.Paragraph? in if case .paragraph(let p) = block { return p } else { return nil } }

        let title = try XCTUnwrap(paragraphs.first)
        XCTAssertEqual(title.text, "Quarterly Sales")
        XCTAssertEqual(title.heading, 1)
        XCTAssertEqual(title.runs[0].style.font, "Helvetica")
        XCTAssertEqual(title.runs[0].style.size, 24)
        XCTAssertTrue(title.runs[0].style.bold)
        XCTAssertEqual(title.runs[0].style.color, "1A4DB3")

        let sentence = try XCTUnwrap(paragraphs.first { $0.text.hasPrefix("Revenue grew") })
        XCTAssertEqual(sentence.text, "Revenue grew strongly but costs were higher. See the website.")
        func style(of word: String) -> PDFLayout.Style? { sentence.runs.first { $0.text.contains(word) }?.style }
        XCTAssertEqual(style(of: "strongly")?.bold, true)
        XCTAssertEqual(style(of: "grew")?.bold, false)
        XCTAssertEqual(style(of: "higher")?.color, "CC0000")
        XCTAssertEqual(style(of: "website")?.underline, true)
        XCTAssertEqual(style(of: "website")?.link, URL(string: "https://example.com"))

        XCTAssertTrue(layout.blocks.contains { if case .picture(let p) = $0 { return abs(p.size.width - 120) < 1 } else { return false } })

        guard case .table(let table) = try XCTUnwrap(layout.blocks.first { if case .table = $0 { return true } else { return false } }) else { return }
        XCTAssertEqual(table.text, [
            ["Region", "Product", "Revenue"],
            ["North", "Widgets", "1,200"],
            ["South", "Gadgets and accessories", "95"],
            ["East", "Gizmos", "12,450"],
        ])
        XCTAssertTrue(table.header)
        XCTAssertTrue(table.borders)
        XCTAssertEqual(table.shading[0], ["DEDEDE", "DEDEDE", "DEDEDE"])
        XCTAssertEqual(table.shading[1], [nil, nil, nil])
        XCTAssertEqual(table.alignments, [.left, .left, .right])
        XCTAssertTrue(table.rows[0][0][0].style.bold)

        XCTAssertEqual(layout.margins.left, 72, accuracy: 1)
        XCTAssertEqual(layout.pageSize, CGSize(width: 612, height: 792))
    }

    @MainActor
    func testWordKeepsFormatting() async throws {
        let docx = try await PDFConverter.convert(try Self.makeReport(in: folder), to: .docx, layout: .editable)
        let scratch = try Output.temporaryFolder()
        try await Zip.extract(docx, to: scratch)
        let xml = try String(contentsOf: scratch.appendingPathComponent("word/document.xml"))
        let document = try XMLDocument(xmlString: xml)
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='tbl']").count, 1)
        XCTAssertEqual(try document.nodes(forXPath: "(//*[local-name()='tr'])[3]/*[local-name()='tc']").map { $0.stringValue ?? "" },
                       ["South", "Gadgets and accessories", "95"])
        for fragment in ["w:ascii=\"Helvetica\"", "<w:color w:val=\"1A4DB3\"/>", "<w:color w:val=\"CC0000\"/>", "<w:sz w:val=\"48\"/>",
                         "<w:u w:val=\"single\"/>", "<w:hyperlink", "<w:drawing>", "w:fill=\"DEDEDE\"", "<w:jc w:val=\"right\"/>",
                         "w:val=\"single\" w:sz=\"4\"", "<w:pgSz w:w=\"12240\" w:h=\"15840\"/>"] {
            XCTAssertTrue(xml.contains(fragment), fragment)
        }
        let rels = try String(contentsOf: scratch.appendingPathComponent("word/_rels/document.xml.rels"))
        XCTAssertTrue(rels.contains("https://example.com") && rels.contains("TargetMode=\"External\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("word/media/picture1.jpeg").path))
        // macOS's own Word reader opens it.
        let text = try NSAttributedString(url: docx, options: [:], documentAttributes: nil).string
        XCTAssertTrue(text.contains("Gadgets and accessories") && text.contains("Revenue grew strongly"))

        let md = try String(contentsOf: try await PDFConverter.convert(try Self.makeReport(in: folder), to: .md))
        XCTAssertTrue(md.hasPrefix("# Quarterly Sales"))
        XCTAssertTrue(md.contains("**strongly**") && md.contains("[website](https://example.com)"), md)
        XCTAssertTrue(md.contains("| **Region** | **Product** | **Revenue** |\n| --- | --- | ---: |\n| North | Widgets | 1,200 |"), md)
    }
}

// MARK: Spreadsheet fidelity

final class SpreadsheetFidelityTests: FixtureCase {
    /// CSV → Excel → CSV must give back exactly what went in.
    @MainActor
    func testCSVSurvivesExcelExactly() async throws {
        let csv = folder.appendingPathComponent("tricky.csv")
        let original = #"""
        id,zip,amount,ratio,card,phone,code,date,formula,note
        1,00501,12.50,0.125,4111111111111111111,+44 20 7946 0958,1e5,3/4/2024,=SUM(A1:A2),"Hello, ""world"""
        2,10001,-7,3.0,123456789012345,555-0100,0x1F,2024-03-04T10:00,=1+1,"line one
        line two"

        """#
        try original.write(to: csv, atomically: true, encoding: .utf8)
        let xlsx = try await SpreadsheetConverter.convert(csv, to: .xlsx)
        let back = try String(contentsOf: try await SpreadsheetConverter.convert(xlsx, to: .csv))
        XCTAssertEqual(back, original)

        // Plain numbers are real numbers (so formulas work on them), keeping their decimals.
        let scratch = try Output.temporaryFolder()
        try await Zip.extract(xlsx, to: scratch)
        let sheet = try String(contentsOf: scratch.appendingPathComponent("xl/worksheets/sheet1.xml"))
        XCTAssertTrue(sheet.contains("<c r=\"C2\" s=\"1\"><v>12.50</v></c>"), sheet)
        XCTAssertTrue(sheet.contains("<c r=\"B2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">00501</t></is></c>"))
        XCTAssertTrue(sheet.contains("<cols>"))
        let styles = try String(contentsOf: scratch.appendingPathComponent("xl/styles.xml"))
        XCTAssertTrue(styles.contains("formatCode=\"0.00\""))
    }

    func testExcelDisplayFormats() {
        let cases: [(String, String, String)] = [
            ("45306", "m/d/yyyy", "1/15/2024"),
            ("45306", "yyyy-mm-dd", "2024-01-15"),
            ("45306", "d-mmm-yy", "15-Jan-24"),
            ("45306.75", "m/d/yyyy h:mm", "1/15/2024 18:00"),
            ("0.75", "h:mm AM/PM", "6:00 PM"),
            ("0.1234", "0.00%", "12.34%"),
            ("1234.5", "\"$\"#,##0.00", "$1,234.50"),
            ("-1234.5", "#,##0.00;(#,##0.00)", "(1,234.50)"),
            ("1234567", "#,##0", "1,234,567"),
            ("3.14159", "0.000", "3.142"),
            ("42", "General", "42"),
            ("0.1", "General", "0.1"),
            ("12345.678", "0.00E+00", "1.23E+04"),
        ]
        for (raw, code, expected) in cases {
            XCTAssertEqual(ExcelFormat.display(raw, format: code), expected, "\(raw) as \(code)")
        }
    }

    @MainActor
    func testPDFToExcelKeepsTableFormatting() async throws {
        let xlsx = try await PDFConverter.convert(try PDFFormattingTests.makeReport(in: folder), to: .xlsx)
        let table = try await Packages.readXLSX(xlsx)
        XCTAssertTrue(table.contains(["Region", "Product", "Revenue"]))
        XCTAssertTrue(table.contains(["South", "Gadgets and accessories", "95"]))
        XCTAssertEqual(table.first, ["Quarterly Sales"])

        let scratch = try Output.temporaryFolder()
        try await Zip.extract(xlsx, to: scratch)
        let styles = try String(contentsOf: scratch.appendingPathComponent("xl/styles.xml"))
        for fragment in ["<b/>", "rgb=\"FF1A4DB3\"", "rgb=\"FFDEDEDE\"", "horizontal=\"right\"", "style=\"thin\"", "<name val=\"Helvetica\"/>"] {
            XCTAssertTrue(styles.contains(fragment), fragment)
        }
    }
}

// MARK: Word compatibility

/// Word refuses (or "repairs" into a locked copy) any document whose property elements are out of the
/// order the Office Open XML schema sets. macOS's readers don't care, so this checks it directly.
final class WordSchemaOrderTests: FixtureCase {
    static let order: [String: [String]] = [
        "pPr": ["pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr", "widowControl", "numPr", "pBdr", "shd", "tabs",
                "suppressAutoHyphens", "bidi", "spacing", "ind", "contextualSpacing", "jc", "textDirection", "textAlignment", "outlineLvl", "rPr"],
        "rPr": ["rStyle", "rFonts", "b", "bCs", "i", "iCs", "caps", "smallCaps", "strike", "dstrike", "vanish", "color", "spacing", "w",
                "kern", "position", "sz", "szCs", "highlight", "u", "effect", "bdr", "shd", "vertAlign", "lang"],
        "tblPr": ["tblStyle", "tblpPr", "tblOverlap", "bidiVisual", "tblW", "jc", "tblCellSpacing", "tblInd", "tblBorders", "shd",
                  "tblLayout", "tblCellMar", "tblLook"],
        "tblBorders": ["top", "left", "start", "bottom", "right", "end", "insideH", "insideV"],
        "tcPr": ["cnfStyle", "tcW", "gridSpan", "vMerge", "tcBorders", "shd", "noWrap", "tcMar", "textDirection", "vAlign"],
        "sectPr": ["headerReference", "footerReference", "type", "pgSz", "pgMar", "cols", "docGrid"],
        "tbl": ["tblPr", "tblGrid", "tr"],
        "tc": ["tcPr", "p", "tbl"],
    ]

    private func assertSchemaOrder(_ docx: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let scratch = try Output.temporaryFolder()
        try await Zip.extract(docx, to: scratch)
        let document = try XMLDocument(contentsOf: scratch.appendingPathComponent("word/document.xml"))
        for (parent, sequence) in Self.order {
            for node in try document.nodes(forXPath: "//*[local-name()='\(parent)']") {
                let children = (node.children ?? []).compactMap { $0.localName }
                let positions = children.map { sequence.firstIndex(of: $0) }
                XCTAssertFalse(positions.contains(nil), "\(parent) has an unknown child in \(children)", file: file, line: line)
                let known = positions.compactMap { $0 }
                XCTAssertEqual(known, known.sorted(), "\(parent) children out of order: \(children)", file: file, line: line)
            }
        }
        // A paragraph's properties must come first.
        for node in try document.nodes(forXPath: "//*[local-name()='p'][*[local-name()='pPr']]") {
            XCTAssertEqual(node.children?.first?.localName, "pPr", file: file, line: line)
        }
    }

    @MainActor
    func testEditableAndExactWordFilesFollowSchemaOrder() async throws {
        let pdf = try PDFFormattingTests.makeReport(in: folder)
        try await assertSchemaOrder(try await PDFConverter.convert(pdf, to: .docx, layout: .editable))
        try await assertSchemaOrder(try await PDFConverter.convert(pdf, to: .docx, layout: .exact))
        try await assertSchemaOrder(try await PDFConverter.convert(try makeTextPDF(), to: .docx, layout: .editable))
    }
}

// MARK: Pictures

final class PictureFidelityTests: FixtureCase {
    /// Word → PDF keeps pictures (macOS's plain Word reader drops them) and paginates.
    @MainActor
    func testWordToPDFKeepsPictures() async throws {
        // A Word file with three full-page pictures, from the exact-pages writer.
        let source = try makePDF("pictures.pdf", pages: 3)
        let docx = try await PDFConverter.convert(source, to: .docx, layout: .exact)
        let pdf = try await DocumentConverter.convert(docx, to: .pdf)
        let doc = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThanOrEqual(doc.pageCount, 3)
        XCTAssertGreaterThan(PDFPageStyles(doc.page(at: 0)!.pageRef!).images.count, 0, "pictures survive")
    }

    /// Text-and-picture Word file: the text stays real text, and the picture comes through.
    @MainActor
    func testWordToPDFKeepsTextAndPictures() async throws {
        let docx = try await PDFConverter.convert(try PDFFormattingTests.makeReport(in: folder), to: .docx, layout: .editable)
        let pdf = try await DocumentConverter.convert(docx, to: .pdf)
        let doc = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertTrue(doc.string?.contains("Gadgets and accessories") ?? false)
        XCTAssertTrue(doc.string?.contains("Quarterly Sales") ?? false)
        XCTAssertGreaterThan(PDFPageStyles(doc.page(at: 0)!.pageRef!).images.count, 0)
    }
}
