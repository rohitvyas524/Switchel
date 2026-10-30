import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Entry points for the video and audio tools that need a window.
@MainActor
enum MediaEditors {
    static func compressVideo(_ urls: [URL]) async throws -> [URL] {
        try await ToolWindow.present("Compress Video", size: CGSize(width: 480, height: 420)) { CompressVideoView(urls: urls, session: $0) }
    }

    static func trimVideo(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Trim \(url.lastPathComponent)", size: CGSize(width: 900, height: 640)) { TrimView(url: url, isVideo: true, session: $0) }
    }

    static func splitVideo(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Split \(url.lastPathComponent)", size: CGSize(width: 960, height: 640)) { SplitView(url: url, session: $0) }
    }

    static func cropVideo(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Crop \(url.lastPathComponent)", size: CGSize(width: 960, height: 660)) { VideoCropView(url: url, session: $0) }
    }

    static func gif(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Make GIF", size: CGSize(width: 900, height: 620)) { GIFView(url: url, session: $0) }
    }

    static func normalize(_ urls: [URL]) async throws -> [URL] {
        try await ToolWindow.present("Normalize Volume", size: CGSize(width: 480, height: 360)) { NormalizeView(urls: urls, session: $0) }
    }

    static func speed(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Change Speed", size: CGSize(width: 900, height: 620)) { SpeedView(url: url, session: $0) }
    }

    static func redactVideo(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Redact \(url.lastPathComponent)", size: CGSize(width: 1040, height: 700)) { VideoRedactView(url: url, session: $0) }
    }

    static func snapshots(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Snapshots — \(url.lastPathComponent)", size: CGSize(width: 960, height: 640)) { SnapshotView(url: url, session: $0) }
    }

    static func compressAudio(_ urls: [URL]) async throws -> [URL] {
        try await ToolWindow.present("Compress Audio", size: CGSize(width: 440, height: 300)) { CompressAudioView(urls: urls, session: $0) }
    }

    static func trimAudio(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Trim \(url.lastPathComponent)", size: CGSize(width: 820, height: 380)) { TrimView(url: url, isVideo: false, session: $0) }
    }

    static func channels(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Audio Channels", size: CGSize(width: 460, height: 360)) { ChannelsView(url: url, session: $0) }
    }

    static func bleep(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Bleep \(url.lastPathComponent)", size: CGSize(width: 860, height: 440)) { BleepView(url: url, session: $0) }
    }

    static func visualize(_ url: URL) async throws -> [URL] {
        try await ToolWindow.present("Audio Visualizer", size: CGSize(width: 900, height: 600)) { VisualizerView(url: url, session: $0) }
    }
}

// MARK: Shared pieces

/// Loads the timeline background once.
@MainActor
private final class Strip: ObservableObject {
    @Published var thumbnails: [NSImage] = []
    @Published var waveform: [Float] = []

    init(_ url: URL, video: Bool) {
        Task {
            if video { thumbnails = await TimelineBackground.thumbnails(url) } else { waveform = await TimelineBackground.waveform(url) }
        }
    }
}

private struct TransportBar: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        HStack {
            Button { model.togglePlay() } label: { Image(systemName: "playpause.fill") }
                .keyboardShortcut(.space, modifiers: []).disabled(!model.canPreview)
            Text("\(formatTime(model.time)) / \(formatTime(model.duration))").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

// MARK: Compress video

private struct CompressVideoView: View {
    let urls: [URL]
    @ObservedObject var session: ToolSession
    @State private var options = VideoTools.Compression()
    @State private var useTarget = false
    @State private var megabytes = 25.0

    private let heights = [0, 2160, 1080, 720, 480]

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Compress", sidebarWidth: nil, action: compress) {
            Form {
                Section { LabeledContent("Videos", value: urls.count == 1 ? "\(urls[0].lastPathComponent) · \(fileSize(urls[0]))" : "\(urls.count)") }
                Section("Size") {
                    Picker("Compress by", selection: $useTarget) { Text("Strength").tag(false); Text("Target file size").tag(true) }
                        .pickerStyle(.segmented)
                    if useTarget {
                        HStack { TextField("MB", value: $megabytes, format: .number).frame(width: 80); Text("MB per video").foregroundStyle(.secondary) }
                    } else {
                        Picker("Strength", selection: $options.strength) { ForEach(VideoTools.Compression.Strength.allCases) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented)
                    }
                }
                Section("Output") {
                    Picker("Resolution", selection: Binding(get: { options.maxHeight ?? 0 }, set: { options.maxHeight = $0 == 0 ? nil : $0 })) {
                        ForEach(heights, id: \.self) { Text($0 == 0 ? "Original" : "\($0)p").tag($0) }
                    }
                    Toggle("Remove audio", isOn: $options.removeAudio)
                }
            }
            .formStyle(.grouped)
        } sidebar: { EmptyView() }
    }

    private func compress() {
        var options = options
        options.targetMegabytes = useTarget ? megabytes : nil
        session.run {
            var outputs: [URL] = []
            for url in urls { outputs.append(try await VideoTools.compress(url, options)) }
            return outputs
        }
    }
}

// MARK: Trim (video and audio)

private struct TrimView: View {
    let url: URL
    let isVideo: Bool
    @ObservedObject var session: ToolSession
    @StateObject private var model: PlayerModel
    @StateObject private var strip: Strip
    @State private var range: ClosedRange<Double> = 0...1
    @State private var trimSilence = false
    @State private var threshold = -50.0

    init(url: URL, isVideo: Bool, session: ToolSession) {
        self.url = url
        self.isVideo = isVideo
        self.session = session
        _model = StateObject(wrappedValue: PlayerModel(url))
        _strip = StateObject(wrappedValue: Strip(url, video: isVideo))
    }

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save Trimmed Copy", canRun: model.duration > 0, sidebarWidth: isVideo ? nil : 240, action: save) {
            VStack(spacing: 12) {
                if isVideo { MediaPreview(model: model) }
                Timeline(duration: model.duration, time: model.time, thumbnails: strip.thumbnails, waveform: strip.waveform, seek: model.seek) { x, t in
                    RangeHandles(range: $range, x: x, time: t, onScrub: model.seek)
                }
                HStack {
                    TransportBar(model: model)
                    Spacer()
                    Button("Start at Playhead") { range = min(model.time, range.upperBound - 0.1)...range.upperBound }
                    Button("End at Playhead") { range = range.lowerBound...max(model.time, range.lowerBound + 0.1) }
                    Text("\(formatTime(range.lowerBound)) – \(formatTime(range.upperBound))").monospacedDigit()
                }
            }
            .padding(16)
            .onChange(of: model.duration) { duration in range = 0...max(duration, 0.1) }
        } sidebar: {
            if !isVideo {
                Toggle("Trim silent ends automatically", isOn: $trimSilence)
                if trimSilence {
                    SidebarSection(title: "Silence threshold") {
                        Slider(value: $threshold, in: -70 ... -20) { Text("\(Int(threshold)) dB") }
                        Text("Quieter than this counts as silence.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onDisappear { model.pause() }
    }

    private func save() {
        model.pause()
        let range = range, full = model.duration
        let isFull = range.lowerBound < 0.01 && range.upperBound > full - 0.01
        session.run {
            if isVideo { return [try await VideoTools.trim(url, range)] }
            guard trimSilence else { return [try await AudioTools.trim(url, range)] }
            if isFull { return [try await AudioTools.trimSilence(url, threshold: threshold)] }
            let trimmed = try await AudioTools.trim(url, range)
            let quiet = try await AudioTools.trimSilence(trimmed, threshold: threshold)
            try? FileManager.default.removeItem(at: trimmed)
            return [quiet]
        }
    }
}

// MARK: Split

private struct SplitView: View {
    enum Export: String, CaseIterable, Identifiable {
        case separate, one
        var id: Self { self }
        var title: String { self == .separate ? "Separate Videos" : "One Video" }
    }

    let url: URL
    @ObservedObject var session: ToolSession
    @StateObject private var model: PlayerModel
    @StateObject private var strip: Strip
    @State private var points: [Double] = []
    @State private var removed: Set<Int> = []
    @State private var parts = 2
    @State private var export: Export = .separate

    init(url: URL, session: ToolSession) {
        self.url = url
        self.session = session
        _model = StateObject(wrappedValue: PlayerModel(url))
        _strip = StateObject(wrappedValue: Strip(url, video: true))
    }

    private var segments: [ClosedRange<Double>] {
        let bounds = [0] + points + [model.duration]
        return (0..<(bounds.count - 1)).map { bounds[$0]...bounds[$0 + 1] }
    }

    private var actionTitle: String {
        export == .separate ? "Split into \(segments.count - removed.count) Videos" : "Export One Video"
    }

    var body: some View {
        ToolScaffold(session: session, actionTitle: actionTitle, canRun: !points.isEmpty && removed.count < segments.count, action: save) {
            VStack(spacing: 12) {
                MediaPreview(model: model)
                Timeline(duration: model.duration, time: model.time, thumbnails: strip.thumbnails, seek: model.seek) { x, _ in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            if removed.contains(index) {
                                Color.red.opacity(0.45).frame(width: max(x(segment.upperBound) - x(segment.lowerBound), 1))
                                    .overlay(Image(systemName: "xmark").foregroundStyle(.white))
                                    .offset(x: x(segment.lowerBound)).allowsHitTesting(false)
                            }
                        }
                        ForEach(points, id: \.self) { point in
                            Rectangle().fill(Color.yellow).frame(width: 3).offset(x: x(point) - 1.5).allowsHitTesting(false)
                        }
                    }
                }
                HStack { TransportBar(model: model); Spacer() }
            }
            .padding(16)
        } sidebar: {
            SidebarSection(title: "Export as") {
                Picker("Export as", selection: $export) { ForEach(Export.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                Text(export == .separate ? "Each part becomes its own video." : "Cut out the parts you remove and join the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Split points") {
                Button("Add Split at Playhead") {
                    if model.time > 0.1 && model.time < model.duration - 0.1 && !points.contains(model.time) {
                        points = (points + [model.time]).sorted()
                        removed = []
                    }
                }
                Stepper("\(parts) equal parts", value: $parts, in: 2...20)
                Button("Split Evenly") {
                    points = (1..<parts).map { model.duration * Double($0) / Double(parts) }
                    removed = []
                }
                .disabled(model.duration == 0)
            }
            if !points.isEmpty {
                SidebarSection(title: "Parts") {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        HStack {
                            Toggle("", isOn: Binding(get: { !removed.contains(index) },
                                                     set: { keep in if keep { removed.remove(index) } else { removed.insert(index) } }))
                                .labelsHidden()
                            Button("\(formatTime(segment.lowerBound)) – \(formatTime(segment.upperBound))") { model.seek(segment.lowerBound) }
                                .buttonStyle(.link).monospacedDigit()
                            Spacer()
                            if index > 0 {
                                Button { points.remove(at: index - 1); removed = [] } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Remove the split before this part")
                            }
                        }
                    }
                    Text("Untick a part to leave it out.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear { model.pause() }
    }

    private func save() {
        model.pause()
        let export = export, points = points, removed = removed, segments = segments
        let kept = segments.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        session.run {
            if export == .one { return [try await VideoTools.keep(url, kept)] }
            if removed.isEmpty { return try await VideoTools.split(url, at: points) }
            var outputs: [URL] = []
            for (i, segment) in segments.enumerated() where !removed.contains(i) {
                outputs.append(try await VideoTools.trim(url, segment, suffix: "part \(i + 1)"))
            }
            return outputs
        }
    }
}

// MARK: Speed

private struct SpeedView: View {
    let url: URL
    @ObservedObject var session: ToolSession
    @StateObject private var model: PlayerModel
    @State private var factor = 2.0

    private let factors = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    init(url: URL, session: ToolSession) {
        self.url = url
        self.session = session
        _model = StateObject(wrappedValue: PlayerModel(url))
    }

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save at \(String(format: "%g", factor))×", sidebarWidth: 220, action: save) {
            MediaPreview(model: model).padding(16)
        } sidebar: {
            SidebarSection(title: "Speed") {
                Picker("Speed", selection: $factor) { ForEach(factors, id: \.self) { Text("\(String(format: "%g", $0))×").tag($0) } }
                    .pickerStyle(.radioGroup).labelsHidden()
            }
            Button("Preview at This Speed") { model.player?.rate = Float(factor) }.disabled(!model.canPreview)
            if model.duration > 0 {
                Text("New length \(formatTime(model.duration / factor))").font(.callout).foregroundStyle(.secondary)
            }
        }
        .onDisappear { model.pause() }
    }

    private func save() {
        model.pause()
        let factor = factor
        session.run { [try await VideoTools.changeSpeed(url, by: factor)] }
    }
}

// MARK: Redact video

private struct VideoRedactView: View {
    let url: URL
    @ObservedObject var session: ToolSession
    @StateObject private var model: PlayerModel
    @StateObject private var strip: Strip
    @State private var regions: [VideoTools.Redaction] = []
    @State private var selected: UUID?
    @State private var drawing: CGRect?
    @State private var style: ImageTools.RedactionStyle = .blur
    @State private var frame: NSImage?

    init(url: URL, session: ToolSession) {
        self.url = url
        self.session = session
        _model = StateObject(wrappedValue: PlayerModel(url))
        _strip = StateObject(wrappedValue: Strip(url, video: true))
    }

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save Redacted Copy", canRun: !regions.isEmpty, action: save) {
            VStack(spacing: 12) {
                stage
                Timeline(duration: model.duration, time: model.time, thumbnails: strip.thumbnails, seek: model.seek) { x, _ in
                    ForEach(regions) { region in
                        Rectangle().fill(Color.red.opacity(region.id == selected ? 0.55 : 0.3))
                            .frame(width: max(x(region.end) - x(region.start), 2), height: 10)
                            .offset(x: x(region.start), y: 54).allowsHitTesting(false)
                    }
                }
                HStack { TransportBar(model: model); Spacer(); Text("Pause on a frame and drag over the area to hide.").font(.callout).foregroundStyle(.secondary) }
            }
            .padding(16)
            .onChange(of: model.time) { time in if model.player?.rate == 0 { loadFrame(at: time) } }
            .task { loadFrame(at: 0) }
        } sidebar: {
            SidebarSection(title: "Style") {
                Picker("Style", selection: $style) { ForEach(ImageTools.RedactionStyle.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: "Areas") {
                Button("Add Redaction at Playhead") {
                    let region = VideoTools.Redaction(rect: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3), start: model.time, end: model.duration)
                    regions.append(region)
                    selected = region.id
                }
                if regions.isEmpty { Text("Or pause on a frame and drag over the area to hide.").font(.callout).foregroundStyle(.secondary) }
                ForEach($regions) { $region in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(formatTime(region.start)) – \(formatTime(region.end))").monospacedDigit()
                            Spacer()
                            Button { regions.removeAll { $0.id == region.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        HStack {
                            Button("Start Here") { region.start = min(model.time, region.end) }.controlSize(.small)
                            Button("End Here") { region.end = max(model.time, region.start) }.controlSize(.small)
                            Button("Entire Video") { region.start = 0; region.end = model.duration }.controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(region.id == selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
                    .onTapGesture { selected = region.id }
                }
            }
        }
        .onDisappear { model.pause() }
    }

    @ViewBuilder
    private var stage: some View {
        if let frame {
            ImageStage(image: frame, pixelSize: frame.size) { mapping in
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                            drawing = mapping.toImage(CGRect(origin: value.startLocation, size: CGSize(width: value.translation.width, height: value.translation.height)))
                        }.onEnded { _ in addRegion(drawing, in: frame.size) })
                    ForEach(regions.filter { $0.start <= model.time && model.time <= $0.end }) { region in
                        let rect = mapping.toView(CGRect(x: region.rect.minX * frame.size.width, y: region.rect.minY * frame.size.height,
                                                         width: region.rect.width * frame.size.width, height: region.rect.height * frame.size.height))
                        Rectangle().fill(Color.black.opacity(0.35)).overlay(Rectangle().strokeBorder(region.id == selected ? Color.accentColor : .white, lineWidth: 2))
                            .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                            .onTapGesture { selected = region.id }
                    }
                    if let drawing {
                        let rect = mapping.toView(drawing)
                        Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addRegion(_ rect: CGRect?, in size: CGSize) {
        drawing = nil
        guard let rect, rect.width > 4, rect.height > 4 else { return }
        let normalized = CGRect(x: rect.minX / size.width, y: rect.minY / size.height, width: rect.width / size.width, height: rect.height / size.height)
        let region = VideoTools.Redaction(rect: normalized, start: model.time, end: model.duration)
        regions.append(region)
        selected = region.id
    }

    private func loadFrame(at time: Double) {
        Task {
            if let image = await Self.frame(of: url, at: time) { frame = image }
        }
    }

    static func frame(of url: URL, at time: Double) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        if let (image, _) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) { return NSImage(image) }
        guard let folder = try? Output.temporaryFolder() else { return nil }
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("frame.png")
        try? await FFmpeg.run(["-ss", "\(time)", "-i", url.path, "-frames:v", "1", "-vf", "scale='min(1280,iw)':-2", file.path])
        return NSImage(contentsOf: file)
    }

    private func save() {
        model.pause()
        let regions = regions, style = style
        session.run { [try await VideoTools.redact(url, regions, style: style)] }
    }
}

// MARK: Snapshots

private struct SnapshotView: View {
    let url: URL
    @ObservedObject var session: ToolSession
    @StateObject private var model: PlayerModel
    @StateObject private var strip: Strip
    @State private var times: [Double] = []
    @State private var format: ImageFormat = .png

    init(url: URL, session: ToolSession) {
        self.url = url
        self.session = session
        _model = StateObject(wrappedValue: PlayerModel(url))
        _strip = StateObject(wrappedValue: Strip(url, video: true))
    }

    var body: some View {
        ToolScaffold(session: session, actionTitle: times.count > 1 ? "Save \(times.count) Snapshots" : "Save Snapshot", canRun: !times.isEmpty, action: save) {
            VStack(spacing: 12) {
                MediaPreview(model: model)
                Timeline(duration: model.duration, time: model.time, thumbnails: strip.thumbnails, seek: model.seek) { x, _ in
                    ForEach(times, id: \.self) { time in
                        Circle().fill(Color.yellow).frame(width: 10, height: 10).offset(x: x(time) - 5, y: 4).allowsHitTesting(false)
                    }
                }
                HStack {
                    TransportBar(model: model)
                    Spacer()
                    Button("Add This Frame") { if !times.contains(model.time) { times = (times + [model.time]).sorted() } }
                        .keyboardShortcut("s", modifiers: [])
                }
            }
            .padding(16)
        } sidebar: {
            SidebarSection(title: "Format") {
                Picker("Format", selection: $format) { Text("PNG").tag(ImageFormat.png); Text("JPG").tag(ImageFormat.jpg); Text("HEIC").tag(ImageFormat.heic) }
                    .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: "Frames") {
                if times.isEmpty { Text("Scrub to a frame and press Add This Frame (S).").font(.callout).foregroundStyle(.secondary) }
                ForEach(times, id: \.self) { time in
                    HStack {
                        Button(formatTime(time)) { model.seek(time) }.buttonStyle(.link).monospacedDigit()
                        Spacer()
                        Button { times.removeAll { $0 == time } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .onDisappear { model.pause() }
    }

    private func save() {
        model.pause()
        let times = times, format = format
        session.run { try await VideoTools.snapshots(url, at: times, as: format) }
    }
}

// MARK: Audio

private struct CompressAudioView: View {
    let urls: [URL]
    @ObservedObject var session: ToolSession
    @State private var kbps = 128
    @State private var mono = false

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Compress", sidebarWidth: nil, action: {
            let kbps = kbps, mono = mono
            session.run {
                var outputs: [URL] = []
                for url in urls { outputs.append(try await AudioTools.compress(url, kbps: kbps, mono: mono)) }
                return outputs
            }
        }) {
            Form {
                Picker("Bitrate", selection: $kbps) {
                    ForEach([48, 64, 96, 128, 192, 256], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Toggle("Convert to mono", isOn: $mono)
                Text("Lossless files (WAV, AIFF, FLAC) are saved as M4A.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        } sidebar: { EmptyView() }
    }
}

private struct ChannelsView: View {
    let url: URL
    @ObservedObject var session: ToolSession
    @State private var mode: AudioTools.ChannelMode = .mono
    @State private var left = 1.0
    @State private var right = 1.0

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save", sidebarWidth: nil, action: {
            let mode = mode, left = left, right = right
            session.run { [try await AudioTools.changeChannels(url, mode: mode, left: left, right: right)] }
        }) {
            Form {
                Picker("Output", selection: $mode) { ForEach(AudioTools.ChannelMode.allCases) { Text($0.title).tag($0) } }
                Slider(value: $left, in: 0...2) { Text("Left volume \(Int(left * 100))%") }
                Slider(value: $right, in: 0...2) { Text("Right volume \(Int(right * 100))%") }
            }
            .formStyle(.grouped)
        } sidebar: { EmptyView() }
    }
}

private struct BleepView: View {
    let url: URL
    @ObservedObject var session: ToolSession
    @StateObject private var model: PlayerModel
    @StateObject private var strip: Strip
    @State private var selection: ClosedRange<Double> = 0...1
    @State private var ranges: [ClosedRange<Double>] = []
    @State private var beep = true

    init(url: URL, session: ToolSession) {
        self.url = url
        self.session = session
        _model = StateObject(wrappedValue: PlayerModel(url))
        _strip = StateObject(wrappedValue: Strip(url, video: false))
    }

    var body: some View {
        ToolScaffold(session: session, actionTitle: beep ? "Save Bleeped Copy" : "Save Muted Copy", canRun: !ranges.isEmpty, action: save) {
            VStack(spacing: 12) {
                Timeline(duration: model.duration, time: model.time, waveform: strip.waveform, seek: model.seek) { x, t in
                    ZStack(alignment: .topLeading) {
                        ForEach(ranges, id: \.lowerBound) { range in
                            Rectangle().fill(Color.red.opacity(0.4)).frame(width: max(x(range.upperBound) - x(range.lowerBound), 2))
                                .offset(x: x(range.lowerBound)).allowsHitTesting(false)
                        }
                        RangeHandles(range: $selection, x: x, time: t, onScrub: model.seek)
                    }
                }
                HStack {
                    TransportBar(model: model)
                    Spacer()
                    Text("\(formatTime(selection.lowerBound)) – \(formatTime(selection.upperBound))").monospacedDigit()
                    Button("Add Bleep at Playhead") {
                        ranges.append(model.time...min(model.time + 0.6, model.duration))
                        ranges.sort { $0.lowerBound < $1.lowerBound }
                    }
                    Button("Add Range") { ranges.append(selection); ranges.sort { $0.lowerBound < $1.lowerBound } }
                }
            }
            .padding(16)
            .onChange(of: model.duration) { duration in selection = 0...min(1, max(duration, 0.1)) }
        } sidebar: {
            SidebarSection(title: "Replace with") {
                Picker("Replace with", selection: $beep) { Text("Beep").tag(true); Text("Silence").tag(false) }
                    .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: "Ranges") {
                if ranges.isEmpty { Text("Select a stretch with the yellow handles, then Add Range.").font(.callout).foregroundStyle(.secondary) }
                ForEach(ranges, id: \.lowerBound) { range in
                    HStack {
                        Text("\(formatTime(range.lowerBound)) – \(formatTime(range.upperBound))").monospacedDigit()
                        Spacer()
                        Button { ranges.removeAll { $0 == range } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .onDisappear { model.pause() }
    }

    private func save() {
        model.pause()
        let ranges = ranges, beep = beep
        session.run { [try await AudioTools.bleep(url, ranges: ranges, beep: beep)] }
    }
}

private struct VisualizerView: View {
    let url: URL
    @ObservedObject var session: ToolSession
    @State private var options = AudioTools.Visualization()
    @State private var preset = 0

    private let sizes: [(String, Int, Int)] = [("Landscape 1280×720", 1280, 720), ("Square 1080×1080", 1080, 1080), ("Vertical 1080×1920", 1080, 1920)]

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Create Video", action: {
            let options = options
            session.run { [try await AudioTools.visualize(url, options)] }
        }) {
            preview.padding(24)
        } sidebar: {
            SidebarSection(title: "Style") {
                Picker("Style", selection: $options.style) { ForEach(AudioTools.Visualization.Style.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: "Colour") { ColorRow(color: $options.color) }.disabled(options.style == .spectrum)
            SidebarSection(title: "Background") {
                ColorRow(color: $options.background, presets: [.black, .darkGray, .white, .systemBlue, .systemPurple])
                HStack {
                    Button(options.backgroundImage == nil ? "Use an Image…" : options.backgroundImage!.lastPathComponent, action: chooseImage)
                    if options.backgroundImage != nil {
                        Button { options.backgroundImage = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    }
                }
            }
            SidebarSection(title: "Size") {
                Picker("Size", selection: $preset) { ForEach(sizes.indices, id: \.self) { Text(sizes[$0].0).tag($0) } }
                    .labelsHidden()
                    .onChange(of: preset) { index in options.width = sizes[index].1; options.height = sizes[index].2 }
            }
        }
    }

    /// A static mock-up of the chosen style.
    private var preview: some View {
        ZStack {
            if let image = options.backgroundImage.flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color(nsColor: options.background)
            }
            Canvas { context, size in
                let color = Color(nsColor: options.color)
                let count = 64
                for i in 0..<count {
                    let x = size.width * CGFloat(i) / CGFloat(count)
                    let level = abs(sin(Double(i) * 0.37) * cos(Double(i) * 0.11)) * 0.8 + 0.1
                    let h = size.height * CGFloat(level) * 0.6
                    switch options.style {
                    case .bars:
                        context.fill(Path(CGRect(x: x, y: size.height - h, width: size.width / CGFloat(count) - 2, height: h)), with: .color(color))
                    case .wave, .line:
                        let rect = CGRect(x: x, y: (size.height - h) / 2, width: options.style == .line ? 1.5 : size.width / CGFloat(count) - 1, height: h)
                        context.fill(Path(rect), with: .color(color))
                    case .spectrum:
                        context.fill(Path(CGRect(x: x, y: 0, width: size.width / CGFloat(count), height: size.height)),
                                     with: .color(Color(hue: level, saturation: 0.8, brightness: 0.4 + level / 2)))
                    }
                }
            }
        }
        .aspectRatio(CGFloat(options.width) / CGFloat(options.height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { options.backgroundImage = panel.url }
    }
}

// MARK: Crop video

private struct VideoCropView: View {
    let url: URL
    @ObservedObject var session: ToolSession
    @State private var frame: NSImage?
    /// Normalized 0–1, top-left origin.
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var ratio: CGFloat?
    @State private var dragStart: CGRect?

    private let ratios: [(String, CGFloat?)] = [("Free", nil), ("1:1", 1), ("4:5", 4 / 5), ("16:9", 16 / 9), ("9:16", 9 / 16), ("4:3", 4 / 3)]

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save Cropped Video", canRun: rect != CGRect(x: 0, y: 0, width: 1, height: 1), action: save) {
            if let frame {
                ImageStage(image: frame, pixelSize: frame.size) { mapping in overlay(mapping, size: frame.size) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } sidebar: {
            SidebarSection(title: "Aspect ratio") {
                Picker("Aspect", selection: Binding(get: { ratios.firstIndex { $0.1 == ratio } ?? 0 }, set: { apply(ratios[$0].1) })) {
                    ForEach(ratios.indices, id: \.self) { Text(ratios[$0].0).tag($0) }
                }
                .labelsHidden()
            }
            Text("Drag the box or its corners. The whole video is cropped to this area.").font(.callout).foregroundStyle(.secondary)
            Button("Reset") { rect = CGRect(x: 0, y: 0, width: 1, height: 1); ratio = nil }
        }
        .task { frame = await VideoRedactView.frame(of: url, at: 1) }
    }

    private func overlay(_ mapping: ImageMapping, size: CGSize) -> some View {
        let pixels = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
        let view = mapping.toView(pixels)
        return ZStack(alignment: .topLeading) {
            Path { path in path.addRect(mapping.frame); path.addRect(view) }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            Rectangle().strokeBorder(Color.white, lineWidth: 1.5).background(Color.white.opacity(0.001))
                .frame(width: view.width, height: view.height).offset(x: view.minX, y: view.minY)
                .gesture(DragGesture(coordinateSpace: .named("crop")).onChanged { value in
                    let start = dragStart ?? rect
                    dragStart = start
                    var moved = start.offsetBy(dx: value.translation.width / mapping.frame.width, dy: value.translation.height / mapping.frame.height)
                    moved.origin.x = min(max(moved.minX, 0), 1 - moved.width)
                    moved.origin.y = min(max(moved.minY, 0), 1 - moved.height)
                    rect = moved
                }.onEnded { _ in dragStart = nil })
            ForEach(0..<4, id: \.self) { corner in
                let point = CGPoint(x: corner % 2 == 0 ? view.minX : view.maxX, y: corner < 2 ? view.minY : view.maxY)
                Circle().fill(Color.white).frame(width: 14, height: 14).shadow(radius: 2).offset(x: point.x - 7, y: point.y - 7)
                    .gesture(DragGesture(coordinateSpace: .named("crop")).onChanged { value in
                        let p = mapping.toImage(value.location)
                        resize(corner: corner, to: CGPoint(x: p.x / size.width, y: p.y / size.height), aspect: size.width / size.height)
                    })
            }
        }
        .coordinateSpace(name: "crop")
    }

    private func resize(corner: Int, to point: CGPoint, aspect: CGFloat) {
        let anchor = CGPoint(x: corner % 2 == 0 ? rect.maxX : rect.minX, y: corner < 2 ? rect.maxY : rect.minY)
        let width = max(abs(point.x - anchor.x), 0.05)
        // Ratios are in pixels; convert through the frame's aspect.
        let height = ratio.map { width * aspect / $0 } ?? max(abs(point.y - anchor.y), 0.05)
        rect = CGRect(x: corner % 2 == 0 ? anchor.x - width : anchor.x, y: corner < 2 ? anchor.y - height : anchor.y, width: width, height: height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func apply(_ value: CGFloat?) {
        ratio = value
        guard let value, let size = frame?.size else { return }
        let aspect = size.width / size.height
        var w: CGFloat = 1, h = aspect / value
        if h > 1 { h = 1; w = value / aspect }
        rect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func save() {
        let rect = rect
        session.run { [try await VideoTools.crop(url, to: rect)] }
    }
}

// MARK: GIF

private struct GIFView: View {
    let url: URL
    @ObservedObject var session: ToolSession
    @StateObject private var model: PlayerModel
    @StateObject private var strip: Strip
    @State private var range: ClosedRange<Double> = 0...1
    @State private var fps = 12
    @State private var width = 480

    init(url: URL, session: ToolSession) {
        self.url = url
        self.session = session
        _model = StateObject(wrappedValue: PlayerModel(url))
        _strip = StateObject(wrappedValue: Strip(url, video: true))
    }

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Make GIF", canRun: model.duration > 0, action: save) {
            VStack(spacing: 12) {
                MediaPreview(model: model)
                Timeline(duration: model.duration, time: model.time, thumbnails: strip.thumbnails, seek: model.seek) { x, t in
                    RangeHandles(range: $range, x: x, time: t, onScrub: model.seek)
                }
                HStack {
                    TransportBar(model: model)
                    Spacer()
                    Text("\(formatTime(range.lowerBound)) – \(formatTime(range.upperBound))").monospacedDigit()
                }
            }
            .padding(16)
            .onChange(of: model.duration) { duration in range = 0...min(max(duration, 0.1), 10) }
        } sidebar: {
            SidebarSection(title: "Frame rate") {
                Picker("Frame rate", selection: $fps) { ForEach([8, 10, 12, 15, 20, 24, 30], id: \.self) { Text("\($0) fps").tag($0) } }.labelsHidden()
            }
            SidebarSection(title: "Width") {
                Picker("Width", selection: $width) { ForEach([240, 320, 480, 640, 800, 1080], id: \.self) { Text("\($0) px").tag($0) } }.labelsHidden()
            }
            Text("Shorter clips, lower frame rates and smaller widths make smaller GIFs.").font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { model.pause() }
    }

    private func save() {
        model.pause()
        let options = VideoTools.GIFOptions(fps: fps, width: width, range: range)
        session.run { [try await VideoTools.makeGIF(url, options)] }
    }
}

// MARK: Normalize

private struct NormalizeView: View {
    let urls: [URL]
    @ObservedObject var session: ToolSession
    @State private var target = -16.0
    @State private var range = 11.0
    @State private var truePeak = -1.5

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Normalize", sidebarWidth: nil, action: {
            let target = target, range = range, truePeak = truePeak
            session.run {
                var outputs: [URL] = []
                for url in urls { outputs.append(try await AudioTools.normalize(url, target: target, range: range, truePeak: truePeak)) }
                return outputs
            }
        }) {
            Form {
                Slider(value: $target, in: -30 ... -9, step: 1) { Text("Loudness \(Int(target)) LUFS") }
                Slider(value: $range, in: 1...20, step: 1) { Text("Loudness range \(Int(range)) LU") }
                Slider(value: $truePeak, in: -9 ... 0, step: 0.5) { Text("True peak \(String(format: "%.1f", truePeak)) dBTP") }
                Text("-16 LUFS is a balanced default for spoken audio and music. The true peak limit helps prevent clipping after encoding.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restore Defaults") { target = -16; range = 11; truePeak = -1.5 }
            }
            .formStyle(.grouped)
        } sidebar: { EmptyView() }
    }
}
