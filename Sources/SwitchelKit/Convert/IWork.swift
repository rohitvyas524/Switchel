import AppKit

/// Drives Pages, Keynote and Numbers over Apple Events for the formats only they can read or write
/// (.pages, .key, .numbers, legacy .ppt/.xls). macOS asks once for Automation permission per app.
enum IWork {
    enum App: String {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"
        var bundleID: String { "com.apple.iWork.\(rawValue)" }
    }

    /// Off in tests, so they never trigger an Automation prompt.
    static var automationEnabled = true

    /// Installed and allowed to be driven.
    static func canUse(_ app: App) -> Bool { automationEnabled && isInstalled(app) }

    static func isInstalled(_ app: App) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
    }

    /// `format` is the app's AppleScript export format, e.g. `PDF` or `Microsoft Word`.
    static func export(_ input: URL, with app: App, to output: URL, as format: String, properties: String? = nil) async throws {
        let extra = properties.map { " with properties \($0)" } ?? ""
        try await run(app, input, output, command: "export theDoc to outFile as \(format)\(extra)")
    }

    /// Saves in the app's own format (.pages, .key, .numbers).
    static func save(_ input: URL, with app: App, to output: URL) async throws {
        try await run(app, input, output, command: "save theDoc in outFile")
    }

    private static func run(_ app: App, _ input: URL, _ output: URL, command: String) async throws {
        guard automationEnabled else { throw SwitchelError("Automation is turned off") }
        guard isInstalled(app) else {
            throw SwitchelError("This needs \(app.rawValue), which is free on the Mac App Store.")
        }
        let script = """
        on run argv
            set inFile to POSIX file (item 1 of argv)
            set outFile to POSIX file (item 2 of argv)
            set wasRunning to application "\(app.rawValue)" is running
            with timeout of 600 seconds
                tell application "\(app.rawValue)"
                    set theDoc to open inFile
                    \(command)
                    close theDoc saving no
                    if not wasRunning then quit
                end tell
            end timeout
        end run
        """
        do {
            try await Shell.run("/usr/bin/osascript", ["-e", script, input.path, output.path])
        } catch {
            if "\(error.localizedDescription)".contains("-1743") {
                throw SwitchelError("Allow Switchel to control \(app.rawValue) in System Settings › Privacy & Security › Automation.")
            }
            throw error
        }
    }
}
