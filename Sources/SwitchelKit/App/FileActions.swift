import AppKit
import Quartz

@MainActor
enum FileActions {
    static func airDrop(_ urls: [URL]) throws {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            throw SwitchelError("AirDrop isn't available")
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Puts the files themselves on the clipboard, ready to paste in Finder.
    static func copyFiles(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    /// Asks for a folder and moves the files there, renaming rather than replacing.
    static func move(_ urls: [URL]) throws -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Move \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") to:"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { throw CancellationError() }
        return try urls.map { url in
            var destination = folder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                let name = url.deletingPathExtension().lastPathComponent
                destination = folder.appendingPathComponent(url.pathExtension.isEmpty ? "\(name) \(n)" : "\(name) \(n).\(url.pathExtension)")
                n += 1
            }
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    /// Opens the chosen terminal in the folder, or in the folder containing the file.
    static func openInTerminal(_ urls: [URL]) throws {
        let preferred = Settings.shared.terminal
        let app = [preferred, .terminal].lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.rawValue) }.first
        guard let app else { throw SwitchelError("No terminal app found") }
        let first = urls[0]
        let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let folder = isFolder ? first : first.deletingLastPathComponent()
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// Quick Look for any set of files.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

/// Files selected in the frontmost Finder window, for the keyboard shortcut.
enum FinderSelection {
    static func urls() async throws -> [URL] {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with f in (get selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
        end tell
        return out
        """
        do {
            let output = try await Shell.run("/usr/bin/osascript", ["-e", script])
            return String(decoding: output, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        } catch {
            if error.localizedDescription.contains("-1743") {
                throw SwitchelError("Allow Switchel to control Finder in System Settings › Privacy & Security › Automation.")
            }
            throw error
        }
    }
}
