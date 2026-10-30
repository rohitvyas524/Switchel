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
        let image = try load(url)
        let out = Output.url(for: url, ext: format.rawValue)
        try await save(image, to: out, as: format, quality: 0.9)
        return out
    }

    /// Writes any `ImageFormat`, including the ones ImageIO can't encode (WebP).
    static func save(_ image: CGImage, to url: URL, as format: ImageFormat, quality: Double) async throws {
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
        default:
            try write(image, to: url, type: format.type, quality: format.isLossy ? quality : nil)
        }
    }

    /// Encodes into memory, for compression's size search.
    static func encode(_ image: CGImage, type: UTType, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw SwitchelError("Can't encode \(type.preferredFilenameExtension ?? "images")")
        }
        let image = [UTType.jpeg, .bmp].contains(type) ? flattened(image) : image
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
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

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double? = nil) throws {
        let image = [UTType.jpeg, .bmp].contains(type) ? flattened(image) : image
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw SwitchelError("Can't write \(type.preferredFilenameExtension ?? "this format") files")
        }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SwitchelError("Couldn't write \(url.lastPathComponent)") }
    }

    static func writePDF(_ images: [CGImage], to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw SwitchelError("Couldn't create \(url.lastPathComponent)")
        }
        for image in images {
            var page = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ctx.beginPage(mediaBox: &page)
            ctx.draw(image, in: page)
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
