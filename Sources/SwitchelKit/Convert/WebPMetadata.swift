import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads and writes WebP's EXIF and XMP chunks, leaving the pixels untouched. ImageIO reads these but
/// can't write WebP, so it builds the metadata on a tiny JPEG and the bytes are moved across.
enum WebPMetadata {
    private struct Chunk {
        var name: String
        var payload: [UInt8]
    }

    /// A tiny JPEG holding the WebP's metadata, for ImageIO to edit.
    static func carrier(from source: CGImageSource) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SwitchelError("Couldn't prepare the metadata")
        }
        let pixel = try ImageConverter.context(width: 1, height: 1, alpha: false)
        guard let image = pixel.makeImage() else { throw SwitchelError("Couldn't prepare the metadata") }
        CGImageDestinationAddImageAndMetadata(dest, image, CGImageSourceCopyMetadataAtIndex(source, 0, nil), nil)
        guard CGImageDestinationFinalize(dest) else { throw SwitchelError("Couldn't prepare the metadata") }
        return data as Data
    }

    /// Writes `url`'s image to `out`, with its metadata replaced by the JPEG's.
    static func replaceMetadata(of url: URL, withMetadataOfJPEG jpeg: Data, to out: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw SwitchelError("Couldn't read \(url.lastPathComponent)")
        }
        let segments = metadataSegments(ofJPEG: [UInt8](jpeg))
        let result = try rewritten(chunks(of: [UInt8](Data(contentsOf: url)), name: url.lastPathComponent),
                                   exif: segments.exif.map { withPixelSize($0, width: width, height: height) }, xmp: segments.xmp,
                                   width: width, height: height)
        try Data(serialized(result)).write(to: out)
    }

    /// Adds ImageIO-style metadata to a WebP file just written.
    static func embed(_ metadata: [CFString: Any], in url: URL) throws {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil),
              let pixel = try ImageConverter.context(width: 1, height: 1, alpha: false).makeImage() else { return }
        CGImageDestinationAddImage(dest, pixel, metadata as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        try replaceMetadata(of: url, withMetadataOfJPEG: data as Data, to: url)
    }

    // MARK: JPEG

    private static func metadataSegments(ofJPEG bytes: [UInt8]) -> (exif: [UInt8]?, xmp: [UInt8]?) {
        let exifMark = Array("Exif\0\0".utf8), xmpMark = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
        var exif: [UInt8]?, xmp: [UInt8]?
        var position = 2
        while position + 4 <= bytes.count, bytes[position] == 0xFF, bytes[position + 1] != 0xDA {
            let marker = bytes[position + 1]
            let length = Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            let end = position + 2 + length
            guard length >= 2, end <= bytes.count else { break }
            let body = Array(bytes[(position + 4)..<end])
            if marker == 0xE1 {
                if body.starts(with: exifMark) { exif = Array(body.dropFirst(exifMark.count)) }
                if body.starts(with: xmpMark) { xmp = Array(body.dropFirst(xmpMark.count)) }
            }
            position = end
        }
        return (exif, xmp)
    }

    /// The carrier JPEG is 1×1 and its EXIF says so, so this writes the real size over it.
    private static func withPixelSize(_ tiff: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard tiff.count >= 8 else { return tiff }
        var result = tiff
        let bigEndian = tiff[0] == 0x4D
        func read(_ offset: Int, _ size: Int) -> Int? {
            guard offset >= 0, offset + size <= tiff.count else { return nil }
            return (0..<size).reduce(0) { $0 << 8 | Int(tiff[offset + (bigEndian ? $1 : size - 1 - $1)]) }
        }
        func write(_ value: Int, at offset: Int, size: Int) {
            for i in 0..<size { result[offset + (bigEndian ? size - 1 - i : i)] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        /// Each 12-byte entry in a directory: tag, type, count, value.
        func entries(_ directory: Int) -> [Int] {
            guard let count = read(directory, 2) else { return [] }
            return (0..<count).map { directory + 2 + $0 * 12 }.filter { $0 + 12 <= tiff.count }
        }
        guard let first = read(4, 4),
              let pointer = entries(first).first(where: { read($0, 2) == 0x8769 }),
              let exif = read(pointer + 8, 4) else { return tiff }
        for entry in entries(exif) {
            guard let tag = read(entry, 2), tag == 0xA002 || tag == 0xA003, let type = read(entry + 2, 2) else { continue }
            let value = tag == 0xA002 ? width : height
            // SHORT or LONG, stored left-aligned in the value field.
            if type == 3, value <= 0xFFFF { write(value, at: entry + 8, size: 2) }
            if type == 4 { write(value, at: entry + 8, size: 4) }
        }
        return result
    }

    // MARK: RIFF

    private static func chunks(of bytes: [UInt8], name: String) throws -> [Chunk] {
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF", String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" else {
            throw SwitchelError("\(name) isn't a valid WebP file")
        }
        var result: [Chunk] = []
        var position = 12
        while position + 8 <= bytes.count {
            let size = (0..<4).reduce(0) { $0 | Int(bytes[position + 4 + $1]) << (8 * $1) }
            guard position + 8 + size <= bytes.count else { throw SwitchelError("\(name) is damaged") }
            result.append(Chunk(name: String(decoding: bytes[position..<(position + 4)], as: UTF8.self),
                                payload: Array(bytes[(position + 8)..<(position + 8 + size)])))
            position += 8 + size + size % 2
        }
        return result
    }

    /// The order the format requires: VP8X, then image data, then EXIF and XMP.
    private static func rewritten(_ chunks: [Chunk], exif: [UInt8]?, xmp: [UInt8]?, width: Int, height: Int) throws -> [Chunk] {
        var kept = chunks.filter { !["VP8X", "EXIF", "XMP "].contains($0.name) }
        let existing = chunks.first { $0.name == "VP8X" }
        if exif == nil, xmp == nil, existing == nil { return kept }

        var header = existing?.payload ?? [0] + [UInt8](repeating: 0, count: 3)
            + littleEndian24(width - 1) + littleEndian24(height - 1)
        guard header.count >= 10 else { throw SwitchelError("This WebP file is damaged") }
        if existing == nil, hasAlpha(kept) { header[0] |= 0x10 }
        header[0] &= ~0x0C
        if exif != nil { header[0] |= 0x08 }
        if xmp != nil { header[0] |= 0x04 }

        kept.insert(Chunk(name: "VP8X", payload: header), at: 0)
        if let exif { kept.append(Chunk(name: "EXIF", payload: exif)) }
        if let xmp { kept.append(Chunk(name: "XMP ", payload: xmp)) }
        return kept
    }

    /// Lossless data records alpha in a flag after its signature and 28 bits of size.
    private static func hasAlpha(_ chunks: [Chunk]) -> Bool {
        chunks.contains { $0.name == "ALPH" } || chunks.contains { $0.name == "VP8L" && $0.payload.count > 4 && $0.payload[4] & 0x10 != 0 }
    }

    private static func littleEndian24(_ value: Int) -> [UInt8] {
        (0..<3).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    private static func serialized(_ chunks: [Chunk]) -> [UInt8] {
        var body = Array("WEBP".utf8)
        for chunk in chunks {
            body += Array(chunk.name.utf8)
            body += (0..<4).map { UInt8((chunk.payload.count >> (8 * $0)) & 0xFF) }
            body += chunk.payload
            if chunk.payload.count % 2 == 1 { body.append(0) }
        }
        return Array("RIFF".utf8) + (0..<4).map { UInt8((body.count >> (8 * $0)) & 0xFF) } + body
    }
}
