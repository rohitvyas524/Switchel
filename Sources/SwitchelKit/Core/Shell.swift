import AVFoundation
import Foundation

enum Shell {
    /// Runs a command to completion and returns its standard output.
    /// Fails with the last lines of standard error when it exits non-zero.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Drain both pipes concurrently so a chatty tool can't fill one and block.
                var errorData = Data()
                let drained = DispatchGroup()
                drained.enter()
                DispatchQueue.global().async {
                    errorData = errors.fileHandleForReading.readDataToEndOfFile()
                    drained.leave()
                }
                let outputData = output.fileHandleForReading.readDataToEndOfFile()
                drained.wait()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: outputData)
                } else {
                    let name = URL(fileURLWithPath: executable).lastPathComponent
                    let detail = String(decoding: errorData, as: UTF8.self)
                        .split(separator: "\n").suffix(2).joined(separator: " ")
                    continuation.resume(throwing: SwitchelError("\(name) failed: \(detail.isEmpty ? "exit \(process.terminationStatus)" : detail)"))
                }
            }
        }
    }

    /// Finds a helper tool: bundled in the app first, then Homebrew, then the system.
    static func tool(_ name: String) -> String? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path
        let candidates = [bundled, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func require(_ name: String, brew formula: String) throws -> String {
        guard let path = tool(name) else {
            throw SwitchelError("This needs \(name). Install it with “brew install \(formula)”.")
        }
        return path
    }
}

enum FFmpeg {
    static var isAvailable: Bool { Shell.tool("ffmpeg") != nil }

    static func run(_ arguments: [String]) async throws {
        let ffmpeg = try Shell.require("ffmpeg", brew: "ffmpeg")
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments)
    }

    /// Seconds, from AVFoundation when it can read the file, otherwise ffprobe.
    static func duration(of url: URL) async throws -> Double {
        if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite, seconds > 0 {
            return seconds
        }
        let ffprobe = try Shell.require("ffprobe", brew: "ffmpeg")
        let output = try await Shell.run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
        guard let seconds = Double(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SwitchelError("Couldn't read the length of \(url.lastPathComponent)")
        }
        return seconds
    }

    static func hasAudio(_ url: URL) async -> Bool {
        if let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio), !tracks.isEmpty { return true }
        guard let ffprobe = Shell.tool("ffprobe"),
              let output = try? await Shell.run(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", url.path])
        else { return false }
        return !output.isEmpty
    }

    /// "between(t,1,2)+between(t,5,6)" for filters' `enable` option.
    static func between(_ ranges: [ClosedRange<Double>]) -> String {
        ranges.map { "between(t,\($0.lowerBound),\($0.upperBound))" }.joined(separator: "+")
    }
}

enum Zip {
    /// Zips the contents of `folder` (not the folder itself). `storedFirst` is written
    /// first and uncompressed, as EPUB and ODF require for their `mimetype` entry.
    static func create(_ archive: URL, fromContentsOf folder: URL, storedFirst: String? = nil) async throws {
        try? FileManager.default.removeItem(at: archive)
        if let storedFirst {
            try await Shell.run("/usr/bin/zip", ["-X0q", archive.path, storedFirst], in: folder)
        }
        let items = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0 != storedFirst && $0 != ".DS_Store" }
        try await Shell.run("/usr/bin/zip", ["-Xrq9", archive.path] + items, in: folder)
    }

    static func extract(_ archive: URL, to folder: URL) async throws {
        try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
    }
}

/// XML text escaping for the hand-written OOXML, ODF and EPUB parts.
extension String {
    var xmlEscaped: String {
        var result = ""
        result.reserveCapacity(count)
        for character in self {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default:
                // XML 1.0 forbids most control characters.
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20, !"\t\n\r".contains(character) { continue }
                result.append(character)
            }
        }
        return result
    }
}
