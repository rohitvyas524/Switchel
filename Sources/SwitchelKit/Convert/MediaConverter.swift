import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoFormat: String, CaseIterable {
    case mp4, mov, mkv, webm, avi, wmv, gif, mp3
}

enum AudioFormat: String, CaseIterable {
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma

    /// ffmpeg codec arguments for this container.
    var codecArguments: [String] {
        switch self {
        case .mp3: ["-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: ["-c:a", "aac", "-b:a", "256k"]
        case .wav: ["-c:a", "pcm_s16le"]
        case .flac: ["-c:a", "flac"]
        case .ogg: ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]
        case .opus: ["-c:a", "libopus", "-b:a", "128k"]
        case .aiff: ["-c:a", "pcm_s16be"]
        case .wma: ["-c:a", "wmav2", "-b:a", "192k"]
        }
    }

    /// The source's format when it's one we encode, otherwise M4A.
    static func same(as url: URL) -> AudioFormat {
        AudioFormat(rawValue: Output.normalizedExtension(url)) ?? .m4a
    }
}

enum MediaConverter {
    /// H.264 needs even dimensions.
    static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    static let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]

    static func videoArguments(_ format: VideoFormat) -> [String] {
        switch format {
        case .mp4, .mov: ["-vf", evenSize] + h264 + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case .mkv: ["-vf", evenSize] + h264 + ["-c:a", "aac", "-b:a", "192k"]
        case .webm: ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                     "-c:a", "libopus", "-b:a", "128k"]
        case .avi: ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case .wmv: ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        case .gif: ["-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                    "-loop", "0"]
        case .mp3: ["-vn"] + AudioFormat.mp3.codecArguments
        }
    }

    static func convert(_ url: URL, to format: VideoFormat) async throws -> URL {
        if !FFmpeg.isAvailable {
            switch format {
            case .mp4: return try await export(url, preset: AVAssetExportPresetHighestQuality, fileType: .mp4, ext: "mp4")
            case .mov: return try await export(url, preset: AVAssetExportPresetHighestQuality, fileType: .mov, ext: "mov")
            case .gif: return try await makeGIF(url)
            default: break  // FFmpeg.run reports what to install.
            }
        }
        let out = Output.url(for: url, ext: format.rawValue)
        try await FFmpeg.run(["-i", url.path] + videoArguments(format) + [out.path])
        return out
    }

    static func convert(_ url: URL, to format: AudioFormat) async throws -> URL {
        if !FFmpeg.isAvailable {
            switch format {
            case .m4a: return try await export(url, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, ext: "m4a")
            case .wav, .aiff: return try await Task.detached { try pcm(url, ext: format.rawValue) }.value
            default: break
            }
        }
        let out = Output.url(for: url, ext: format.rawValue)
        try await FFmpeg.run(["-i", url.path, "-vn"] + format.codecArguments + [out.path])
        return out
    }

    // MARK: AVFoundation fallbacks

    static func export(_ url: URL, preset: String, fileType: AVFileType, ext: String, suffix: String? = nil) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw SwitchelError("Can't export \(url.lastPathComponent)")
        }
        let out = Output.url(for: url, ext: ext, suffix: suffix)
        session.outputURL = out
        session.outputFileType = fileType
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? SwitchelError("Export of \(url.lastPathComponent) failed")
        }
        return out
    }

    /// 16-bit PCM; the container (WAV, AIFF, CAF) comes from the extension.
    static func pcm(_ url: URL, ext: String) throws -> URL {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let out = Output.url(for: url, ext: ext)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: ext == "aiff",
        ]
        let output = try AVAudioFile(forWriting: out, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else {
            throw SwitchelError("Couldn't decode \(url.lastPathComponent)")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        return out
    }

    /// 10 fps, 480 px, first 30 seconds.
    static func makeGIF(_ url: URL) async throws -> URL {
        let fps = 10.0
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let count = max(1, min(Int(duration * fps), 300))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let out = Output.url(for: url, ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw SwitchelError("Couldn't create \(out.lastPathComponent)")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let (image, _) = try await generator.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
            CGImageDestinationAddImage(dest, image, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw SwitchelError("Couldn't write \(out.lastPathComponent)") }
        return out
    }
}
