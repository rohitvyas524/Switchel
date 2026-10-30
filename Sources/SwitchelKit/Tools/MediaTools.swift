import AVFoundation
import AppKit

/// Video and audio tools, built on ffmpeg. Times are in seconds.
enum VideoTools {
    /// Tools keep the source container when it's one we encode, otherwise MP4.
    static func format(for url: URL) -> VideoFormat {
        let format = VideoFormat(rawValue: Output.normalizedExtension(url))
        return format.flatMap { [.gif, .mp3].contains($0) ? nil : $0 } ?? .mp4
    }

    /// Codec arguments without filters, so tools can add their own filter graph.
    static func encoder(_ format: VideoFormat) -> [String] {
        switch format {
        case .webm: ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]
        case .avi: ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case .wmv: ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        default: MediaConverter.h264 + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        }
    }

    // MARK: Compress

    struct Compression: Equatable {
        enum Strength: String, CaseIterable, Identifiable {
            case light, balanced, strong
            var id: Self { self }
            var title: String { rawValue.capitalized }
            var crf: Int { switch self { case .light: 23; case .balanced: 28; case .strong: 33 } }
        }
        var strength: Strength = .balanced
        /// Overrides strength with a bitrate that lands near this size.
        var targetMegabytes: Double?
        var maxHeight: Int?
        var removeAudio = false
    }

    static func compress(_ url: URL, _ options: Compression = .init()) async throws -> URL {
        guard FFmpeg.isAvailable else {
            return try await MediaConverter.export(url, preset: AVAssetExportPresetHEVC1920x1080, fileType: .mp4, ext: "mp4", suffix: "compressed")
        }
        let out = Output.url(for: url, ext: "mp4", suffix: "compressed")
        let scale = options.maxHeight.map { "scale=-2:'trunc(min(\($0),ih)/2)*2'" } ?? MediaConverter.evenSize
        var video = ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p"]
        if let megabytes = options.targetMegabytes {
            let duration = try await FFmpeg.duration(of: url)
            let audioKbps = options.removeAudio ? 0 : 128
            let kbps = max(100, Int(megabytes * 8 * 1000 / duration) - audioKbps)
            video += ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 6 / 5)k", "-bufsize", "\(kbps * 2)k"]
        } else {
            video += ["-crf", String(options.strength.crf)]
        }
        let audio = options.removeAudio ? ["-an"] : ["-c:a", "aac", "-b:a", "128k"]
        try await FFmpeg.run(["-i", url.path, "-vf", scale] + video + audio + ["-movflags", "+faststart", out.path])
        return out
    }

    // MARK: Trim, split

    static func trim(_ url: URL, _ range: ClosedRange<Double>, suffix: String = "trimmed") async throws -> URL {
        let format = format(for: url)
        let out = Output.url(for: url, ext: format.rawValue, suffix: suffix)
        let filter = [.webm, .avi, .wmv].contains(format) ? [] : ["-vf", MediaConverter.evenSize]
        try await FFmpeg.run(["-ss", "\(range.lowerBound)", "-i", url.path, "-t", "\(range.upperBound - range.lowerBound)"]
                             + filter + encoder(format) + [out.path])
        return out
    }

    /// Crops the frame. `rect` is normalized 0–1 with a top-left origin.
    static func crop(_ url: URL, to rect: CGRect) async throws -> URL {
        let format = format(for: url)
        let out = Output.url(for: url, ext: format.rawValue, suffix: "cropped")
        let filter = "crop=iw*\(rect.width):ih*\(rect.height):iw*\(rect.minX):ih*\(rect.minY),\(MediaConverter.evenSize)"
        try await FFmpeg.run(["-i", url.path, "-vf", filter] + encoder(format) + [out.path])
        return out
    }

    /// Keeps only `ranges` and joins them into one video, cutting out everything else.
    static func keep(_ url: URL, _ ranges: [ClosedRange<Double>]) async throws -> URL {
        guard !ranges.isEmpty else { throw SwitchelError("Keep at least one part") }
        let format = format(for: url)
        let out = Output.url(for: url, ext: format.rawValue, suffix: "edited")
        let audio = await FFmpeg.hasAudio(url)
        var graph: [String] = []
        var inputs = ""
        for (i, range) in ranges.enumerated() {
            graph.append("[0:v]trim=start=\(range.lowerBound):end=\(range.upperBound),setpts=PTS-STARTPTS[v\(i)]")
            inputs += "[v\(i)]"
            if audio {
                graph.append("[0:a]atrim=start=\(range.lowerBound):end=\(range.upperBound),asetpts=PTS-STARTPTS[a\(i)]")
                inputs += "[a\(i)]"
            }
        }
        graph.append("\(inputs)concat=n=\(ranges.count):v=1:a=\(audio ? 1 : 0)[joined]\(audio ? "[a]" : "")")
        graph.append("[joined]\(MediaConverter.evenSize)[v]")
        var arguments = ["-i", url.path, "-filter_complex", graph.joined(separator: ";"), "-map", "[v]"]
        if audio { arguments += ["-map", "[a]"] }
        try await FFmpeg.run(arguments + encoder(format) + [out.path])
        return out
    }

    struct GIFOptions: Equatable {
        var fps = 12
        var width = 480
        var range: ClosedRange<Double>?
    }

    static func makeGIF(_ url: URL, _ options: GIFOptions) async throws -> URL {
        let out = Output.url(for: url, ext: "gif")
        var arguments: [String] = []
        if let range = options.range {
            arguments += ["-ss", "\(range.lowerBound)", "-t", "\(range.upperBound - range.lowerBound)"]
        }
        let filter = "fps=\(options.fps),scale='min(\(options.width),iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"
        try await FFmpeg.run(arguments + ["-i", url.path, "-vf", filter, "-loop", "0", out.path])
        return out
    }

    static func split(_ url: URL, at points: [Double]) async throws -> [URL] {
        let duration = try await FFmpeg.duration(of: url)
        let bounds = [0] + points.filter { $0 > 0 && $0 < duration }.sorted() + [duration]
        var outputs: [URL] = []
        for i in 0..<(bounds.count - 1) {
            outputs.append(try await trim(url, bounds[i]...bounds[i + 1], suffix: "part \(i + 1)"))
        }
        return outputs
    }

    // MARK: Speed

    /// atempo accepts 0.5–2, so larger changes are chained.
    static func atempo(_ factor: Double) -> String {
        var remaining = factor, parts: [Double] = []
        while remaining > 2 { parts.append(2); remaining /= 2 }
        while remaining < 0.5 { parts.append(0.5); remaining /= 0.5 }
        parts.append(remaining)
        return parts.map { "atempo=\($0)" }.joined(separator: ",")
    }

    static func changeSpeed(_ url: URL, by factor: Double) async throws -> URL {
        let format = format(for: url)
        let label = factor == factor.rounded() ? String(Int(factor)) : String(format: "%g", factor)
        let out = Output.url(for: url, ext: format.rawValue, suffix: "\(label)x")
        let video = "[0:v]setpts=PTS/\(factor),\(MediaConverter.evenSize)[v]"
        let graph = await FFmpeg.hasAudio(url)
            ? ["-filter_complex", "\(video);[0:a]\(atempo(factor))[a]", "-map", "[v]", "-map", "[a]"]
            : ["-filter_complex", video, "-map", "[v]"]
        try await FFmpeg.run(["-i", url.path] + graph + encoder(format) + [out.path])
        return out
    }

    // MARK: Redact

    struct Redaction: Identifiable, Equatable {
        let id = UUID()
        /// Normalized 0–1, top-left origin, so it's independent of the video's pixel size.
        var rect: CGRect
        var start: Double
        var end: Double
    }

    static func redact(_ url: URL, _ regions: [Redaction], style: ImageTools.RedactionStyle) async throws -> URL {
        guard !regions.isEmpty else { throw SwitchelError("Draw at least one redaction") }
        let format = format(for: url)
        let out = Output.url(for: url, ext: format.rawValue, suffix: "redacted")
        var graph: [String] = []
        var label = "0:v"
        for (i, region) in regions.enumerated() {
            let r = region.rect
            let enable = "enable='between(t,\(region.start),\(region.end))'"
            switch style {
            case .black:
                graph.append("[\(label)]drawbox=x=iw*\(r.minX):y=ih*\(r.minY):w=iw*\(r.width):h=ih*\(r.height):color=black:t=fill:\(enable)[r\(i)]")
            case .blur, .pixelate:
                let effect = style == .blur
                    ? "boxblur=luma_radius='max(1,min(w,h)/5)':chroma_radius='max(1,min(cw,ch)/5)':luma_power=3"
                    : "pixelize=w=16:h=16"
                graph.append("[\(label)]split[b\(i)][s\(i)]")
                graph.append("[s\(i)]crop=iw*\(r.width):ih*\(r.height):iw*\(r.minX):ih*\(r.minY),\(effect)[e\(i)]")
                graph.append("[b\(i)][e\(i)]overlay=W*\(r.minX):H*\(r.minY):\(enable)[r\(i)]")
            }
            label = "r\(i)"
        }
        graph.append("[\(label)]\(MediaConverter.evenSize)[v]")
        try await FFmpeg.run(["-i", url.path, "-filter_complex", graph.joined(separator: ";"), "-map", "[v]", "-map", "0:a?"]
                             + encoder(format) + [out.path])
        return out
    }

    // MARK: Snapshots

    static func snapshots(_ url: URL, at times: [Double], as format: ImageFormat = .png) async throws -> [URL] {
        guard !times.isEmpty else { throw SwitchelError("Add at least one frame") }
        let folder: URL? = times.count > 1 ? Output.url(for: url, ext: nil, suffix: "snapshots") : nil
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let base = Output.baseName(url)
        var outputs: [URL] = []
        for time in times.sorted() {
            let stamp = String(format: "%02dm%05.2fs", Int(time) / 60, time.truncatingRemainder(dividingBy: 60))
            let out = folder.map { $0.appendingPathComponent("\(base) \(stamp).\(format.rawValue)") }
                ?? Output.url(for: url, ext: format.rawValue, suffix: "snapshot")
            try await FFmpeg.run(["-ss", "\(time)", "-i", url.path, "-frames:v", "1", "-update", "1", out.path])
            outputs.append(out)
        }
        return folder.map { [$0] } ?? outputs
    }

    // MARK: Merge, mute

    static func merge(_ urls: [URL]) async throws -> URL {
        guard urls.count > 1 else { throw SwitchelError("Choose two or more videos to merge") }
        let format = format(for: urls[0])
        let out = Output.url(for: urls[0], ext: format.rawValue, suffix: "merged")
        let size = try await dimensions(of: urls[0])
        var withAudio = true
        for url in urls where !(await FFmpeg.hasAudio(url)) { withAudio = false }

        var graph: [String] = []
        var inputs = ""
        for i in urls.indices {
            graph.append("[\(i):v]scale=\(size.w):\(size.h):force_original_aspect_ratio=decrease,pad=\(size.w):\(size.h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(i)]")
            inputs += "[v\(i)]"
            if withAudio {
                graph.append("[\(i):a]aresample=48000,aformat=channel_layouts=stereo[a\(i)]")
                inputs += "[a\(i)]"
            }
        }
        graph.append("\(inputs)concat=n=\(urls.count):v=1:a=\(withAudio ? 1 : 0)[v]\(withAudio ? "[a]" : "")")
        var arguments: [String] = urls.flatMap { ["-i", $0.path] }
        arguments += ["-filter_complex", graph.joined(separator: ";"), "-map", "[v]"]
        if withAudio { arguments += ["-map", "[a]"] }
        try await FFmpeg.run(arguments + encoder(format) + [out.path])
        return out
    }

    /// Even pixel size of the first video stream.
    static func dimensions(of url: URL) async throws -> (w: Int, h: Int) {
        let ffprobe = try Shell.require("ffprobe", brew: "ffmpeg")
        let output = try await Shell.run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", url.path])
        let parts = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { throw SwitchelError("Couldn't read the size of \(url.lastPathComponent)") }
        return (parts[0] / 2 * 2, parts[1] / 2 * 2)
    }

    static func removeAudio(_ url: URL) async throws -> URL {
        let out = Output.url(for: url, ext: url.pathExtension, suffix: "muted")
        try await FFmpeg.run(["-i", url.path, "-c:v", "copy", "-an", out.path])
        return out
    }
}

enum AudioTools {
    static func output(for url: URL, suffix: String) -> (URL, AudioFormat) {
        let format = AudioFormat.same(as: url)
        return (Output.url(for: url, ext: format.rawValue, suffix: suffix), format)
    }

    private static func filter(_ url: URL, _ filter: String, suffix: String) async throws -> URL {
        let (out, format) = output(for: url, suffix: suffix)
        try await FFmpeg.run(["-i", url.path, "-vn", "-af", filter] + format.codecArguments + [out.path])
        return out
    }

    // MARK: Compress

    static func compress(_ url: URL, kbps: Int, mono: Bool) async throws -> URL {
        var format = AudioFormat.same(as: url)
        if [.wav, .aiff, .flac].contains(format) { format = .m4a }
        let out = Output.url(for: url, ext: format.rawValue, suffix: "compressed")
        let codec: String = switch format {
        case .mp3: "libmp3lame"
        case .opus: "libopus"
        case .ogg: "vorbis"
        case .wma: "wmav2"
        default: "aac"
        }
        let channels = mono ? ["-ac", "1"] : format == .ogg ? ["-ac", "2"] : []
        try await FFmpeg.run(["-i", url.path, "-vn", "-c:a", codec, "-b:a", "\(kbps)k", "-strict", "-2"] + channels + [out.path])
        return out
    }

    // MARK: Trim

    static func trim(_ url: URL, _ range: ClosedRange<Double>) async throws -> URL {
        let (out, format) = output(for: url, suffix: "trimmed")
        try await FFmpeg.run(["-ss", "\(range.lowerBound)", "-i", url.path, "-t", "\(range.upperBound - range.lowerBound)", "-vn"]
                             + format.codecArguments + [out.path])
        return out
    }

    /// Removes leading and trailing audio quieter than `threshold` dB.
    static func trimSilence(_ url: URL, threshold: Double = -50) async throws -> URL {
        let remove = "silenceremove=start_periods=1:start_threshold=\(threshold)dB:start_silence=0.05"
        return try await filter(url, "\(remove),areverse,\(remove),areverse", suffix: "trimmed")
    }

    // MARK: Volume, channels

    /// EBU R128 loudness. -16 LUFS suits spoken audio and music; the true-peak ceiling prevents clipping after encoding.
    static func normalize(_ url: URL, target: Double = -16, range: Double = 11, truePeak: Double = -1.5) async throws -> URL {
        try await filter(url, "loudnorm=I=\(target):TP=\(truePeak):LRA=\(range)", suffix: "normalized")
    }

    enum ChannelMode: String, CaseIterable, Identifiable {
        case stereo, mono, swap, leftOnly, rightOnly
        var id: Self { self }
        var title: String {
            switch self {
            case .stereo: "Stereo"
            case .mono: "Mono"
            case .swap: "Swap L/R"
            case .leftOnly: "Left Only"
            case .rightOnly: "Right Only"
            }
        }
    }

    static func panFilter(_ mode: ChannelMode, left: Double, right: Double) -> String {
        let pan: String = switch mode {
        case .stereo: "pan=stereo|c0=\(left)*c0|c1=\(right)*c1"
        case .mono: "pan=mono|c0=\(left / 2)*c0+\(right / 2)*c1"
        case .swap: "pan=stereo|c0=\(left)*c1|c1=\(right)*c0"
        case .leftOnly: "pan=stereo|c0=\(left)*c0|c1=\(right)*c0"
        case .rightOnly: "pan=stereo|c0=\(left)*c1|c1=\(right)*c1"
        }
        // Upmix mono sources first so c1 exists.
        return "aformat=channel_layouts=stereo,\(pan)"
    }

    static func changeChannels(_ url: URL, mode: ChannelMode, left: Double = 1, right: Double = 1) async throws -> URL {
        try await filter(url, panFilter(mode, left: left, right: right), suffix: mode == .mono ? "mono" : "channels")
    }

    // MARK: Bleep

    static func bleep(_ url: URL, ranges: [ClosedRange<Double>], beep: Bool) async throws -> URL {
        guard !ranges.isEmpty else { throw SwitchelError("Mark at least one range") }
        let (out, format) = output(for: url, suffix: beep ? "bleeped" : "muted")
        let when = FFmpeg.between(ranges)
        let graph = beep
            ? "[0:a]volume=0:enable='\(when)'[m];sine=frequency=1000:sample_rate=48000,volume=0.25,volume=0:enable='not(\(when))'[s];[m][s]amix=inputs=2:duration=first:normalize=0[a]"
            : "[0:a]volume=0:enable='\(when)'[a]"
        try await FFmpeg.run(["-i", url.path, "-filter_complex", graph, "-map", "[a]"] + format.codecArguments + [out.path])
        return out
    }

    // MARK: Visualize

    struct Visualization: Equatable {
        enum Style: String, CaseIterable, Identifiable {
            case wave, line, bars, spectrum
            var id: Self { self }
            var title: String { rawValue.capitalized }
        }
        var style: Style = .wave
        var color: NSColor = NSColor(srgbRed: 1, green: 0.55, blue: 0.2, alpha: 1)
        var background: NSColor = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        var backgroundImage: URL?
        var width = 1280
        var height = 720
    }

    /// Renders the audio as an MP4 with an animated waveform.
    static func visualize(_ url: URL, _ options: Visualization) async throws -> URL {
        let out = Output.url(for: url, ext: "mp4", suffix: "visualized")
        let size = "\(options.width)x\(options.height)"
        let color = hex(options.color)
        let visual: String = switch options.style {
        case .wave: "showwaves=s=\(size):mode=cline:rate=30:colors=\(color)"
        case .line: "showwaves=s=\(size):mode=line:rate=30:colors=\(color)"
        case .bars: "showfreqs=s=\(size):mode=bar:ascale=sqrt:fscale=log:colors=\(color)"
        case .spectrum: "showspectrum=s=\(size):slide=scroll:color=intensity"
        }
        let background = options.backgroundImage.map { ["-loop", "1", "-framerate", "30", "-i", $0.path] }
            ?? ["-f", "lavfi", "-i", "color=c=\(hex(options.background)):s=\(size):r=30"]
        let graph = "[0:a]\(visual),format=rgba,colorkey=black:0.01:0[w];[1:v]scale=\(options.width):\(options.height):force_original_aspect_ratio=increase,crop=\(options.width):\(options.height)[bg];[bg][w]overlay=shortest=1,format=yuv420p[v]"
        try await FFmpeg.run(["-i", url.path] + background + ["-filter_complex", graph, "-map", "[v]", "-map", "0:a",
                                                              "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "192k", "-shortest", out.path])
        return out
    }

    static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "0x%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    // MARK: Merge

    static func merge(_ urls: [URL]) async throws -> URL {
        guard urls.count > 1 else { throw SwitchelError("Choose two or more audio files to merge") }
        let (out, format) = output(for: urls[0], suffix: "merged")
        let inputs = urls.indices.map { "[\($0):a]aresample=48000,aformat=channel_layouts=stereo[a\($0)]" }.joined(separator: ";")
        let labels = urls.indices.map { "[a\($0)]" }.joined()
        try await FFmpeg.run(urls.flatMap { ["-i", $0.path] } + ["-filter_complex", "\(inputs);\(labels)concat=n=\(urls.count):v=0:a=1[a]", "-map", "[a]"]
                             + format.codecArguments + [out.path])
        return out
    }
}
