import SwiftUI
import UniformTypeIdentifiers

/// First-launch wizard: what Switchel does, how the wheels work, keys, preferences, and a file to try.
struct WelcomeView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var page = 0
    var finish: () -> Void

    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: intro
                case 1: howItWorks
                case 2: ScrollView { KeysPane() }
                case 3: ScrollView { PreferencesPane(showsEngines: true) }
                default: tryIt
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(page)
            .transition(.opacity)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle().fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                }
                Button(page == pageCount - 1 ? "Start Using Switchel" : "Continue") {
                    if page == pageCount - 1 {
                        settings.hasCompletedWelcome = true
                        finish()
                    } else {
                        withAnimation { page += 1 }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 660, height: 560)
    }

    private var intro: some View {
        VStack(spacing: 18) {
            AppMark(size: 96)
            Text("Welcome to Switchel").font(.largeTitle.bold())
            Text("Convert, edit and share files right where you drag them.\nEverything happens on your Mac, and nothing is uploaded.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.title3)
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("How it works").font(.title.bold())
            HStack(alignment: .top, spacing: 16) {
                Step(number: 1, title: "Drag a file", detail: "From Finder, the desktop or any app.")
                Step(number: 2, title: "Hold a key", detail: "A wheel opens under the cursor.")
                Step(number: 3, title: "Drop on a slice", detail: "The result is saved; the original is untouched.")
            }
            VStack(spacing: 10) {
                ForEach(Mode.allCases) { mode in
                    HStack(spacing: 14) {
                        KeyCap(settings.key(for: mode).symbol)
                        Image(systemName: mode.symbol).frame(width: 22).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title).bold()
                            Text(mode.summary).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            Text("Drop in the middle of the wheel, or outside it, to cancel. You can change the keys on the next page.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var tryIt: some View {
        VStack(spacing: 18) {
            Text("Try it").font(.title.bold())
            Text("Drag this picture somewhere, and while you're dragging hold \(settings.key(for: .convert).symbol) \(settings.key(for: .convert).name). Drop it on PNG or JPG.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let sample = SampleFile.url {
                Image(nsImage: NSImage(contentsOf: sample) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 220, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 6, y: 3)
                    .onDrag { NSItemProvider(contentsOf: sample) ?? NSItemProvider() }
                    .help("Drag me")
            }
            Text("Switchel lives in the menu bar. Open Settings from there any time.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct Step: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number)").font(.headline).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(Circle().fill(Color.accentColor))
            Text(title).bold()
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

struct KeyCap: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Text(symbol).font(.system(size: 17, weight: .semibold))
            .frame(width: 34, height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)).shadow(color: .black.opacity(0.2), radius: 0.5, y: 1))
    }
}

struct AppMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.225).fill(
                LinearGradient(colors: [Color(red: 1, green: 0.6, blue: 0.2), Color(red: 0.9, green: 0.3, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

// MARK: Settings panes, shared by the wizard and the Settings window

struct KeysPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your keys").font(.title.bold())
            Text("Start dragging a file, then hold a key to open its wheel. Each wheel needs its own key; picking one that's taken swaps them.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Mode.allCases) { mode in
                HStack(spacing: 12) {
                    Image(systemName: mode.symbol).font(.title3).frame(width: 28).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title).bold()
                        Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(mode.title, selection: Binding(get: { settings.key(for: mode) }, set: { settings.setKey($0, for: mode) })) {
                        ForEach(WheelKey.allCases) { key in Text("\(key.symbol) \(key.name)").tag(key) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(!settings.isEnabled(mode))
                    Toggle("Enabled", isOn: Binding(get: { settings.isEnabled(mode) }, set: { settings.enabled[mode] = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            }
            HStack(spacing: 12) {
                Image(systemName: "keyboard").font(.title3).frame(width: 28).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard shortcut").bold()
                    Text("Opens a wheel for the files selected in Finder. ← → choose, Tab switches wheels, Return applies, Esc closes.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                ShortcutRecorder(combo: $settings.shortcut)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            HStack {
                Text("Finder also reacts to ⌘ and ⌥ mid-drag (move and copy). Switchel never moves or changes your original.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { settings.resetKeys() }.controlSize(.small)
            }
        }
    }
}

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? "Type a shortcut…" : combo?.display ?? "Record Shortcut") {
                recording ? stop() : start()
            }
            .frame(minWidth: 130)
            if combo != nil && !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc
                stop()
            } else if let recorded = KeyCombo(event: event) {
                combo = recorded
                stop()
            } else {
                NSSound.beep()  // Needs ⌘, ⌥ or ⌃.
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct PreferencesPane: View {
    @ObservedObject private var settings = Settings.shared
    var showsEngines = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preferences").font(.title.bold())
            Form {
                Picker("Save results", selection: $settings.saveLocation) {
                    ForEach(SaveLocation.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.saveLocation) { location in
                    if location == .folder && settings.customFolder == nil { chooseFolder() }
                }
                if settings.saveLocation == .folder {
                    HStack {
                        Text(settings.customFolder?.path ?? "No folder chosen").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Wheel style", selection: $settings.wheelStyle) {
                    ForEach(WheelStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Click sound when moving between slices", isOn: $settings.hoverSound)
                Toggle("Play a sound when done", isOn: $settings.playSound)
                Toggle("Show results in Finder", isOn: $settings.revealResults)
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                Picker("Terminal app", selection: $settings.terminal) {
                    ForEach(TerminalApp.allCases.filter { $0.isInstalled || $0 == settings.terminal }) { Text($0.title).tag($0) }
                }
            }
            .formStyle(.grouped)
            if showsEngines { EnginesPane(compact: true) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.customFolder = url
        } else if settings.customFolder == nil {
            settings.saveLocation = .nextToOriginal
        }
    }
}

/// Which optional engines are present; each unlocks a group of formats.
struct EnginesPane: View {
    var compact = false

    private struct Engine: Identifiable {
        let id: String
        let unlocks: String
        let available: Bool
        let install: String
    }

    private var engines: [Engine] {
        [
            Engine(id: "ffmpeg", unlocks: "MKV, WebM, AVI, WMV, MP3, FLAC, OGG, Opus, WMA and every audio/video tool",
                   available: FFmpeg.isAvailable, install: "brew install ffmpeg"),
            Engine(id: "cwebp", unlocks: "WebP export", available: Shell.tool("cwebp") != nil, install: "brew install webp"),
            Engine(id: "Pages", unlocks: "Pages documents", available: IWork.isInstalled(.pages), install: "Free on the Mac App Store"),
            Engine(id: "Keynote", unlocks: "PowerPoint and Keynote slides", available: IWork.isInstalled(.keynote), install: "Free on the Mac App Store"),
            Engine(id: "Numbers", unlocks: "XLS and Numbers spreadsheets", available: IWork.isInstalled(.numbers), install: "Free on the Mac App Store"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(compact ? "Optional engines" : "Engines").font(compact ? .headline : .title.bold())
            Text("Images, PDFs and most documents need nothing extra. These unlock the rest.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(engines) { engine in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: engine.available ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(engine.available ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.id).bold()
                        Text(engine.unlocks).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !engine.available {
                        Text(engine.install).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct SettingsView: View {
    var showWelcome: () -> Void

    var body: some View {
        TabView {
            ScrollView { PreferencesPane().padding(24) }
                .tabItem { Label("General", systemImage: "gearshape") }
            ScrollView { KeysPane().padding(24) }
                .tabItem { Label("Keys", systemImage: "keyboard") }
            ScrollView { EnginesPane().padding(24).frame(maxWidth: .infinity, alignment: .leading) }
                .tabItem { Label("Engines", systemImage: "shippingbox") }
            VStack(spacing: 14) {
                AppMark(size: 72)
                Text("Switchel").font(.title.bold())
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .foregroundStyle(.secondary)
                Button("Show Welcome Again", action: showWelcome)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 560)
    }
}

/// A picture to practise on, made on first use.
enum SampleFile {
    static let url: URL? = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Switchel Sample", isDirectory: true)
        let url = folder.appendingPathComponent("Try Switchel.png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ctx = try ImageConverter.context(width: 800, height: 540, alpha: false)
            let colors = ImageTools.framePresets[0].map(\.cgColor) as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 800, y: 540), options: [])
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let text = NSAttributedString(string: "Drag me!", attributes: [
                .font: NSFont.systemFont(ofSize: 96, weight: .heavy), .foregroundColor: NSColor.white,
            ])
            text.draw(at: NSPoint(x: (800 - text.size().width) / 2, y: (540 - text.size().height) / 2))
            NSGraphicsContext.restoreGraphicsState()
            guard let image = ctx.makeImage() else { return nil }
            try ImageConverter.write(image, to: url, type: .png)
            return url
        } catch {
            return nil
        }
    }()
}
