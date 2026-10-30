import AppKit
import CoreGraphics

/// Reads a page's content stream for what PDFKit doesn't report: each text run's real font,
/// size and colour, where pictures sit, and filled or stroked boxes (table borders, shading,
/// underlines). Everything is in page space, the same space as `PDFPage` bounds.
final class PDFPageStyles {
    struct TextRun {
        var start: CGPoint
        var endX: CGFloat
        var font: String
        var size: CGFloat
        var color: CGColor
    }

    struct Shape {
        var rect: CGRect
        var color: CGColor
        var stroked: Bool
    }

    private(set) var runs: [TextRun] = []
    private(set) var images: [CGRect] = []
    private(set) var shapes: [Shape] = []

    private struct GraphicsState {
        var ctm: CGAffineTransform = .identity
        var fill: CGColor = .black
        var stroke: CGColor = .black
        var fillComponents = 1
        var strokeComponents = 1
        var lineWidth: CGFloat = 1
    }

    private struct Font {
        var name: String
        var widths: [Int: CGFloat]  // per 1000 units of text space
        var defaultWidth: CGFloat
        var twoByte: Bool
    }

    private var state = GraphicsState()
    private var saved: [GraphicsState] = []
    private var resources: [CGPDFDictionaryRef] = []
    private var streams: [CGPDFContentStreamRef] = []
    private var fonts: [String: Font] = [:]

    // Text state.
    private var textMatrix = CGAffineTransform.identity
    private var lineMatrix = CGAffineTransform.identity
    private var font: Font?
    private var fontSize: CGFloat = 0
    private var leading: CGFloat = 0
    private var charSpacing: CGFloat = 0
    private var wordSpacing: CGFloat = 0
    private var horizontalScale: CGFloat = 1
    private var rise: CGFloat = 0

    // Path under construction, in page space.
    private var path: [CGRect] = []
    private var point = CGPoint.zero

    init(_ page: CGPDFPage) {
        guard let pageDictionary = page.dictionary else { return }
        var pageResources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &pageResources)
        scan(CGPDFContentStreamCreateWithPage(page), resources: pageResources)
    }

    // MARK: Scanning

    private func scan(_ stream: CGPDFContentStreamRef, resources dictionary: CGPDFDictionaryRef?) {
        if let dictionary { resources.append(dictionary) }
        streams.append(stream)
        let table = Self.operators
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        streams.removeLast()
        if dictionary != nil { resources.removeLast() }
    }

    private static let operators: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        func on(_ name: String, _ handler: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, name, handler) }

        // Graphics state
        on("q") { _, info in me(info).saved.append(me(info).state) }
        on("Q") { _, info in let s = me(info); if let last = s.saved.popLast() { s.state = last } }
        on("cm") { scanner, info in
            guard let m = numbers(scanner, 6) else { return }
            let s = me(info)
            s.state.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(s.state.ctm)
        }
        on("w") { scanner, info in if let w = numbers(scanner, 1) { me(info).state.lineWidth = w[0] } }

        // Colour
        on("g") { scanner, info in if let v = numbers(scanner, 1) { me(info).state.fill = gray(v[0]); me(info).state.fillComponents = 1 } }
        on("G") { scanner, info in if let v = numbers(scanner, 1) { me(info).state.stroke = gray(v[0]); me(info).state.strokeComponents = 1 } }
        on("rg") { scanner, info in if let v = numbers(scanner, 3) { me(info).state.fill = rgb(v); me(info).state.fillComponents = 3 } }
        on("RG") { scanner, info in if let v = numbers(scanner, 3) { me(info).state.stroke = rgb(v); me(info).state.strokeComponents = 3 } }
        on("k") { scanner, info in if let v = numbers(scanner, 4) { me(info).state.fill = cmyk(v); me(info).state.fillComponents = 4 } }
        on("K") { scanner, info in if let v = numbers(scanner, 4) { me(info).state.stroke = cmyk(v); me(info).state.strokeComponents = 4 } }
        on("cs") { scanner, info in let s = me(info); s.state.fillComponents = s.components(ofSpace: popName(scanner)) }
        on("CS") { scanner, info in let s = me(info); s.state.strokeComponents = s.components(ofSpace: popName(scanner)) }
        let fillColor: CGPDFOperatorCallback = { scanner, info in
            let s = me(info)
            if let v = numbers(scanner, s.state.fillComponents) { s.state.fill = color(v) }
        }
        let strokeColor: CGPDFOperatorCallback = { scanner, info in
            let s = me(info)
            if let v = numbers(scanner, s.state.strokeComponents) { s.state.stroke = color(v) }
        }
        on("sc", fillColor)
        on("scn", fillColor)
        on("SC", strokeColor)
        on("SCN", strokeColor)

        // Paths
        on("m") { scanner, info in if let p = numbers(scanner, 2) { me(info).point = CGPoint(x: p[0], y: p[1]) } }
        on("l") { scanner, info in
            guard let p = numbers(scanner, 2) else { return }
            let s = me(info), to = CGPoint(x: p[0], y: p[1])
            s.path.append(CGRect(x: min(s.point.x, to.x), y: min(s.point.y, to.y), width: abs(to.x - s.point.x), height: abs(to.y - s.point.y)).applying(s.state.ctm))
            s.point = to
        }
        on("re") { scanner, info in
            guard let r = numbers(scanner, 4) else { return }
            let s = me(info)
            s.path.append(CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).standardized.applying(s.state.ctm))
        }
        for name in ["S", "s"] { on(name) { _, info in me(info).finishPath(fill: false, stroke: true) } }
        for name in ["f", "F", "f*"] { on(name) { _, info in me(info).finishPath(fill: true, stroke: false) } }
        for name in ["B", "B*", "b", "b*"] { on(name) { _, info in me(info).finishPath(fill: true, stroke: true) } }
        on("n") { _, info in me(info).path.removeAll() }

        // Text
        on("BT") { _, info in let s = me(info); s.textMatrix = .identity; s.lineMatrix = .identity }
        on("Tf") { scanner, info in
            var size: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &size), let name = popName(scanner) else { return }
            let s = me(info)
            s.fontSize = size
            s.font = s.lookUpFont(name)
        }
        on("Tc") { scanner, info in if let v = numbers(scanner, 1) { me(info).charSpacing = v[0] } }
        on("Tw") { scanner, info in if let v = numbers(scanner, 1) { me(info).wordSpacing = v[0] } }
        on("Tz") { scanner, info in if let v = numbers(scanner, 1) { me(info).horizontalScale = v[0] / 100 } }
        on("TL") { scanner, info in if let v = numbers(scanner, 1) { me(info).leading = v[0] } }
        on("Ts") { scanner, info in if let v = numbers(scanner, 1) { me(info).rise = v[0] } }
        on("Td") { scanner, info in if let v = numbers(scanner, 2) { me(info).moveLine(v[0], v[1]) } }
        on("TD") { scanner, info in if let v = numbers(scanner, 2) { me(info).leading = -v[1]; me(info).moveLine(v[0], v[1]) } }
        on("T*") { _, info in let s = me(info); s.moveLine(0, -s.leading) }
        on("Tm") { scanner, info in
            guard let m = numbers(scanner, 6) else { return }
            let s = me(info)
            s.lineMatrix = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
            s.textMatrix = s.lineMatrix
        }
        on("Tj") { scanner, info in
            var string: CGPDFStringRef?
            if CGPDFScannerPopString(scanner, &string), let string { me(info).show(string) }
        }
        on("'") { scanner, info in
            var string: CGPDFStringRef?
            let s = me(info)
            s.moveLine(0, -s.leading)
            if CGPDFScannerPopString(scanner, &string), let string { s.show(string) }
        }
        on("\"") { scanner, info in
            var string: CGPDFStringRef?
            let s = me(info)
            guard CGPDFScannerPopString(scanner, &string), let string, let spacing = numbers(scanner, 2) else { return }
            s.wordSpacing = spacing[0]
            s.charSpacing = spacing[1]
            s.moveLine(0, -s.leading)
            s.show(string)
        }
        on("TJ") { scanner, info in
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            let s = me(info)
            for i in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var number: CGPDFReal = 0
                if CGPDFArrayGetString(array, i, &string), let string {
                    s.show(string)
                } else if CGPDFArrayGetNumber(array, i, &number) {
                    s.advance(-number / 1000 * s.fontSize * s.horizontalScale)
                }
            }
        }

        // Pictures and forms
        on("Do") { scanner, info in if let name = popName(scanner) { me(info).drawObject(name) } }
        on("EI") { _, info in
            let s = me(info)
            s.images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.state.ctm))
        }
        return table
    }()

    // MARK: Text

    private func moveLine(_ x: CGFloat, _ y: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    private func advance(_ distance: CGFloat) {
        textMatrix = CGAffineTransform(translationX: distance, y: 0).concatenating(textMatrix)
    }

    private func show(_ string: CGPDFStringRef) {
        guard let font, let bytes = CGPDFStringGetBytePtr(string) else { return }
        let length = CGPDFStringGetLength(string)
        var codes: [Int] = []
        if font.twoByte {
            for i in stride(from: 0, to: length - 1, by: 2) { codes.append(Int(bytes[i]) << 8 | Int(bytes[i + 1])) }
        } else {
            codes = (0..<length).map { Int(bytes[$0]) }
        }
        let matrix = textMatrix.concatenating(state.ctm)
        let start = CGPoint(x: 0, y: rise).applying(matrix)
        var width: CGFloat = 0
        for code in codes {
            let glyph = (font.widths[code] ?? font.defaultWidth) / 1000 * fontSize
            width += (glyph + charSpacing + (!font.twoByte && code == 32 ? wordSpacing : 0)) * horizontalScale
        }
        let end = CGPoint(x: width, y: rise).applying(matrix)
        let size = fontSize * hypot(matrix.c, matrix.d)
        runs.append(TextRun(start: start, endX: end.x, font: font.name, size: size, color: state.fill))
        advance(width)
    }

    private func lookUpFont(_ name: String) -> Font? {
        let key = "\(resources.count):\(name)"
        if let cached = fonts[key] { return cached }
        var fontsDictionary: CGPDFDictionaryRef?
        var dictionary: CGPDFDictionaryRef?
        guard let current = resources.last,
              CGPDFDictionaryGetDictionary(current, "Font", &fontsDictionary), let fontsDictionary,
              CGPDFDictionaryGetDictionary(fontsDictionary, name, &dictionary), let dictionary else { return nil }

        let baseFont = Self.name(dictionary, "BaseFont") ?? name
        var font = Font(name: baseFont, widths: [:], defaultWidth: 500, twoByte: Self.name(dictionary, "Subtype") == "Type0")
        if font.twoByte {
            // Type 0 fonts keep widths on their descendant: /DW and /W [c [w…] c1 c2 w …].
            var descendants: CGPDFArrayRef?
            var child: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &child), let child {
                var dw: CGPDFReal = 1000
                CGPDFDictionaryGetNumber(child, "DW", &dw)
                font.defaultWidth = dw
                var w: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(child, "W", &w), let w {
                    var i = 0
                    let count = CGPDFArrayGetCount(w)
                    while i < count {
                        var first: CGPDFInteger = 0
                        guard CGPDFArrayGetInteger(w, i, &first) else { break }
                        var list: CGPDFArrayRef?
                        if CGPDFArrayGetArray(w, i + 1, &list), let list {
                            for j in 0..<CGPDFArrayGetCount(list) {
                                var value: CGPDFReal = 0
                                if CGPDFArrayGetNumber(list, j, &value) { font.widths[first + j] = value }
                            }
                            i += 2
                        } else {
                            var last: CGPDFInteger = 0
                            var value: CGPDFReal = 0
                            guard CGPDFArrayGetInteger(w, i + 1, &last), CGPDFArrayGetNumber(w, i + 2, &value) else { break }
                            if last - first < 70_000 { for code in first...max(first, last) { font.widths[code] = value } }
                            i += 3
                        }
                    }
                }
            }
        } else {
            var firstChar: CGPDFInteger = 0
            var widths: CGPDFArrayRef?
            CGPDFDictionaryGetInteger(dictionary, "FirstChar", &firstChar)
            if CGPDFDictionaryGetArray(dictionary, "Widths", &widths), let widths {
                for i in 0..<CGPDFArrayGetCount(widths) {
                    var value: CGPDFReal = 0
                    if CGPDFArrayGetNumber(widths, i, &value) { font.widths[firstChar + i] = value }
                }
            }
            var descriptor: CGPDFDictionaryRef?
            var missing: CGPDFReal = 0
            if CGPDFDictionaryGetDictionary(dictionary, "FontDescriptor", &descriptor), let descriptor,
               CGPDFDictionaryGetNumber(descriptor, "MissingWidth", &missing), missing > 0 {
                font.defaultWidth = missing
            }
        }
        fonts[key] = font
        return font
    }

    // MARK: Paths, pictures, forms

    private func finishPath(fill: Bool, stroke: Bool) {
        for rect in path {
            if fill { shapes.append(Shape(rect: rect, color: state.fill, stroked: false)) }
            if stroke {
                let width = max(state.lineWidth * hypot(state.ctm.a, state.ctm.b), 0.5)
                shapes.append(Shape(rect: rect.insetBy(dx: -width / 2, dy: -width / 2), color: state.stroke, stroked: true))
            }
        }
        path.removeAll()
    }

    private func drawObject(_ name: String) {
        var objects: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        guard let current = resources.last,
              CGPDFDictionaryGetDictionary(current, "XObject", &objects), let objects,
              CGPDFDictionaryGetStream(objects, name, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        switch Self.name(dictionary, "Subtype") {
        case "Image":
            images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm))
        case "Form":
            let outer = state
            var matrix: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                var m = [CGPDFReal](repeating: 0, count: 6)
                for i in 0..<6 { CGPDFArrayGetNumber(matrix, i, &m[i]) }
                state.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(state.ctm)
            }
            var formResources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &formResources)
            if streams.count < 8, let parent = streams.last {
                scan(CGPDFContentStreamCreateWithStream(stream, formResources ?? resources.last!, parent), resources: formResources)
            }
            state = outer
        default:
            break
        }
    }

    private func components(ofSpace name: String?) -> Int {
        switch name {
        case "DeviceGray", "CalGray", "G": return 1
        case "DeviceRGB", "CalRGB", "RGB": return 3
        case "DeviceCMYK", "CMYK": return 4
        default:
            // Named spaces: ICCBased carries N; Separation and Pattern take one tint.
            var spaces: CGPDFDictionaryRef?
            var array: CGPDFArrayRef?
            var stream: CGPDFStreamRef?
            if let name, let current = resources.last, CGPDFDictionaryGetDictionary(current, "ColorSpace", &spaces), let spaces,
               CGPDFDictionaryGetArray(spaces, name, &array), let array, CGPDFArrayGetStream(array, 1, &stream), let stream,
               let info = CGPDFStreamGetDictionary(stream) {
                var n: CGPDFInteger = 3
                CGPDFDictionaryGetInteger(info, "N", &n)
                return n
            }
            return 1
        }
    }

    // MARK: Helpers

    /// The scanner hands callbacks an opaque pointer back to this object.
    private static func me(_ info: UnsafeMutableRawPointer?) -> PDFPageStyles {
        Unmanaged<PDFPageStyles>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values = [CGFloat](repeating: 0, count: count)
        for i in (0..<count).reversed() {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values[i] = value
        }
        return values
    }

    private static func popName(_ scanner: CGPDFScannerRef) -> String? {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { return nil }
        return String(cString: name)
    }

    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    private static func gray(_ v: CGFloat) -> CGColor { CGColor(srgbRed: v, green: v, blue: v, alpha: 1) }
    private static func rgb(_ v: [CGFloat]) -> CGColor { CGColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: 1) }
    private static func cmyk(_ v: [CGFloat]) -> CGColor {
        CGColor(srgbRed: (1 - v[0]) * (1 - v[3]), green: (1 - v[1]) * (1 - v[3]), blue: (1 - v[2]) * (1 - v[3]), alpha: 1)
    }
    private static func color(_ v: [CGFloat]) -> CGColor {
        switch v.count {
        case 3: rgb(v)
        case 4: cmyk(v)
        default: gray(v.first ?? 0)
        }
    }
}
