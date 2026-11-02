import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable {
    case jpg, png, webp, heic, tiff, avif, bmp, gif, pdf

    var type: UTType {
        switch self {
        case .jpg: .jpeg
        case .png: .png
        case .webp: .webP
        case .heic: .heic
        case .tiff: .tiff
        case .avif: UTType("public.avif") ?? .image
        case .bmp: .bmp
        case .gif: .gif
        case .pdf: .pdf
        }
    }

    var isLossy: Bool { [.jpg, .webp, .heic, .avif].contains(self) }
}

enum ImageConverter {
    static func convert(_ url: URL, to format: ImageFormat) async throws -> URL {
        let out = Output.url(for: url, ext: format.rawValue)
        if format == .pdf {
            try writePDF(try loadPages(url), to: out)
        } else {
            try await save(try load(url), to: out, as: format, quality: 0.9, metadata: metadata(of: url))
        }
        return out
    }

    /// Writes any `ImageFormat`, including the ones ImageIO can't encode (WebP).
    /// `metadata` (EXIF, GPS, IPTC) is carried into the formats ImageIO writes.
    static func save(_ image: CGImage, to url: URL, as format: ImageFormat, quality: Double, metadata: [CFString: Any]? = nil) async throws {
        switch format {
        case .pdf:
            try writePDF([image], to: url)
        case .webp:
            let cwebp = try Shell.require("cwebp", brew: "webp")
            let folder = try Output.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let png = folder.appendingPathComponent("in.png")
            try write(image, to: png, type: .png)
            try await Shell.run(cwebp, ["-quiet", "-q", String(Int(quality * 100)), "-alpha_q", "100", png.path, "-o", url.path])
            if let metadata { try WebPMetadata.embed(metadata, in: url) }
        default:
            try write(image, to: url, type: format.type, quality: format.isLossy ? quality : nil, metadata: metadata)
        }
    }

    /// The source's EXIF, GPS, IPTC and camera details, so a format change keeps the capture date and location.
    /// Orientation is reset because `load` has already rotated the pixels upright.
    static func metadata(of url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var kept = props.filter { [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                                   kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary].contains($0.key) }
        if var tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        // A crop or compress changes the size, so the source's would be wrong.
        if var exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            kept[kCGImagePropertyExifDictionary] = exif
        }
        kept[kCGImagePropertyOrientation] = 1
        return kept
    }

    /// Encodes into memory, for compression's size search.
    static func encode(_ image: CGImage, type: UTType, quality: Double, metadata: [CFString: Any]? = nil) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw SwitchelError("Can't encode \(type.preferredFilenameExtension ?? "images")")
        }
        let image = [UTType.jpeg, .bmp].contains(type) ? flattened(image) : image
        var props = metadata ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SwitchelError("Couldn't encode image") }
        return data as Data
    }

    // MARK: Reading and writing

    /// Loads the first frame with EXIF orientation applied, optionally downscaled.
    static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            let fullSize = max(width, height)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize ?? fullSize, fullSize),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return image
            }
        }
        // ImageIO can't decode vector formats like SVG; NSImage can.
        if let image = NSImage(contentsOf: url) {
            let target = CGFloat(maxPixelSize ?? 2048)
            let scale = target / max(image.size.width, image.size.height, 1)
            var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return cg }
        }
        throw SwitchelError("Couldn't read \(url.lastPathComponent)")
    }

    /// Every page of a multipage TIFF; other images give their first frame, so an animated GIF isn't one page per frame.
    static func loadPages(_ url: URL) throws -> [CGImage] {
        guard Output.normalizedExtension(url) == "tiff",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 1 else { return [try load(url)] }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return try (0..<CGImageSourceGetCount(source)).map { index in
            var pageOptions = options
            if let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
               let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int {
                pageOptions[kCGImageSourceThumbnailMaxPixelSize] = max(width, height)
            }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, pageOptions as CFDictionary) else {
                throw SwitchelError("Couldn't read page \(index + 1) of \(url.lastPathComponent)")
            }
            return image
        }
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double? = nil, metadata: [CFString: Any]? = nil) throws {
        let image = [UTType.jpeg, .bmp].contains(type) ? flattened(image) : image
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw SwitchelError("Can't write \(type.preferredFilenameExtension ?? "this format") files")
        }
        var props = metadata ?? [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SwitchelError("Couldn't write \(url.lastPathComponent)") }
    }

    /// One image per page: A4, or US Letter where the region uses it, turned to match the image.
    /// Images are centred within margins, scaled down to fit and never up past 72 pixels per inch.
    static func writePDF(_ images: [CGImage], to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw SwitchelError("Couldn't create \(url.lastPathComponent)")
        }
        let paper = Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
        let margin: CGFloat = 36
        for image in images {
            let landscape = image.width > image.height
            var page = CGRect(origin: .zero, size: landscape ? CGSize(width: paper.height, height: paper.width) : paper)
            let area = page.insetBy(dx: margin, dy: margin)
            let scale = min(1, area.width / CGFloat(image.width), area.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ctx.beginPage(mediaBox: &page)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: page.midX - size.width / 2, y: page.midY - size.height / 2, width: size.width, height: size.height))
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// The source's own format when we can write it, otherwise PNG.
    static func sameFormat(as url: URL) -> ImageFormat {
        let ext = Output.normalizedExtension(url)
        return ImageFormat(rawValue: ext).flatMap { $0 == .pdf ? nil : $0 } ?? .png
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    /// Composites onto white, for formats without transparency.
    static func flattened(_ image: CGImage, background: CGColor = .white) -> CGImage {
        guard hasAlpha(image), let ctx = try? context(width: image.width, height: image.height, alpha: false) else {
            return image
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(background)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func context(width: Int, height: Int, alpha: Bool) throws -> CGContext {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue) else {
            throw SwitchelError("Image is too large (\(width)×\(height))")
        }
        return ctx
    }
}
