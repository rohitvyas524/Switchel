import SwiftUI
import UniformTypeIdentifiers

/// Entry points for the image tools that need a window.
@MainActor
enum ImageEditors {
    static func compress(_ urls: [URL]) async throws -> [URL] {
        try await ToolWindow.present("Compress Images", size: CGSize(width: 480, height: 420)) { CompressImagesView(urls: urls, session: $0) }
    }

    static func crop(_ url: URL) async throws -> [URL] {
        let image = try LoadedImage(url)
        return try await ToolWindow.present("Crop \(url.lastPathComponent)", size: CGSize(width: 960, height: 680)) { CropView(url: url, image: image, session: $0) }
    }

    static func adjust(_ url: URL) async throws -> [URL] {
        let image = try LoadedImage(url, previewSize: 1200)
        return try await ToolWindow.present("Adjust \(url.lastPathComponent)", size: CGSize(width: 1000, height: 680)) { AdjustView(url: url, image: image, session: $0) }
    }

    static func annotate(_ url: URL) async throws -> [URL] {
        let image = try LoadedImage(url)
        return try await ToolWindow.present("Annotate \(url.lastPathComponent)", size: CGSize(width: 1000, height: 700)) { AnnotateView(url: url, image: image, session: $0) }
    }

    static func redact(_ url: URL) async throws -> [URL] {
        let image = try LoadedImage(url)
        return try await ToolWindow.present("Redact \(url.lastPathComponent)", size: CGSize(width: 1000, height: 700)) { RedactPhotoView(url: url, image: image, session: $0) }
    }

    static func background(_ url: URL) async throws -> [URL] {
        let image = try LoadedImage(url)
        return try await ToolWindow.present("Background — \(url.lastPathComponent)", size: CGSize(width: 960, height: 680)) { BackgroundView(url: url, image: image, session: $0) }
    }

    static func frame(_ url: URL) async throws -> [URL] {
        let image = try LoadedImage(url, previewSize: 1000)
        return try await ToolWindow.present("Frame \(url.lastPathComponent)", size: CGSize(width: 960, height: 680)) { FrameView(url: url, image: image, session: $0) }
    }

    static func metadata(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Metadata — \(url.lastPathComponent)", size: CGSize(width: 860, height: 600)) { MetadataView(url: url, session: $0) }
    }

    static func collage(_ urls: [URL]) async throws -> [URL] {
        let previews = try urls.map { try ImageConverter.load($0, maxPixelSize: 600) }
        return try await ToolWindow.present("Collage", size: CGSize(width: 960, height: 680)) { CollageView(urls: urls, previews: previews, session: $0) }
    }

    static func icon(_ url: URL) async throws -> [URL] {
        let image = try LoadedImage(url, previewSize: 1024)
        return try await ToolWindow.present("Make Icon", size: CGSize(width: 760, height: 560)) { IconView(url: url, image: image, session: $0) }
    }

    static func qrCodes(_ urls: [URL]) async throws -> [URL] {
        let codes = try await Task.detached { try urls.flatMap { url in try ImageTools.readCodes(url).map { (url, $0) } } }.value
        guard !codes.isEmpty else { throw SwitchelError("No QR codes or barcodes found") }
        return try await ToolWindow.present("Codes Found", size: CGSize(width: 560, height: 380)) { session in
            QRResultsView(codes: codes.map { QRResultsView.Code(file: $0.0.lastPathComponent, value: $0.1) }, session: session)
        }
    }
}

// MARK: Compress

private struct CompressImagesView: View {
    let urls: [URL]
    @ObservedObject var session: ToolSession
    @State private var useTarget = false
    @State private var quality = 0.7
    @State private var target = 500.0
    @State private var megabytes = false
    @State private var maxDimension = 2560
    @State private var format: ImageFormat?

    private let dimensions = [0, 4096, 2560, 1920, 1280, 800]

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Compress", sidebarWidth: nil, action: compress) {
            Form {
                Section {
                    LabeledContent("Images", value: "\(urls.count) · \(urls.count == 1 ? fileSize(urls[0]) : "")")
                }
                Section("Size") {
                    Picker("Compress by", selection: $useTarget) {
                        Text("Quality").tag(false)
                        Text("Target file size").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if useTarget {
                        HStack {
                            TextField("Target", value: $target, format: .number).frame(width: 90)
                            Picker("", selection: $megabytes) { Text("KB").tag(false); Text("MB").tag(true) }.labelsHidden().frame(width: 80)
                            Text("per image").foregroundStyle(.secondary)
                        }
                    } else {
                        Slider(value: $quality, in: 0.1...0.95) { Text("Quality \(Int(quality * 100))%") }
                    }
                }
                Section("Output") {
                    Picker("Largest side", selection: $maxDimension) {
                        ForEach(dimensions, id: \.self) { Text($0 == 0 ? "Original" : "\($0) px").tag($0) }
                    }
                    Picker("Format", selection: $format) {
                        Text("Automatic (JPG, or HEIC with transparency)").tag(ImageFormat?.none)
                        ForEach([ImageFormat.jpg, .heic, .webp, .avif, .png], id: \.self) { Text($0.rawValue.uppercased()).tag(Optional($0)) }
                    }
                }
            }
            .formStyle(.grouped)
        } sidebar: { EmptyView() }
    }

    private func compress() {
        let bytes = Int(target * (megabytes ? 1_000_000 : 1000))
        let options = ImageTools.Compression(target: useTarget ? .maxBytes(bytes) : .quality(quality),
                                             maxDimension: maxDimension == 0 ? nil : maxDimension, format: format)
        session.run {
            var outputs: [URL] = []
            for url in urls { outputs.append(try await ImageTools.compress(url, options)) }
            return outputs
        }
    }
}

// MARK: Crop

private struct CropView: View {
    let url: URL
    let image: LoadedImage
    @ObservedObject var session: ToolSession
    @State private var rect: CGRect
    @State private var ratio: CGFloat?
    @State private var dragStart: CGRect?

    private let ratios: [(String, CGFloat?)] = [("Free", nil), ("1:1", 1), ("4:3", 4 / 3), ("3:2", 3 / 2), ("16:9", 16 / 9), ("9:16", 9 / 16)]

    init(url: URL, image: LoadedImage, session: ToolSession) {
        self.url = url
        self.image = image
        self.session = session
        _rect = State(initialValue: CGRect(origin: .zero, size: image.pixelSize))
    }

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save Cropped Copy", action: save) {
            ImageStage(image: image.nsImage, pixelSize: image.pixelSize) { mapping in overlay(mapping) }
        } sidebar: {
            SidebarSection(title: "Aspect ratio") {
                Picker("Aspect", selection: Binding(get: { ratios.firstIndex { $0.1 == ratio } ?? 0 }, set: { applyRatio(ratios[$0].1) })) {
                    ForEach(ratios.indices, id: \.self) { Text(ratios[$0].0).tag($0) }
                }
                .labelsHidden()
            }
            SidebarSection(title: "Size in pixels") {
                HStack {
                    TextField("Width", value: Binding(get: { Int(rect.width) }, set: { rect.size.width = CGFloat(min(max($0, 1), Int(image.pixelSize.width - rect.minX))) }), format: .number)
                    Text("×")
                    TextField("Height", value: Binding(get: { Int(rect.height) }, set: { rect.size.height = CGFloat(min(max($0, 1), Int(image.pixelSize.height - rect.minY))) }), format: .number)
                }
                Text("Original \(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height))").font(.caption).foregroundStyle(.secondary)
            }
            Button("Reset") { rect = CGRect(origin: .zero, size: image.pixelSize); ratio = nil }
        }
    }

    private func overlay(_ mapping: ImageMapping) -> some View {
        let view = mapping.toView(rect)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(mapping.frame)
                path.addRect(view)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: view.width, height: view.height)
                .offset(x: view.minX, y: view.minY)
                .gesture(DragGesture(coordinateSpace: .named("stage")).onChanged { value in
                    let start = dragStart ?? rect
                    dragStart = start
                    var moved = start.offsetBy(dx: value.translation.width / mapping.scale, dy: value.translation.height / mapping.scale)
                    moved.origin.x = min(max(moved.minX, 0), image.pixelSize.width - moved.width)
                    moved.origin.y = min(max(moved.minY, 0), image.pixelSize.height - moved.height)
                    rect = moved
                }.onEnded { _ in dragStart = nil })
            ForEach(0..<4, id: \.self) { corner in
                let point = CGPoint(x: corner % 2 == 0 ? view.minX : view.maxX, y: corner < 2 ? view.minY : view.maxY)
                Circle().fill(Color.white).frame(width: 14, height: 14).shadow(radius: 2)
                    .offset(x: point.x - 7, y: point.y - 7)
                    .gesture(DragGesture(coordinateSpace: .named("stage")).onChanged { value in
                        resize(corner: corner, to: mapping.toImage(value.location))
                    })
            }
        }
        .coordinateSpace(name: "stage")
    }

    private func resize(corner: Int, to point: CGPoint) {
        // The opposite corner stays put.
        let anchor = CGPoint(x: corner % 2 == 0 ? rect.maxX : rect.minX, y: corner < 2 ? rect.maxY : rect.minY)
        var width = max(abs(point.x - anchor.x), 8), height = max(abs(point.y - anchor.y), 8)
        if let ratio { height = width / ratio }
        if anchor.y + (corner < 2 ? -height : height) < 0 || anchor.y + (corner < 2 ? -height : height) > image.pixelSize.height {
            height = corner < 2 ? anchor.y : image.pixelSize.height - anchor.y
            if let ratio { width = height * ratio }
        }
        rect = CGRect(x: corner % 2 == 0 ? anchor.x - width : anchor.x, y: corner < 2 ? anchor.y - height : anchor.y, width: width, height: height)
            .intersection(CGRect(origin: .zero, size: image.pixelSize))
    }

    private func applyRatio(_ value: CGFloat?) {
        ratio = value
        guard let value else { return }
        var size = image.pixelSize
        if size.width / size.height > value { size.width = size.height * value } else { size.height = size.width / value }
        rect = CGRect(x: (image.pixelSize.width - size.width) / 2, y: (image.pixelSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func save() {
        let rect = rect
        session.run { [try await ImageTools.crop(url, to: rect)] }
    }
}

// MARK: Adjust

private struct AdjustView: View {
    let url: URL
    let image: LoadedImage
    @ObservedObject var session: ToolSession
    @State private var adjustments = ImageTools.Adjustments()
    @State private var showOriginal = false

    var body: some View {
        let preview = showOriginal || adjustments.isIdentity ? image.nsImage
            : (try? ImageTools.adjust(image.preview, adjustments)).map { NSImage($0) } ?? image.nsImage
        return ToolScaffold(session: session, actionTitle: "Save Adjusted Copy", canRun: !adjustments.isIdentity, action: save) {
            ImageStage(image: preview, pixelSize: image.pixelSize) { _ in EmptyView() }
                .overlay(alignment: .bottom) {
                    Text("Hold to compare").font(.caption).padding(6).background(.regularMaterial, in: Capsule()).padding(10)
                        .onLongPressGesture(minimumDuration: 0, pressing: { showOriginal = $0 }, perform: {})
                }
        } sidebar: {
            slider("Exposure", $adjustments.exposure, -2...2)
            slider("Brightness", $adjustments.brightness, -0.5...0.5)
            slider("Contrast", $adjustments.contrast, 0.5...1.5)
            slider("Saturation", $adjustments.saturation, 0...2)
            slider("Warmth", $adjustments.warmth, -1...1)
            slider("Highlights", $adjustments.highlights, 0...1)
            slider("Shadows", $adjustments.shadows, 0...1)
            slider("Sharpness", $adjustments.sharpness, 0...2)
            Button("Reset") { adjustments = ImageTools.Adjustments() }.disabled(adjustments.isIdentity)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        SidebarSection(title: title) { Slider(value: value, in: range) }
    }

    private func save() {
        let adjustments = adjustments
        session.run { [try await ImageTools.saveCopy(try ImageTools.adjust(image.full, adjustments), of: url, suffix: "adjusted")] }
    }
}

// MARK: Annotate

private struct AnnotateView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, highlighter, arrow, rectangle, ellipse, text
        var id: Self { self }
        var symbol: String {
            switch self {
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .text: "textformat"
            }
        }
    }

    let url: URL
    let image: LoadedImage
    @ObservedObject var session: ToolSession
    @State private var marks: [ImageTools.Mark] = []
    @State private var current: ImageTools.Mark?
    @State private var tool: Tool = .arrow
    @State private var color: NSColor = .systemRed
    @State private var width: CGFloat
    @State private var text = "Text"

    init(url: URL, image: LoadedImage, session: ToolSession) {
        self.url = url
        self.image = image
        self.session = session
        _width = State(initialValue: max(3, max(image.pixelSize.width, image.pixelSize.height) / 250))
    }

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save Annotated Copy", canRun: !marks.isEmpty, action: save) {
            ImageStage(image: image.nsImage, pixelSize: image.pixelSize) { mapping in
                Canvas { context, _ in
                    for mark in marks + [current].compactMap({ $0 }) { draw(mark, in: &context, mapping: mapping) }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { update(mapping.toImage($0.startLocation), mapping.toImage($0.location)) }
                    .onEnded { _ in if let current { marks.append(current) }; current = nil })
            }
        } sidebar: {
            SidebarSection(title: "Tool") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                    ForEach(Tool.allCases) { option in
                        Button { tool = option } label: {
                            Image(systemName: option.symbol).frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.bordered)
                        .tint(tool == option ? .accentColor : nil)
                        .help(option.rawValue.capitalized)
                    }
                }
                if tool == .text { TextField("Text", text: $text) }
            }
            SidebarSection(title: "Colour") { ColorRow(color: $color) }
            SidebarSection(title: "Thickness") {
                Slider(value: $width, in: 1...max(40, image.pixelSize.width / 60))
            }
            HStack {
                Button("Undo") { _ = marks.popLast() }.keyboardShortcut("z").disabled(marks.isEmpty)
                Button("Clear") { marks.removeAll() }.disabled(marks.isEmpty)
            }
        }
    }

    private func update(_ start: CGPoint, _ point: CGPoint) {
        let shape: ImageTools.Mark.Shape
        switch tool {
        case .pen, .highlighter:
            var points: [CGPoint] = []
            if case .pen(let existing) = current?.shape { points = existing }
            if case .highlighter(let existing) = current?.shape { points = existing }
            points.append(point)
            shape = tool == .pen ? .pen(points) : .highlighter(points)
        case .arrow: shape = .arrow(start, point)
        case .rectangle: shape = .rectangle(CGRect(x: start.x, y: start.y, width: point.x - start.x, height: point.y - start.y))
        case .ellipse: shape = .ellipse(CGRect(x: start.x, y: start.y, width: point.x - start.x, height: point.y - start.y))
        case .text: shape = .text(text, point)
        }
        if current == nil {
            current = ImageTools.Mark(shape: shape, color: color, lineWidth: width)
        } else {
            current?.shape = shape
        }
    }

    private func draw(_ mark: ImageTools.Mark, in context: inout GraphicsContext, mapping: ImageMapping) {
        let color = Color(nsColor: mark.color)
        let lineWidth = mark.lineWidth * mapping.scale
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        func polyline(_ points: [CGPoint]) -> Path {
            Path { path in path.addLines(points.map(mapping.toView)) }
        }
        switch mark.shape {
        case .pen(let points):
            context.stroke(polyline(points), with: .color(color), style: style)
        case .highlighter(let points):
            context.stroke(polyline(points), with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: lineWidth * 4, lineCap: .round, lineJoin: .round))
        case .arrow(let from, let to):
            let a = mapping.toView(from), b = mapping.toView(to)
            let angle = atan2(b.y - a.y, b.x - a.x), head = max(lineWidth * 4, 12 * mapping.scale)
            context.stroke(Path { $0.move(to: a); $0.addLine(to: CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)) }, with: .color(color), style: style)
            context.fill(Path { path in
                path.move(to: b)
                path.addLine(to: CGPoint(x: b.x - cos(angle - .pi / 7) * head, y: b.y - sin(angle - .pi / 7) * head))
                path.addLine(to: CGPoint(x: b.x - cos(angle + .pi / 7) * head, y: b.y - sin(angle + .pi / 7) * head))
                path.closeSubpath()
            }, with: .color(color))
        case .rectangle(let rect):
            context.stroke(Path(mapping.toView(rect.standardized)), with: .color(color), style: style)
        case .ellipse(let rect):
            context.stroke(Path(ellipseIn: mapping.toView(rect.standardized)), with: .color(color), style: style)
        case .text(let string, let point):
            context.draw(Text(string).font(.system(size: mark.lineWidth * 6 * mapping.scale, weight: .semibold)).foregroundColor(color),
                         at: mapping.toView(point), anchor: .topLeading)
        }
    }

    private func save() {
        let marks = marks
        session.run {
            let annotated = try ImageTools.annotate(image.full, with: marks)
            return [try await ImageTools.saveCopy(annotated, of: url, suffix: "annotated")]
        }
    }
}

// MARK: Redact

private struct RedactPhotoView: View {
    let url: URL
    let image: LoadedImage
    @ObservedObject var session: ToolSession
    @State private var regions: [CGRect] = []
    @State private var drawing: CGRect?
    @State private var selected: Int?
    @State private var style: ImageTools.RedactionStyle = .blur
    @State private var preview: NSImage?
    @State private var detecting = false

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save Redacted Copy", canRun: !regions.isEmpty, action: save) {
            ImageStage(image: preview ?? image.nsImage, pixelSize: image.pixelSize) { mapping in
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                            drawing = mapping.toImage(CGRect(origin: value.startLocation, size: CGSize(width: value.translation.width, height: value.translation.height)))
                        }.onEnded { _ in
                            if let drawing, drawing.width > 4, drawing.height > 4 { regions.append(drawing); selected = regions.count - 1 }
                            drawing = nil
                        })
                    ForEach(regions.indices, id: \.self) { i in
                        let rect = mapping.toView(regions[i])
                        Rectangle().strokeBorder(i == selected ? Color.accentColor : Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: i == selected ? [] : [5]))
                            .background(Color.white.opacity(0.001))
                            .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                            .onTapGesture { selected = i }
                    }
                    if let drawing {
                        let rect = mapping.toView(drawing)
                        Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            .onChange(of: regions) { _ in renderPreview() }
            .onChange(of: style) { _ in renderPreview() }
        } sidebar: {
            SidebarSection(title: "Style") {
                Picker("Style", selection: $style) { ForEach(ImageTools.RedactionStyle.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: "Find automatically") {
                HStack {
                    Button("Faces") { detect(faces: true, text: false) }
                    Button("Text") { detect(faces: false, text: true) }
                    if detecting { ProgressView().controlSize(.small) }
                }
            }
            SidebarSection(title: "Areas") {
                Text(regions.isEmpty ? "Drag over the picture to cover an area." : "\(regions.count) area\(regions.count == 1 ? "" : "s"). Click one to select it.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Delete Selected") { if let selected { regions.remove(at: selected); self.selected = nil } }
                        .keyboardShortcut(.delete, modifiers: []).disabled(selected == nil)
                    Button("Clear") { regions.removeAll(); selected = nil }.disabled(regions.isEmpty)
                }
            }
        }
    }

    private func renderPreview() {
        let scale = image.previewScale
        let scaled = regions.map { CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale) }
        preview = (try? ImageTools.redact(image.preview, regions: scaled, style: style)).map { NSImage($0) }
    }

    private func detect(faces: Bool, text: Bool) {
        detecting = true
        let full = image.full
        Task {
            let found = (try? await Task.detached { try ImageTools.detectSensitiveRegions(in: full, faces: faces, text: text) }.value) ?? []
            detecting = false
            if found.isEmpty { session.error = "Nothing found" } else { session.error = nil; regions += found }
        }
    }

    private func save() {
        let regions = regions, style = style
        session.run {
            let redacted = try ImageTools.redact(image.full, regions: regions, style: style)
            return [try await ImageTools.saveCopy(redacted, of: url, suffix: "redacted")]
        }
    }
}

// MARK: Background

private struct BackgroundView: View {
    enum Choice: String, CaseIterable, Identifiable {
        case transparent, color, blur, image
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    let url: URL
    let image: LoadedImage
    @ObservedObject var session: ToolSession
    @State private var subject: ImageTools.Subject?
    @State private var choice: Choice = .transparent
    @State private var color: NSColor = .white
    @State private var backdropImage: CGImage?
    @State private var blur: CGFloat = 0.5
    @State private var preview: NSImage?
    @State private var failure: String?

    var body: some View {
        ToolScaffold(session: session, actionTitle: choice == .transparent ? "Save Cut-out" : "Save with Background", canRun: subject != nil, action: save) {
            ZStack {
                ImageStage(image: preview ?? image.nsImage, pixelSize: image.pixelSize) { _ in EmptyView() }
                if subject == nil {
                    VStack(spacing: 8) {
                        if let failure { Text(failure).foregroundStyle(.red) } else { ProgressView("Finding the subject…") }
                    }
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task { await findSubject() }
            .onChange(of: choice) { _ in renderPreview() }
            .onChange(of: color) { _ in renderPreview() }
            .onChange(of: blur) { _ in renderPreview() }
        } sidebar: {
            SidebarSection(title: "Background") {
                Picker("Background", selection: $choice) { ForEach(Choice.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                switch choice {
                case .transparent: Text("Saved as PNG with transparency.").font(.callout).foregroundStyle(.secondary)
                case .color: ColorRow(color: $color)
                case .blur:
                    Slider(value: $blur, in: 0.1...1) { Text("Blur") }
                    Text("Keeps the photo's own background, blurred like a portrait shot.").font(.callout).foregroundStyle(.secondary)
                case .image: Button(backdropImage == nil ? "Choose Image…" : "Change Image…", action: chooseImage)
                }
            }
        }
    }

    private func findSubject() async {
        let preview = image.preview
        do {
            subject = try await Task.detached { try ImageTools.subject(of: preview) }.value
            renderPreview()
        } catch {
            failure = error.localizedDescription
        }
    }

    private var backdrop: ImageTools.Backdrop {
        switch choice {
        case .transparent: .transparent
        case .color: .color(color)
        case .blur: .blur(blur)
        case .image: backdropImage.map { .image($0) } ?? .transparent
        }
    }

    private func renderPreview() {
        guard let subject else { return }
        preview = (try? ImageTools.composite(subject, over: backdrop)).map { NSImage($0) }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let loaded = try? ImageConverter.load(url, maxPixelSize: 4096) else { return }
        backdropImage = loaded
        renderPreview()
    }

    private func save() {
        let backdrop = backdrop, full = image.full, transparent = choice == .transparent
        session.run {
            let subject = try await Task.detached { try ImageTools.subject(of: full) }.value
            let result = try ImageTools.composite(subject, over: backdrop)
            return [try await ImageTools.saveCopy(result, of: url, suffix: transparent ? "cutout" : "new background", forceTransparency: transparent)]
        }
    }
}

// MARK: Frame

private struct FrameView: View {
    let url: URL
    let image: LoadedImage
    @ObservedObject var session: ToolSession
    @State private var options = ImageTools.FrameOptions()

    var body: some View {
        let rendered = (try? ImageTools.frame(image.preview, previewOptions)).map { NSImage($0) } ?? image.nsImage
        return ToolScaffold(session: session, actionTitle: "Save Framed Copy", action: save) {
            ImageStage(image: rendered, pixelSize: rendered.size) { _ in EmptyView() }
        } sidebar: {
            SidebarSection(title: "Background") {
                HStack(spacing: 8) {
                    ForEach(ImageTools.framePresets.indices, id: \.self) { i in
                        let preset = ImageTools.framePresets[i]
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: preset.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 30, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(options.colors == preset ? 0.9 : 0.1), lineWidth: 2))
                            .onTapGesture { options.colors = preset }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(ImageTools.solidPresets, id: \.self) { solid in
                        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: solid)).frame(width: 30, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(options.colors == [solid, solid] ? 0.9 : 0.15), lineWidth: 2))
                            .onTapGesture { options.colors = [solid, solid] }
                    }
                }
                HStack {
                    ColorPicker("From", selection: colorBinding(0))
                    ColorPicker("To", selection: colorBinding(1))
                }
            }
            SidebarSection(title: "Spacing") { Slider(value: $options.padding, in: 0...0.3) }
            SidebarSection(title: "Corners") { Slider(value: $options.cornerRadius, in: 0...0.08) }
            SidebarSection(title: "Tilt") {
                HStack {
                    Slider(value: $options.rotation, in: -15...15)
                    Text("\(Int(options.rotation))°").monospacedDigit().frame(width: 34)
                }
            }
            Toggle("Shadow", isOn: $options.shadow)
            SidebarSection(title: "Canvas") {
                Picker("Canvas", selection: $options.ratio) { ForEach(ImageTools.FrameOptions.Ratio.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
        }
    }

    /// Same proportions as the full render, so the preview is faithful.
    private var previewOptions: ImageTools.FrameOptions { options }

    private func colorBinding(_ index: Int) -> Binding<Color> {
        Binding(get: { Color(nsColor: options.colors[index]) }, set: { options.colors[index] = NSColor($0) })
    }

    private func save() {
        let options = options
        session.run { [try await ImageTools.saveCopy(try ImageTools.frame(image.full, options), of: url, suffix: "framed")] }
    }
}

// MARK: Metadata

private struct MetadataView: View {
    let url: URL
    @ObservedObject var session: ToolSession
    private let entries: [ImageTools.MetadataEntry]
    private let original: (description: String, artist: String, copyright: String, date: Date?)
    @State private var details: String
    @State private var artist: String
    @State private var copyright: String
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var removeLocation = false
    @State private var removeAll = false

    init(url: URL, session: ToolSession) {
        self.url = url
        self.session = session
        let entries = ImageTools.metadata(of: url)
        self.entries = entries
        func value(_ group: String, _ key: String) -> String { entries.first { $0.group == group && $0.key == key }?.value ?? "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let taken = formatter.date(from: value("Exif", "DateTimeOriginal"))
        original = (value("TIFF", "ImageDescription"), value("TIFF", "Artist"), value("TIFF", "Copyright"), taken)
        _details = State(initialValue: original.description)
        _artist = State(initialValue: original.artist)
        _copyright = State(initialValue: original.copyright)
        _hasDate = State(initialValue: taken != nil)
        _date = State(initialValue: taken ?? Date())
    }

    private var hasLocation: Bool { entries.contains { $0.group == "GPS" } }

    var body: some View {
        ToolScaffold(session: session, actionTitle: removeAll ? "Save Clean Copy" : "Save Edited Copy", sidebarWidth: 300, action: save) {
            List {
                ForEach(Array(Set(entries.map(\.group))).sorted(), id: \.self) { group in
                    Section(group) {
                        ForEach(entries.filter { $0.group == group }) { entry in
                            LabeledContent(entry.key) { Text(entry.value).textSelection(.enabled).lineLimit(3) }
                        }
                    }
                }
            }
        } sidebar: {
            SidebarSection(title: "Edit") {
                TextField("Description", text: $details)
                TextField("Artist", text: $artist)
                TextField("Copyright", text: $copyright)
                Toggle("Date taken", isOn: $hasDate)
                if hasDate { DatePicker("", selection: $date).labelsHidden() }
            }
            .disabled(removeAll)
            SidebarSection(title: "Privacy") {
                Toggle("Remove location", isOn: $removeLocation).disabled(!hasLocation || removeAll)
                if !hasLocation { Text("This image has no location data.").font(.caption).foregroundStyle(.secondary) }
                Toggle("Remove all metadata", isOn: $removeAll)
                Text("Pixels are copied as-is, so there's no quality loss.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        var changes = ImageTools.MetadataChanges(removeLocation: removeLocation, removeAll: removeAll)
        if !removeAll {
            if details != original.description { changes.description = details }
            if artist != original.artist { changes.artist = artist }
            if copyright != original.copyright { changes.copyright = copyright }
            if hasDate && date != original.date { changes.dateTaken = date }
        }
        session.run { [try await ImageTools.editMetadata(url, changes)] }
    }
}

// MARK: Collage

private struct CollageView: View {
    let urls: [URL]
    let previews: [CGImage]
    @ObservedObject var session: ToolSession
    @State private var options = ImageTools.CollageOptions()

    var body: some View {
        var previewOptions = options
        previewOptions.width = 1200
        let rendered = (try? ImageTools.collage(previews, previewOptions)).map { NSImage($0) } ?? NSImage()
        return ToolScaffold(session: session, actionTitle: "Save Collage", action: save) {
            ImageStage(image: rendered, pixelSize: rendered.size) { _ in EmptyView() }
        } sidebar: {
            SidebarSection(title: "Columns") {
                Stepper(options.columns == 0 ? "Automatic" : "\(options.columns) per row", value: $options.columns, in: 0...8)
            }
            SidebarSection(title: "Spacing") { Slider(value: $options.spacing, in: 0...0.05) }
            SidebarSection(title: "Corners") { Slider(value: $options.cornerRadius, in: 0...0.04) }
            SidebarSection(title: "Background") { ColorRow(color: $options.background) }
            Text("\(urls.count) images, in the order you dragged them.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let options = options
        session.run {
            let images = try await Task.detached { try urls.map { try ImageConverter.load($0, maxPixelSize: 1800) } }.value
            let collage = try ImageTools.collage(images, options)
            let out = Output.url(for: urls[0], ext: "jpg", suffix: "collage")
            try ImageConverter.write(collage, to: out, type: .jpeg, quality: 0.92)
            return [out]
        }
    }
}

// MARK: Icon

private struct IconView: View {
    let url: URL
    let image: LoadedImage
    @ObservedObject var session: ToolSession
    @State private var options = ImageTools.IconOptions()

    var body: some View {
        let rendered = (try? ImageTools.icon(image.preview, options)).map { NSImage($0) } ?? NSImage()
        return ToolScaffold(session: session, actionTitle: "Save Icon", action: save) {
            ImageStage(image: rendered, pixelSize: rendered.size) { _ in EmptyView() }
        } sidebar: {
            SidebarSection(title: "Shape") {
                Picker("Shape", selection: $options.shape) { ForEach(ImageTools.IconOptions.Shape.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: "Padding") { Slider(value: $options.padding, in: 0...0.3) }
            SidebarSection(title: "Background") { ColorRow(color: $options.background) }
            Text("Saves an .icns with every size from 16 to 1024 px, plus a 1024 px PNG.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let options = options
        session.run {
            let master = try ImageTools.icon(image.full, options)
            let icns = Output.url(for: url, ext: "icns", suffix: "icon")
            try ImageTools.writeICNS(master, to: icns)
            let png = Output.url(for: url, ext: "png", suffix: "icon")
            try ImageConverter.write(master, to: png, type: .png)
            return [icns, png]
        }
    }
}

// MARK: QR codes

private struct QRResultsView: View {
    struct Code: Identifiable {
        let id = UUID()
        let file: String
        let value: String
    }

    let codes: [Code]
    @ObservedObject var session: ToolSession

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Done", sidebarWidth: nil, action: { session.run { [] } }) {
            List(codes) { code in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(code.value).textSelection(.enabled).lineLimit(4)
                        Text(code.file).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.value, forType: .string)
                    }
                    if let link = URL(string: code.value), link.scheme?.hasPrefix("http") == true {
                        Button("Open") { NSWorkspace.shared.open(link) }
                    }
                }
                .padding(.vertical, 4)
            }
        } sidebar: { EmptyView() }
    }
}
