import AVFoundation
import AVKit
import SwiftUI

// MARK: Tool windows

/// Drives one editor window: Save runs the work, Cancel or closing the window cancels.
@MainActor
final class ToolSession: ObservableObject {
    @Published var isWorking = false
    @Published var error: String?
    fileprivate var completion: ((Result<[URL], Error>) -> Void)?

    func run(_ work: @escaping @MainActor () async throws -> [URL]) {
        isWorking = true
        error = nil
        Task { @MainActor in
            do {
                finish(.success(try await work()))
            } catch {
                isWorking = false
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    fileprivate func finish(_ result: Result<[URL], Error>) {
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}

@MainActor
enum ToolWindow {
    private final class CloseObserver: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }

    /// Shows `content` in a window and returns the files it saved.
    static func present<Content: View>(_ title: String, size: CGSize, @ViewBuilder content: (ToolSession) -> Content) async throws -> [URL] {
        let session = ToolSession()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content(session).frame(minWidth: size.width * 0.7, minHeight: size.height * 0.7))
        window.setContentSize(size)
        window.center()
        let observer = CloseObserver { session.cancel() }
        window.delegate = observer
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return try await withCheckedThrowingContinuation { continuation in
            session.completion = { result in
                window.delegate = nil
                window.orderOut(nil)
                _ = observer
                continuation.resume(with: result)
            }
        }
    }
}

/// Standard editor layout: main area, optional sidebar, and a bottom bar with Cancel and the action.
struct ToolScaffold<Main: View, Sidebar: View>: View {
    @ObservedObject var session: ToolSession
    var actionTitle = "Save Copy"
    var canRun = true
    var sidebarWidth: CGFloat? = 270
    var action: () -> Void
    @ViewBuilder var main: Main
    @ViewBuilder var sidebar: Sidebar

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                main.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let sidebarWidth {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) { sidebar }.padding(16)
                    }
                    .frame(width: sidebarWidth)
                }
            }
            Divider()
            HStack(spacing: 10) {
                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                if session.isWorking { ProgressView().controlSize(.small) }
                Button("Cancel") { session.cancel() }.keyboardShortcut(.cancelAction)
                Button(actionTitle, action: action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun || session.isWorking)
            }
            .padding(12)
        }
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content
        }
    }
}

// MARK: Images

/// Maps between the view and image pixels (both top-left origin).
struct ImageMapping {
    let frame: CGRect
    let pixelSize: CGSize

    var scale: CGFloat { frame.width / max(pixelSize.width, 1) }

    func toImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max((point.x - frame.minX) / scale, 0), pixelSize.width),
                y: min(max((point.y - frame.minY) / scale, 0), pixelSize.height))
    }

    func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale)
    }

    func toView(_ rect: CGRect) -> CGRect {
        CGRect(origin: toView(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    func toImage(_ rect: CGRect) -> CGRect {
        let a = toImage(rect.origin), b = toImage(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// An aspect-fit image with an overlay that knows where the image sits.
struct ImageStage<Overlay: View>: View {
    let image: NSImage
    let pixelSize: CGSize
    @ViewBuilder var overlay: (ImageMapping) -> Overlay

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size
            let scale = min((available.width - 32) / max(pixelSize.width, 1), (available.height - 32) / max(pixelSize.height, 1))
            let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
            let frame = CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2, width: size.width, height: size.height)
            ZStack(alignment: .topLeading) {
                Checkerboard().frame(width: size.width, height: size.height).offset(x: frame.minX, y: frame.minY)
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height).offset(x: frame.minX, y: frame.minY)
                overlay(ImageMapping(frame: frame, pixelSize: pixelSize))
            }
            .frame(width: available.width, height: available.height, alignment: .topLeading)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// Shows where an image is transparent.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0...Int(size.height / cell) {
                for column in 0...Int(size.width / cell) where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.gray.opacity(0.18)))
                }
            }
        }
        .background(Color.white)
    }
}

/// An image file loaded once at full size and once downscaled for fast previews.
struct LoadedImage {
    let full: CGImage
    let preview: CGImage
    let nsImage: NSImage

    var pixelSize: CGSize { CGSize(width: full.width, height: full.height) }
    /// Multiply preview pixels by this to get full-size pixels.
    var previewScale: CGFloat { CGFloat(full.width) / CGFloat(preview.width) }

    init(_ url: URL, previewSize: Int = 1400) throws {
        full = try ImageConverter.load(url)
        preview = max(full.width, full.height) > previewSize ? try ImageConverter.load(url, maxPixelSize: previewSize) : full
        nsImage = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
    }
}

extension NSImage {
    convenience init(_ image: CGImage) {
        self.init(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// A swatch row of preset colours plus a free picker.
struct ColorRow: View {
    @Binding var color: NSColor
    var presets: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(presets, id: \.self) { preset in
                Circle().fill(Color(nsColor: preset)).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(preset == color ? 0.9 : 0.15), lineWidth: preset == color ? 2 : 1))
                    .onTapGesture { color = preset }
            }
            ColorPicker("", selection: Binding(get: { Color(nsColor: color) }, set: { color = NSColor($0) })).labelsHidden()
        }
    }
}

// MARK: Media

/// AVPlayer plus its current time, for editors with a preview.
@MainActor
final class PlayerModel: ObservableObject {
    let url: URL
    let player: AVPlayer?
    @Published var time: Double = 0
    @Published var duration: Double = 0
    private var observer: Any?

    init(_ url: URL) {
        self.url = url
        let asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        observer = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.time = time.seconds }
        }
        Task {
            duration = (try? await FFmpeg.duration(of: url)) ?? 0
        }
    }

    /// AVFoundation can't play MKV, WebM, AVI, WMV, OGG and friends; editors still work without a preview.
    var canPreview: Bool {
        ["mp4", "m4v", "mov", "m4a", "mp3", "wav", "aiff", "caf", "aac", "flac", "3gp"].contains(Output.normalizedExtension(url))
    }

    func seek(_ seconds: Double) {
        time = min(max(seconds, 0), duration)
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        guard let player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    func pause() { player?.pause() }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?
    var controls: AVPlayerViewControlsStyle = .inline

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controls
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

/// Video preview, or a placeholder for formats AVFoundation can't play.
struct MediaPreview: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        if model.canPreview {
            PlayerView(player: model.player)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(.secondary)
                Text("Preview isn't available for \(model.url.pathExtension.uppercased()) files.\nThe timeline below still works.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
        }
    }
}

/// Filmstrip or waveform behind a timeline.
enum TimelineBackground {
    static func thumbnails(_ url: URL, count: Int = 12) async -> [NSImage] {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration).seconds, duration > 0,
           let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 200)
            var images: [NSImage] = []
            for i in 0..<count {
                let time = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                if let (image, _) = try? await generator.image(at: time) { images.append(NSImage(image)) }
            }
            if !images.isEmpty { return images }
        }
        // ffmpeg handles containers AVFoundation can't.
        guard let duration = try? await FFmpeg.duration(of: url), let folder = try? Output.temporaryFolder() else { return [] }
        defer { try? FileManager.default.removeItem(at: folder) }
        let pattern = folder.appendingPathComponent("t%02d.jpg").path
        try? await FFmpeg.run(["-i", url.path, "-vf", "fps=\(Double(count) / max(duration, 0.1)),scale=200:-2", "-frames:v", "\(count)", pattern])
        return (1...count).compactMap { NSImage(contentsOf: folder.appendingPathComponent(String(format: "t%02d.jpg", $0))) }
    }

    /// Peak levels, 0–1, in `buckets` slices.
    static func waveform(_ url: URL, buckets: Int = 600) async -> [Float] {
        guard let ffmpeg = Shell.tool("ffmpeg"),
              let data = try? await Shell.run(ffmpeg, ["-v", "error", "-i", url.path, "-ac", "1", "-ar", "4000", "-f", "f32le", "-"]),
              !data.isEmpty else { return [] }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let size = max(1, samples.count / buckets)
        let peaks = stride(from: 0, to: samples.count, by: size).map { start in
            samples[start..<min(start + size, samples.count)].reduce(0) { max($0, abs($1)) }
        }
        let loudest = max(peaks.max() ?? 1, 0.0001)
        return peaks.map { $0 / loudest }
    }
}

/// A time axis with a background strip, a playhead, and overlay content placed by time.
struct Timeline<Overlay: View>: View {
    let duration: Double
    let time: Double
    var thumbnails: [NSImage] = []
    var waveform: [Float] = []
    var seek: (Double) -> Void
    @ViewBuilder var overlay: (_ x: @escaping (Double) -> CGFloat, _ time: @escaping (CGFloat) -> Double) -> Overlay

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x: (Double) -> CGFloat = { duration > 0 ? CGFloat($0 / duration) * width : 0 }
            let t: (CGFloat) -> Double = { min(max(Double($0 / max(width, 1)) * duration, 0), duration) }
            ZStack(alignment: .topLeading) {
                strip(width: width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { seek(t($0.location.x)) })
                overlay(x, t)
                Rectangle().fill(Color.white).frame(width: 2, height: geometry.size.height)
                    .shadow(radius: 1).offset(x: x(time) - 1).allowsHitTesting(false)
            }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func strip(width: CGFloat, height: CGFloat) -> some View {
        if !thumbnails.isEmpty {
            HStack(spacing: 0) {
                ForEach(thumbnails.indices, id: \.self) { i in
                    Image(nsImage: thumbnails[i]).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(thumbnails.count), height: height).clipped()
                }
            }
        } else {
            Canvas { context, size in
                guard !waveform.isEmpty else { return }
                let step = size.width / CGFloat(waveform.count)
                for (i, peak) in waveform.enumerated() {
                    let h = max(1, CGFloat(peak) * size.height * 0.9)
                    context.fill(Path(CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: max(step - 0.5, 0.5), height: h)),
                                 with: .color(.accentColor))
                }
            }
            .background(Color.secondary.opacity(0.15))
        }
    }
}

/// Start and end handles over a timeline; outside the range is dimmed.
struct RangeHandles: View {
    @Binding var range: ClosedRange<Double>
    let x: (Double) -> CGFloat
    let time: (CGFloat) -> Double
    var onScrub: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            let start = x(range.lowerBound), end = x(range.upperBound)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.45).frame(width: max(start, 0)).allowsHitTesting(false)
                Color.black.opacity(0.45).frame(width: max(geometry.size.width - end, 0)).offset(x: end).allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(end - start, 6)).offset(x: start).allowsHitTesting(false)
                handle.offset(x: start - 6).gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { value in
                    let t = min(time(value.location.x), range.upperBound - 0.1)
                    range = max(t, 0)...range.upperBound
                    onScrub(range.lowerBound)
                })
                handle.offset(x: end - 6).gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { value in
                    let t = max(time(value.location.x), range.lowerBound + 0.1)
                    range = range.lowerBound...t
                    onScrub(range.upperBound)
                })
            }
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.yellow).frame(width: 12)
            .overlay(Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: 18))
            .contentShape(Rectangle())
    }
}

/// "1:02.35"
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "–" }
    let total = max(seconds, 0)
    return String(format: "%d:%05.2f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
}

func fileSize(_ url: URL) -> String {
    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
