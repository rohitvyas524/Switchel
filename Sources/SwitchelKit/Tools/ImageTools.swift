import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Image tools. Rectangles and points are in image pixels with a top-left origin.
enum ImageTools {
    // MARK: Compress

    struct Compression {
        enum Target: Equatable {
            case quality(Double)
            case maxBytes(Int)
        }
        var target: Target = .quality(0.6)
        var maxDimension: Int? = 2560
        /// nil picks HEIC for images with transparency, JPEG otherwise.
        var format: ImageFormat?
    }

    static func compress(_ url: URL, _ options: Compression = .init()) async throws -> URL {
        var image = try ImageConverter.load(url, maxPixelSize: options.maxDimension)
        let format = options.format ?? (ImageConverter.hasAlpha(image) ? .heic : .jpg)
        let out = Output.url(for: url, ext: format.rawValue, suffix: "compressed")
        switch options.target {
        case .quality(let quality):
            try await ImageConverter.save(image, to: out, as: format, quality: quality)
        case .maxBytes(let limit):
            if format == .webp {
                let cwebp = try Shell.require("cwebp", brew: "webp")
                let png = try Output.temporaryFolder().appendingPathComponent("in.png")
                defer { try? FileManager.default.removeItem(at: png.deletingLastPathComponent()) }
                try ImageConverter.write(image, to: png, type: .png)
                try await Shell.run(cwebp, ["-quiet", "-size", String(limit), png.path, "-o", out.path])
                return out
            }
            // Search quality first; if even the lowest is too big, shrink and search again.
            let type = format.isLossy ? format.type : UTType.jpeg
            for _ in 0..<6 {
                var low = 0.05, high = 0.95
                var best: Data?
                for _ in 0..<7 {
                    let mid = (low + high) / 2
                    let data = try ImageConverter.encode(image, type: type, quality: mid)
                    if data.count <= limit { best = data; low = mid } else { high = mid }
                }
                if best == nil, let lowest = try? ImageConverter.encode(image, type: type, quality: 0.05), lowest.count <= limit {
                    best = lowest
                }
                if let best {
                    try best.write(to: out)
                    return out
                }
                image = try resized(image, scale: 0.75)
            }
            throw SwitchelError("Couldn't get \(url.lastPathComponent) under \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))")
        }
        return out
    }

    static func resized(_ image: CGImage, scale: CGFloat) throws -> CGImage {
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        let ctx = try ImageConverter.context(width: width, height: height, alpha: ImageConverter.hasAlpha(image))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = ctx.makeImage() else { throw SwitchelError("Couldn't resize image") }
        return result
    }

    // MARK: Crop, rotate

    static func crop(_ url: URL, to rect: CGRect) async throws -> URL {
        let image = try ImageConverter.load(url)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let cropped = image.cropping(to: rect.integral.intersection(bounds)) else {
            throw SwitchelError("The crop area is empty")
        }
        return try await saveCopy(cropped, of: url, suffix: "cropped")
    }

    static func rotateClockwise(_ url: URL) async throws -> URL {
        let image = try ImageConverter.load(url)
        let ctx = try ImageConverter.context(width: image.height, height: image.width, alpha: ImageConverter.hasAlpha(image))
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = ctx.makeImage() else { throw SwitchelError("Couldn't rotate \(url.lastPathComponent)") }
        return try await saveCopy(rotated, of: url, suffix: "rotated")
    }

    /// Saves in the source's format (PNG when we can't write it).
    static func saveCopy(_ image: CGImage, of url: URL, suffix: String, forceTransparency: Bool = false) async throws -> URL {
        var format = ImageConverter.sameFormat(as: url)
        if forceTransparency && [.jpg, .bmp].contains(format) { format = .png }
        let out = Output.url(for: url, ext: format.rawValue, suffix: suffix)
        try await ImageConverter.save(image, to: out, as: format, quality: 0.95)
        return out
    }

    // MARK: Annotate

    struct Mark: Identifiable {
        enum Shape {
            case pen([CGPoint])
            case highlighter([CGPoint])
            case arrow(CGPoint, CGPoint)
            case rectangle(CGRect)
            case ellipse(CGRect)
            case text(String, CGPoint)
        }
        let id = UUID()
        var shape: Shape
        var color: NSColor
        var lineWidth: CGFloat
    }

    static func annotate(_ image: CGImage, with marks: [Mark]) throws -> CGImage {
        let width = image.width, height = image.height
        let ctx = try ImageConverter.context(width: width, height: height, alpha: ImageConverter.hasAlpha(image))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for mark in marks {
            ctx.saveGState()
            ctx.setStrokeColor(mark.color.cgColor)
            ctx.setFillColor(mark.color.cgColor)
            ctx.setLineWidth(mark.lineWidth)
            switch mark.shape {
            case .pen(let points):
                stroke(points, in: ctx)
            case .highlighter(let points):
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(mark.color.withAlphaComponent(0.4).cgColor)
                ctx.setLineWidth(mark.lineWidth * 4)
                stroke(points, in: ctx)
            case .arrow(let from, let to):
                drawArrow(from: from, to: to, width: mark.lineWidth, in: ctx)
            case .rectangle(let rect):
                ctx.stroke(rect.standardized)
            case .ellipse(let rect):
                ctx.strokeEllipse(in: rect.standardized)
            case .text(let string, let point):
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSAttributedString(string: string, attributes: [
                    .font: NSFont.systemFont(ofSize: mark.lineWidth * 6, weight: .semibold),
                    .foregroundColor: mark.color,
                ]).draw(at: point)
                NSGraphicsContext.restoreGraphicsState()
            }
            ctx.restoreGState()
        }
        guard let result = ctx.makeImage() else { throw SwitchelError("Couldn't draw annotations") }
        return result
    }

    private static func stroke(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.move(to: first)
        points.dropFirst().forEach { ctx.addLine(to: $0) }
        if points.count == 1 { ctx.addLine(to: first) }
        ctx.strokePath()
    }

    static func drawArrow(from: CGPoint, to: CGPoint, width: CGFloat, in ctx: CGContext) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = max(width * 4, 12)
        let base = CGPoint(x: to.x - cos(angle) * head * 0.8, y: to.y - sin(angle) * head * 0.8)
        ctx.move(to: from)
        ctx.addLine(to: base)
        ctx.strokePath()
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x - cos(angle - .pi / 7) * head, y: to.y - sin(angle - .pi / 7) * head))
        ctx.addLine(to: CGPoint(x: to.x - cos(angle + .pi / 7) * head, y: to.y - sin(angle + .pi / 7) * head))
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: Redact

    enum RedactionStyle: String, CaseIterable, Identifiable {
        case blur, pixelate, black
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    static func redact(_ image: CGImage, regions: [CGRect], style: RedactionStyle) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let strength = max(extent.width, extent.height) / 60
        let effect: CIImage = switch style {
        case .blur: input.clampedToExtent().applyingGaussianBlur(sigma: strength).cropped(to: extent)
        case .pixelate: input.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, strength)]).cropped(to: extent)
        case .black: CIImage(color: .black).cropped(to: extent)
        }
        let output = regions.reduce(input) { result, region in
            let flipped = CGRect(x: region.minX, y: extent.height - region.maxY, width: region.width, height: region.height)
            return effect.cropped(to: flipped.standardized).composited(over: result)
        }
        guard let result = CIContext().createCGImage(output, from: extent) else { throw SwitchelError("Couldn't redact image") }
        return result
    }

    /// Faces (padded a little) and lines of text, for one-click redaction.
    static func detectSensitiveRegions(in image: CGImage, faces: Bool, text: Bool) throws -> [CGRect] {
        let handler = VNImageRequestHandler(cgImage: image)
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        try handler.perform((faces ? [faceRequest] : []) + (text ? [textRequest] : []))
        let size = CGSize(width: image.width, height: image.height)
        func pixels(_ box: CGRect, padding: CGFloat) -> CGRect {
            CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
                .insetBy(dx: -box.width * size.width * padding, dy: -box.height * size.height * padding)
        }
        let faceBoxes = faces ? (faceRequest.results ?? []).map { pixels($0.boundingBox, padding: 0.15) } : []
        let textBoxes = text ? (textRequest.results ?? []).map { pixels($0.boundingBox, padding: 0.05) } : []
        return faceBoxes + textBoxes
    }

    // MARK: Background

    enum Backdrop {
        case transparent
        case color(NSColor)
        case image(CGImage)
        /// The photo's own background, blurred, like a portrait-mode shot. 0–1.
        case blur(CGFloat)
    }

    /// The subject's mask, computed once so previews can swap backgrounds instantly.
    struct Subject {
        let image: CIImage
        let mask: CIImage
    }

    static func subject(of image: CGImage) throws -> Subject {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw SwitchelError("No subject found in this image")
        }
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        return Subject(image: CIImage(cgImage: image), mask: CIImage(cvPixelBuffer: mask))
    }

    static func composite(_ subject: Subject, over backdrop: Backdrop) throws -> CGImage {
        let extent = subject.image.extent
        let background: CIImage = switch backdrop {
        case .transparent: CIImage(color: .clear).cropped(to: extent)
        case .color(let color): CIImage(color: CIColor(color: color) ?? .white).cropped(to: extent)
        case .image(let image): aspectFill(CIImage(cgImage: image), into: extent)
        case .blur(let amount):
            subject.image.clampedToExtent().applyingGaussianBlur(sigma: max(extent.width, extent.height) * amount * 0.04).cropped(to: extent)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = subject.image
        blend.backgroundImage = background
        blend.maskImage = subject.mask
        guard let output = blend.outputImage, let result = CIContext().createCGImage(output, from: extent) else {
            throw SwitchelError("Couldn't replace the background")
        }
        return result
    }

    private static func aspectFill(_ image: CIImage, into extent: CGRect) -> CIImage {
        let scale = max(extent.width / image.extent.width, extent.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - extent.width) / 2, dy = (scaled.extent.height - extent.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX - dx, y: -scaled.extent.minY - dy)).cropped(to: extent)
    }

    // MARK: Adjust

    struct Adjustments: Equatable {
        var exposure: Double = 0  // EV, -2…2
        var brightness: Double = 0  // -0.5…0.5
        var contrast: Double = 1  // 0.5…1.5
        var saturation: Double = 1  // 0…2
        var warmth: Double = 0  // -1…1
        var highlights: Double = 1  // 0…1, lower recovers highlights
        var shadows: Double = 0  // 0…1, higher lifts shadows
        var sharpness: Double = 0  // 0…2

        var isIdentity: Bool { self == Adjustments() }
    }

    static func adjust(_ image: CGImage, _ adjustments: Adjustments) throws -> CGImage {
        let input = CIImage(cgImage: image)
        var output = input
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adjustments.exposure])
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: adjustments.brightness,
                                                            kCIInputContrastKey: adjustments.contrast,
                                                            kCIInputSaturationKey: adjustments.saturation])
            .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": adjustments.highlights,
                                                                   "inputShadowAmount": adjustments.shadows])
        if adjustments.warmth != 0 {
            // Neutral is 6500 K; warming means telling the filter the light was cooler.
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + adjustments.warmth * 2500, y: 0),
            ])
        }
        if adjustments.sharpness > 0 {
            output = output.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: adjustments.sharpness])
        }
        guard let result = CIContext().createCGImage(output.cropped(to: input.extent), from: input.extent) else {
            throw SwitchelError("Couldn't render the photo adjustments")
        }
        return result
    }

    // MARK: Frame

    struct FrameOptions: Equatable {
        enum Ratio: String, CaseIterable, Identifiable {
            case auto, square, wide, tall, classic
            var id: Self { self }
            var title: String {
                switch self {
                case .auto: "Auto"
                case .square: "1:1"
                case .wide: "16:9"
                case .tall: "9:16"
                case .classic: "4:3"
                }
            }
            var value: CGFloat? {
                switch self {
                case .auto: nil
                case .square: 1
                case .wide: 16 / 9
                case .tall: 9 / 16
                case .classic: 4 / 3
                }
            }
        }
        var padding: CGFloat = 0.08  // of the longer side
        var cornerRadius: CGFloat = 0.02
        var shadow = true
        var colors: [NSColor] = [NSColor(srgbRed: 1, green: 0.55, blue: 0.2, alpha: 1), NSColor(srgbRed: 0.9, green: 0.2, blue: 0.5, alpha: 1)]
        var ratio: Ratio = .auto
        /// Tilt in degrees.
        var rotation: CGFloat = 0
    }

    static let solidPresets: [NSColor] = [
        .white, NSColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 1), NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1),
        NSColor(srgbRed: 1, green: 0.6, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.3, green: 0.55, blue: 1, alpha: 1), NSColor(srgbRed: 0.35, green: 0.8, blue: 0.5, alpha: 1),
    ]

    static let framePresets: [[NSColor]] = [
        [NSColor(srgbRed: 1, green: 0.55, blue: 0.2, alpha: 1), NSColor(srgbRed: 0.9, green: 0.2, blue: 0.5, alpha: 1)],
        [NSColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 1), NSColor(srgbRed: 0.5, green: 0.2, blue: 0.9, alpha: 1)],
        [NSColor(srgbRed: 0.1, green: 0.8, blue: 0.6, alpha: 1), NSColor(srgbRed: 0.1, green: 0.4, blue: 0.8, alpha: 1)],
        [NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1), NSColor(srgbRed: 0.8, green: 0.82, blue: 0.88, alpha: 1)],
        [NSColor(srgbRed: 0.15, green: 0.15, blue: 0.18, alpha: 1), NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)],
    ]

    static func frame(_ image: CGImage, _ options: FrameOptions) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad = options.padding * max(w, h)
        // A tilted image needs room for its rotated bounding box.
        let angle = options.rotation * .pi / 180
        let bounds = CGSize(width: abs(w * cos(angle)) + abs(h * sin(angle)), height: abs(w * sin(angle)) + abs(h * cos(angle)))
        var canvas = CGSize(width: bounds.width + pad * 2, height: bounds.height + pad * 2)
        if let ratio = options.ratio.value {
            if canvas.width / canvas.height < ratio { canvas.width = canvas.height * ratio } else { canvas.height = canvas.width / ratio }
        }
        let ctx = try ImageConverter.context(width: Int(canvas.width), height: Int(canvas.height), alpha: false)
        let colors = options.colors.map(\.cgColor) as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        }
        ctx.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        ctx.rotate(by: -angle)
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let radius = options.cornerRadius * max(w, h)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if options.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.15), blur: max(pad * 0.5, 8), color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(.white)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        guard let result = ctx.makeImage() else { throw SwitchelError("Couldn't frame image") }
        return result
    }

    // MARK: Collage

    struct CollageOptions: Equatable {
        var columns = 0  // 0 picks automatically
        var spacing: CGFloat = 0.015  // of the width
        var cornerRadius: CGFloat = 0.01
        var background: NSColor = .white
        var width: CGFloat = 2400
    }

    /// Justified rows: every image in a row shares a height and the row fills the width.
    static func collage(_ images: [CGImage], _ options: CollageOptions) throws -> CGImage {
        guard !images.isEmpty else { throw SwitchelError("Add some images first") }
        let columns = options.columns > 0 ? options.columns : max(1, Int(ceil(sqrt(Double(images.count)))))
        let gap = options.spacing * options.width
        let rows = stride(from: 0, to: images.count, by: columns).map { Array(images[$0..<min($0 + columns, images.count)]) }
        let fullRowHeight: (([CGImage]) -> CGFloat) = { row in
            (options.width - gap * CGFloat(row.count + 1)) / row.reduce(0) { $0 + CGFloat($1.width) / CGFloat($1.height) }
        }
        let typical = fullRowHeight(rows[0])
        // A short last row keeps the others' height instead of blowing up.
        let heights = rows.map { min(fullRowHeight($0), typical) }
        let total = heights.reduce(gap) { $0 + $1 + gap }

        let ctx = try ImageConverter.context(width: Int(options.width), height: Int(total), alpha: false)
        ctx.setFillColor(options.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: options.width, height: total))
        var top = gap
        for (row, height) in zip(rows, heights) {
            let rowWidth = row.reduce(0) { $0 + CGFloat($1.width) / CGFloat($1.height) * height } + gap * CGFloat(row.count - 1)
            var x = (options.width - rowWidth) / 2
            for image in row {
                let width = CGFloat(image.width) / CGFloat(image.height) * height
                let rect = CGRect(x: x, y: total - top - height, width: width, height: height)
                let radius = options.cornerRadius * options.width
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.clip()
                ctx.interpolationQuality = .high
                ctx.draw(image, in: rect)
                ctx.restoreGState()
                x += width + gap
            }
            top += height + gap
        }
        guard let result = ctx.makeImage() else { throw SwitchelError("Couldn't build collage") }
        return result
    }

    // MARK: Metadata

    struct MetadataEntry: Identifiable, Hashable {
        var id: String { "\(group).\(key)" }
        let group: String
        let key: String
        let value: String
    }

    static func metadata(of url: URL) -> [MetadataEntry] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        var entries: [MetadataEntry] = []
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            if let group = value as? [String: Any] {
                let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                for (field, fieldValue) in group.sorted(by: { $0.key < $1.key }) {
                    entries.append(MetadataEntry(group: name, key: field, value: describe(fieldValue)))
                }
            } else {
                entries.append(MetadataEntry(group: "Image", key: key, value: describe(value)))
            }
        }
        return entries
    }

    private static func describe(_ value: Any) -> String {
        if let array = value as? [Any] { return array.map(describe).joined(separator: ", ") }
        if let dictionary = value as? [String: Any] { return dictionary.map { "\($0.key): \(describe($0.value))" }.joined(separator: ", ") }
        return "\(value)"
    }

    struct MetadataChanges: Equatable {
        var description: String?
        var artist: String?
        var copyright: String?
        var dateTaken: Date?
        var removeLocation = false
        var removeAll = false
    }

    /// Rewrites metadata without re-encoding the pixels.
    static func editMetadata(_ url: URL, _ changes: MetadataChanges) async throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw SwitchelError("Couldn't read \(url.lastPathComponent)")
        }
        let out = Output.url(for: url, ext: url.pathExtension, suffix: changes.removeAll ? "clean" : "edited")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else {
            // Formats ImageIO can't write (WebP): re-encode instead.
            return try await saveCopy(try ImageConverter.load(url), of: url, suffix: "clean")
        }
        let existing = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let metadata = changes.removeAll || existing == nil ? CGImageMetadataCreateMutable() : CGImageMetadataCreateMutableCopy(existing!)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

        func set(_ group: CFString, _ key: CFString, _ value: CFTypeRef) {
            CGImageMetadataSetValueMatchingImageProperty(metadata, group, key, value)
        }
        if changes.removeAll, let orientation = properties?[kCGImagePropertyOrientation] {
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFTypeRef)
        }
        if let value = changes.description { set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, value as CFString) }
        if let value = changes.artist { set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, value as CFString) }
        if let value = changes.copyright { set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright, value as CFString) }
        if let date = changes.dateTaken {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, formatter.string(from: date) as CFString)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: changes.removeLocation || changes.removeAll,
            kCGImageMetadataShouldExcludeXMP: changes.removeAll,
        ]
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil) else {
            throw SwitchelError("Couldn't save metadata for \(url.lastPathComponent)")
        }
        return out
    }

    // MARK: QR codes

    static func readCodes(_ url: URL) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: try ImageConverter.load(url)).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    // MARK: Icon

    struct IconOptions: Equatable {
        enum Shape: String, CaseIterable, Identifiable {
            case squircle, circle, square
            var id: Self { self }
            var title: String { rawValue.capitalized }
        }
        var shape: Shape = .squircle
        var padding: CGFloat = 0.1
        var background: NSColor = .white
    }

    /// A 1024 px master following Apple's icon grid (824 px body on a 1024 canvas).
    static func icon(_ image: CGImage, _ options: IconOptions) throws -> CGImage {
        let size: CGFloat = 1024
        let ctx = try ImageConverter.context(width: Int(size), height: Int(size), alpha: true)
        let body = options.shape == .square ? CGRect(x: 0, y: 0, width: size, height: size) : CGRect(x: 100, y: 100, width: 824, height: 824)
        let path: CGPath = switch options.shape {
        case .squircle: CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        case .circle: CGPath(ellipseIn: body, transform: nil)
        case .square: CGPath(rect: body, transform: nil)
        }
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(options.background.cgColor)
        ctx.fill(body)
        let inner = body.insetBy(dx: body.width * options.padding, dy: body.height * options.padding)
        let scale = min(inner.width / CGFloat(image.width), inner.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: inner.midX - drawn.width / 2, y: inner.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
        guard let result = ctx.makeImage() else { throw SwitchelError("Couldn't render icon") }
        return result
    }

    /// An .icns with every standard size.
    static func writeICNS(_ master: CGImage, to url: URL) throws {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, sizes.count, nil) else {
            throw SwitchelError("Can't write icons")
        }
        for size in sizes {
            CGImageDestinationAddImage(dest, try resized(master, scale: CGFloat(size) / CGFloat(master.width)), nil)
        }
        guard CGImageDestinationFinalize(dest) else { throw SwitchelError("Couldn't write \(url.lastPathComponent)") }
    }

    // MARK: PDF

    /// One PDF page per image, named after the first file.
    static func combineIntoPDF(_ urls: [URL]) throws -> URL {
        let images = try urls.map { try ImageConverter.load($0) }
        let out = Output.url(for: urls[0], ext: "pdf", suffix: urls.count > 1 ? "combined" : nil)
        try ImageConverter.writePDF(images, to: out)
        return out
    }
}
