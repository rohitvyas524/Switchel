import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Which wheel a held modifier opens.
enum Mode: String, CaseIterable, Identifiable {
    case convert, tools, actions

    var id: Self { self }

    var title: String {
        switch self {
        case .convert: "Convert"
        case .tools: "Tools"
        case .actions: "Actions"
        }
    }

    var summary: String {
        switch self {
        case .convert: "Change a file’s format"
        case .tools: "Compress, crop, trim, redact and more"
        case .actions: "AirDrop, Float, move, copy and share"
        }
    }

    var symbol: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .tools: "wrench.and.screwdriver"
        case .actions: "square.and.arrow.up"
        }
    }

    var defaultKey: WheelKey {
        switch self {
        case .convert: .shift
        case .tools: .command
        case .actions: .control
        }
    }
}

enum WheelKey: String, CaseIterable, Identifiable {
    case shift, command, control, option

    var id: Self { self }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .command: .command
        case .control: .control
        case .option: .option
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        }
    }

    var name: String { rawValue.capitalized }
}

enum SaveLocation: String, CaseIterable, Identifiable {
    case nextToOriginal, downloads, folder

    var id: Self { self }

    var title: String {
        switch self {
        case .nextToOriginal: "Next to the original"
        case .downloads: "Downloads"
        case .folder: "Choose a folder…"
        }
    }
}

enum WheelStyle: String, CaseIterable, Identifiable {
    case glass, solid

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"
    case warp = "dev.warp.Warp-Stable"
    case ghostty = "com.mitchellh.ghostty"

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .warp: "Warp"
        case .ghostty: "Ghostty"
        }
    }

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil }
}

/// A global shortcut in Carbon's terms, plus how to show it.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = 0
        var symbols = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); symbols += "⌘" }
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        display = symbols + (names[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?")
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published private(set) var keys: [Mode: WheelKey] = [:]
    @Published var enabled: [Mode: Bool] = [:] {
        didSet { for mode in Mode.allCases { defaults.set(enabled[mode] ?? true, forKey: "enabled.\(mode.rawValue)") } }
    }
    @Published var shortcut: KeyCombo? {
        didSet {
            defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "shortcut")
            onShortcutChange?()
        }
    }
    @Published var saveLocation: SaveLocation {
        didSet { defaults.set(saveLocation.rawValue, forKey: "saveLocation"); applyOutputFolder() }
    }
    @Published var customFolder: URL? {
        didSet { defaults.set(customFolder?.path, forKey: "customFolder"); applyOutputFolder() }
    }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var revealResults: Bool { didSet { defaults.set(revealResults, forKey: "revealResults") } }
    @Published var terminal: TerminalApp { didSet { defaults.set(terminal.rawValue, forKey: "terminal") } }
    @Published var wheelStyle: WheelStyle { didSet { defaults.set(wheelStyle.rawValue, forKey: "wheelStyle") } }
    @Published var hoverSound: Bool { didSet { defaults.set(hoverSound, forKey: "hoverSound") } }
    @Published var hasCompletedWelcome: Bool { didSet { defaults.set(hasCompletedWelcome, forKey: "completedWelcome") } }

    var onShortcutChange: (() -> Void)?

    private init() {
        saveLocation = defaults.string(forKey: "saveLocation").flatMap(SaveLocation.init) ?? .nextToOriginal
        customFolder = defaults.string(forKey: "customFolder").map { URL(fileURLWithPath: $0) }
        playSound = defaults.object(forKey: "playSound") as? Bool ?? true
        revealResults = defaults.bool(forKey: "revealResults")
        terminal = defaults.string(forKey: "terminal").flatMap(TerminalApp.init) ?? .terminal
        wheelStyle = defaults.string(forKey: "wheelStyle").flatMap(WheelStyle.init) ?? .solid
        hoverSound = defaults.bool(forKey: "hoverSound")
        hasCompletedWelcome = defaults.bool(forKey: "completedWelcome")
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
        for mode in Mode.allCases {
            keys[mode] = defaults.string(forKey: "key.\(mode.rawValue)").flatMap(WheelKey.init) ?? mode.defaultKey
            enabled[mode] = defaults.object(forKey: "enabled.\(mode.rawValue)") as? Bool ?? true
        }
        applyOutputFolder()
    }

    func key(for mode: Mode) -> WheelKey { keys[mode] ?? mode.defaultKey }

    /// Each wheel needs its own key, so taking another wheel's key swaps them.
    func setKey(_ key: WheelKey, for mode: Mode) {
        if let other = Mode.allCases.first(where: { $0 != mode && self.key(for: $0) == key }) {
            keys[other] = self.key(for: mode)
        }
        keys[mode] = key
        for mode in Mode.allCases { defaults.set(self.key(for: mode).rawValue, forKey: "key.\(mode.rawValue)") }
    }

    func isEnabled(_ mode: Mode) -> Bool { enabled[mode] ?? true }

    /// The first enabled wheel whose key is held.
    func mode(for flags: NSEvent.ModifierFlags) -> Mode? {
        Mode.allCases.first { isEnabled($0) && flags.contains(key(for: $0).flag) }
    }

    func resetKeys() {
        for mode in Mode.allCases { setKey(mode.defaultKey, for: mode) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Toast.shared.show("Couldn't change login item: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func applyOutputFolder() {
        Output.folderOverride = switch saveLocation {
        case .nextToOriginal: nil
        case .downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .folder: customFolder
        }
    }
}

/// A system-wide shortcut via Carbon, which needs no Accessibility permission.
@MainActor
final class HotKey {
    static var handler: (() -> Void)?
    private static var installed = false
    private var reference: EventHotKeyRef?

    init?(_ combo: KeyCombo) {
        if !Self.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handler?() } }
                return noErr
            }, 1, &spec, nil, nil)
            Self.installed = true
        }
        let id = EventHotKeyID(signature: OSType(0x5357_4348), id: 1)  // 'SWCH'
        guard RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr else {
            return nil
        }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
    }
}
