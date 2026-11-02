import AppKit
import XCTest
@testable import SwitchelKit

/// Fixes that added a small seam so they could be tested without opening a window.
final class CancellationAndEditorTests: FixtureCase {
    func testCancellingStopsTheCommand() async throws {
        let started = Date()
        let task = Task { try await Shell.run("/bin/sleep", ["30"]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("should have been cancelled")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the process was stopped, not waited for")
        }
    }

    func testCancelledBeforeStartingNeverRuns() async throws {
        let marker = folder.appendingPathComponent("ran")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Shell.run("/usr/bin/touch", [marker.path])
        }
        do { _ = try await task.value; XCTFail("should have been cancelled") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFailureStillReportsTheCommandsError() async {
        do {
            try await Shell.run("/bin/sh", ["-c", "echo nope >&2; exit 3"])
            XCTFail("should have failed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nope"), error.localizedDescription)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// A batch that finished one file and is partway through the next when cancelled.
    @MainActor
    func testCancelRemovesEverythingTheSaveStarted() async throws {
        let source = folder.appendingPathComponent("song.txt")
        try "keep me".write(to: source, atomically: true, encoding: .utf8)
        let session = ToolSession()
        var first: URL?, second: URL?
        session.run {
            first = Output.url(for: source, ext: "txt", suffix: "one")
            try "done".write(to: first!, atomically: true, encoding: .utf8)
            second = Output.url(for: source, ext: "txt", suffix: "two")
            try "partial".write(to: second!, atomically: true, encoding: .utf8)
            try await Shell.run("/bin/sleep", ["30"])
            return [first!, second!]
        }
        try await waitUntil { second.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        session.cancel()
        try await waitUntil { !FileManager.default.fileExists(atPath: second!.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original is never touched")
    }

    @MainActor
    func testSaveFinishingUncancelledKeepsItsFile() async throws {
        let source = folder.appendingPathComponent("a.txt")
        let session = ToolSession()
        var out: URL?
        session.run {
            out = Output.url(for: source, ext: "txt", suffix: "edited")
            try "ok".write(to: out!, atomically: true, encoding: .utf8)
            return [out!]
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out!.path))
    }

    func testBleepRangeNeverCrosses() {
        XCTAssertEqual(AudioTools.bleepRange(at: 1, duration: 10), 1...1.6)
        XCTAssertEqual(AudioTools.bleepRange(at: 9.8, duration: 10), 9.8...10)
        XCTAssertNil(AudioTools.bleepRange(at: 10, duration: 10))
        XCTAssertNil(AudioTools.bleepRange(at: 12, duration: 10), "a VBR playhead past the reported end")
        XCTAssertNil(AudioTools.bleepRange(at: .nan, duration: 10))
        XCTAssertNil(AudioTools.bleepRange(at: 0, duration: 0))
    }

    func testRedactedCopiesDropCaptureDetails() async throws {
        let photo = try makePhoto()
        let out = try await ImageTools.saveCopy(try ImageConverter.load(photo), of: photo, suffix: "redacted", keepMetadata: false)
        XCTAssertFalse(ImageTools.metadata(of: out).contains { $0.group == "GPS" || $0.key == "Make" })
    }

    func testCroppedWebPKeepsCaptureDetails() async throws {
        try XCTSkipIf(Shell.tool("cwebp") == nil, "needs cwebp")
        let photo = try makePhoto()
        let webp = try await ImageConverter.convert(photo, to: .webp)
        let cropped = try await ImageTools.crop(webp, to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let entries = ImageTools.metadata(of: cropped)
        XCTAssertTrue(entries.contains { $0.group == "GPS" }, "\(entries)")
        XCTAssertEqual(entries.first { $0.key == "Make" }?.value, "TestCam")
        XCTAssertEqual(entries.first { $0.key == "PixelWidth" }?.value, "200")
        XCTAssertNil(entries.first { $0.key == "PixelXDimension" && $0.value == "1" }, "the carrier's size mustn't leak")
    }

    func testEditedWebPDoesntClaimTheCarriersSize() async throws {
        try XCTSkipIf(Shell.tool("cwebp") == nil, "needs cwebp")
        let photo = try makePhoto()
        let webp = try await ImageConverter.convert(photo, to: .webp)
        let edited = try await ImageTools.editMetadata(webp, .init(artist: "Ada", removeLocation: true))
        let entries = ImageTools.metadata(of: edited)
        XCTAssertEqual(entries.first { $0.key == "Artist" }?.value, "Ada")
        XCTAssertFalse(entries.contains { $0.group == "GPS" }, "\(entries)")
        XCTAssertEqual(entries.first { $0.key == "Make" }?.value, "TestCam")
        XCTAssertNil(entries.first { $0.key == "PixelXDimension" && $0.value == "1" }, "\(entries)")
    }

    func testTrimWithSilenceNamesTheOutputOnce() async throws {
        try XCTSkipIf(!FFmpeg.isAvailable, "needs ffmpeg")
        let wav = try makeWAV("song.wav")
        let out = try await AudioTools.trim(wav, 0.1...1.9, thenSilenceBelow: -50)
        XCTAssertEqual(out.lastPathComponent, "song trimmed.wav")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.contains("trimmed trimmed") || $0.contains("trimmed 2") }, "\(names)")
        let length = try await FFmpeg.duration(of: out)
        XCTAssertLessThan(length, 1.5, "the silence really went")
    }

    @MainActor
    func testFloatFitsTheScreen() {
        let screen = NSRect(x: 0, y: 25, width: 1000, height: 800)
        let top = NSRect(x: 100, y: 500, width: 150, height: 170)  // top edge at 670

        // Room below: the top edge stays put.
        let small = FloatController.fitted(top, to: NSSize(width: 260, height: 300), on: screen)
        XCTAssertEqual(small.maxY, 670)
        XCTAssertEqual(small.height, 300)

        // Would run off the bottom: it moves up instead.
        let medium = FloatController.fitted(top, to: NSSize(width: 260, height: 700), on: screen)
        XCTAssertEqual(medium.minY, screen.minY)
        XCTAssertEqual(medium.height, 700)

        // Taller than the screen: capped, and fully on it.
        let huge = FloatController.fitted(top, to: NSSize(width: 260, height: 4000), on: screen)
        XCTAssertEqual(huge.height, 780)
        XCTAssertTrue(screen.contains(huge))
    }

    @MainActor
    func testFloatRowsScrollIntoReach() {
        let view = FloatView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        view.add((0..<50).map { folder.appendingPathComponent("file\($0).txt") })
        view.toggleExpandedForTesting()
        view.setFrameSize(NSSize(width: 260, height: 200))
        XCTAssertEqual(view.row(at: NSPoint(x: 50, y: 35)), 0)
        XCTAssertNil(view.row(at: NSPoint(x: 50, y: 10)), "the header isn't a row")

        view.scroll(by: 400)
        XCTAssertEqual(view.row(at: NSPoint(x: 50, y: 35)), 10)
        XCTAssertNil(view.row(at: NSPoint(x: 50, y: 10)), "rows behind the header can't be grabbed")

        view.scroll(by: 100_000)
        XCTAssertEqual(view.row(at: NSPoint(x: 50, y: 170)), 49, "the last row can be reached")
        view.scroll(by: -100_000)
        XCTAssertEqual(view.row(at: NSPoint(x: 50, y: 35)), 0)
    }
}
