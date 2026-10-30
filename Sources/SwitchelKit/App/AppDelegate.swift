import AppKit
import SwiftUI

public enum SwitchelApp {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()
    private let wheel = WheelController()
    private var hotKey: HotKey?
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        monitor.onModeChange = { [weak self] mode, urls in
            self?.wheel.show(mode: mode, urls: urls, at: NSEvent.mouseLocation)
        }
        monitor.onDragEnd = { [weak self] in self?.wheel.hideAfterDragEnds() }
        wheel.onPick = { [weak self] item, urls in self?.run(item, on: urls) }
        monitor.start()

        HotKey.handler = { [weak self] in self?.openWheelForFinderSelection() }
        Settings.shared.onShortcutChange = { [weak self] in self?.registerShortcut() }
        registerShortcut()

        if !Settings.shared.hasCompletedWelcome { showWelcome() }
    }

    private func run(_ item: WheelItem, on urls: [URL]) {
        if !item.interactive { Toast.shared.show("\(item.title)…", sticky: true) }
        Task {
            do {
                let outputs = try await item.run(urls)
                var message = switch outputs.count {
                case 0: "\(item.title) done"
                case 1: "Saved \(outputs[0].lastPathComponent)"
                default: "Saved \(outputs.count) files"
                }
                if item.title == "Compress", let saving = Self.saving(from: urls, to: outputs) {
                    message += " · \(saving)"
                }
                Toast.shared.show(message, outputs: outputs)
                if !outputs.isEmpty {
                    if Settings.shared.playSound { NSSound(named: "Glass")?.play() }
                    if Settings.shared.revealResults { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                }
            } catch is CancellationError {
                Toast.shared.hide()
            } catch {
                Toast.shared.show(error.localizedDescription, isError: true)
            }
        }
    }

    /// "63% smaller", or nil when it didn't shrink.
    private static func saving(from inputs: [URL], to outputs: [URL]) -> String? {
        func total(_ urls: [URL]) -> Int { urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
        let before = total(inputs), after = total(outputs)
        guard before > 0, after > 0, after < before else { return nil }
        return "\(Int((1 - Double(after) / Double(before)) * 100))% smaller"
    }

    // MARK: Keyboard shortcut

    private func registerShortcut() {
        hotKey = Settings.shared.shortcut.flatMap(HotKey.init)
    }

    private func openWheelForFinderSelection() {
        Task {
            do {
                let urls = try await FinderSelection.urls()
                guard !urls.isEmpty else {
                    Toast.shared.show("Select files in Finder first")
                    return
                }
                wheel.showForKeyboard(urls: urls, at: NSEvent.mouseLocation)
            } catch {
                Toast.shared.show(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Windows

    @objc func showWelcome() {
        if welcomeWindow == nil {
            let window = makeWindow(title: "Welcome to Switchel", content: WelcomeView { [weak self] in
                self?.welcomeWindow?.close()
            })
            window.titlebarAppearsTransparent = true
            welcomeWindow = window
        }
        present(welcomeWindow)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Switchel Settings", content: SettingsView { [weak self] in
                self?.settingsWindow?.close()
                self?.showWelcome()
            })
        }
        present(settingsWindow)
    }

    @objc func newFloat() {
        FloatShelf.shared.create(with: [], near: NSPoint(x: NSScreen.main?.visibleFrame.midX ?? 600, y: NSScreen.main?.visibleFrame.midY ?? 400))
    }

    private func makeWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Switchel")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt on open so it always shows the current keys.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Drag files, then hold:", action: nil, keyEquivalent: ""))
        for mode in Mode.allCases where Settings.shared.isEnabled(mode) {
            menu.addItem(NSMenuItem(title: "   \(Settings.shared.key(for: mode).symbol)  \(mode.title)", action: nil, keyEquivalent: ""))
        }
        if let shortcut = Settings.shared.shortcut {
            menu.addItem(NSMenuItem(title: "   \(shortcut.display)  Wheel for Finder selection", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(item("New Float", #selector(newFloat)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Welcome Guide", #selector(showWelcome)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Switchel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
