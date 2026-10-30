import SwiftUI

/// Entry points for the text, document and subtitle tools that need a window.
@MainActor
enum DocumentEditors {
    static func wordCount(_ urls: [URL]) async throws -> [URL] {
        var rows: [WordCountView.Row] = []
        for url in urls { rows.append(.init(file: url.lastPathComponent, stats: try await TextTools.stats(of: url))) }
        return try await ToolWindow.present("Word Count", size: CGSize(width: 560, height: 360)) { WordCountView(rows: rows, session: $0) }
    }

    static func findAndReplace(_ urls: [URL]) async throws -> [URL] {
        var preview = ""
        for url in urls { preview += try await DocumentConverter.read(url).string + "\n" }
        return try await ToolWindow.present("Find & Replace", size: CGSize(width: 520, height: 400)) { FindReplaceView(urls: urls, text: preview, session: $0) }
    }

    static func changeCase(_ urls: [URL]) async throws -> [URL] {
        let sample = String(try await DocumentConverter.read(urls[0]).string.prefix(400))
        return try await ToolWindow.present("Change Case", size: CGSize(width: 520, height: 380)) { ChangeCaseView(urls: urls, sample: sample, session: $0) }
    }

    static func cleanUp(_ urls: [URL]) async throws -> [URL] {
        try await ToolWindow.present("Clean Up Text", size: CGSize(width: 460, height: 330)) { CleanUpView(urls: urls, session: $0) }
    }

    static func shiftSubtitles(_ urls: [URL]) async throws -> [URL] {
        try await ToolWindow.present("Shift Subtitles", size: CGSize(width: 440, height: 260)) { ShiftSubtitlesView(urls: urls, session: $0) }
    }
}

private struct WordCountView: View {
    struct Row: Identifiable {
        let id = UUID()
        let file: String
        let stats: TextTools.Stats
    }

    let rows: [Row]
    @ObservedObject var session: ToolSession

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Done", sidebarWidth: nil, action: { session.run { [] } }) {
            List(rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    if rows.count > 1 { Text(row.file).font(.headline) }
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        stat("Words", row.stats.words)
                        stat("Characters", row.stats.characters)
                        stat("Characters (no spaces)", row.stats.charactersWithoutSpaces)
                        stat("Paragraphs", row.stats.paragraphs)
                        stat("Lines", row.stats.lines)
                        GridRow {
                            Text("Reading time").foregroundStyle(.secondary)
                            Text(row.stats.readingMinutes < 1 ? "Under a minute" : "\(Int(row.stats.readingMinutes.rounded())) min")
                        }
                    }
                    Button("Copy Summary") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(row.file): \(row.stats.words) words, \(row.stats.characters) characters", forType: .string)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 6)
            }
        } sidebar: { EmptyView() }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.formatted()).monospacedDigit().textSelection(.enabled)
        }
    }
}

private struct FindReplaceView: View {
    let urls: [URL]
    let text: String
    @ObservedObject var session: ToolSession
    @State private var replacement = TextTools.Replacement()

    var body: some View {
        let count = TextTools.matches(in: text, replacement)
        return ToolScaffold(session: session, actionTitle: "Replace All", canRun: count > 0, sidebarWidth: nil, action: save) {
            Form {
                TextField("Find", text: $replacement.find)
                TextField("Replace with", text: $replacement.replace)
                Toggle("Match case", isOn: $replacement.caseSensitive)
                Toggle("Whole words only", isOn: $replacement.wholeWords)
                Toggle("Regular expression", isOn: $replacement.regularExpression)
                Text(replacement.find.isEmpty ? "Type something to find." : "\(count) match\(count == 1 ? "" : "es") in \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")")
                    .foregroundStyle(count > 0 ? Color.secondary : Color.red)
                Text("Saves an edited copy; formatting in Word, RTF and Pages files is kept.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        } sidebar: { EmptyView() }
    }

    private func save() {
        let replacement = replacement
        session.run {
            var outputs: [URL] = []
            for url in urls where TextTools.matches(in: try await DocumentConverter.read(url).string, replacement) > 0 {
                outputs.append(try await TextTools.findAndReplace(url, replacement))
            }
            return outputs
        }
    }
}

private struct ChangeCaseView: View {
    let urls: [URL]
    let sample: String
    @ObservedObject var session: ToolSession
    @State private var style: TextTools.Case = .title

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save Copy", sidebarWidth: nil, action: {
            let style = style
            session.run {
                var outputs: [URL] = []
                for url in urls { outputs.append(try await TextTools.changeCase(url, to: style)) }
                return outputs
            }
        }) {
            Form {
                Picker("Change to", selection: $style) { ForEach(TextTools.Case.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.radioGroup)
                Section("Preview") {
                    Text(style.apply(sample)).lineLimit(6).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
        } sidebar: { EmptyView() }
    }
}

private struct CleanUpView: View {
    let urls: [URL]
    @ObservedObject var session: ToolSession
    @State private var options = TextTools.Cleanup()

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save Clean Copy", sidebarWidth: nil, action: {
            let options = options
            session.run {
                var outputs: [URL] = []
                for url in urls { outputs.append(try await TextTools.cleanUp(url, options)) }
                return outputs
            }
        }) {
            Form {
                Toggle("Remove spaces at the ends of lines", isOn: $options.trimTrailingSpaces)
                Toggle("Collapse repeated blank lines", isOn: $options.collapseBlankLines)
                Toggle("Remove duplicate lines", isOn: $options.removeDuplicateLines)
                Toggle("Sort lines A–Z", isOn: $options.sortLines)
            }
            .formStyle(.grouped)
        } sidebar: { EmptyView() }
    }
}

private struct ShiftSubtitlesView: View {
    let urls: [URL]
    @ObservedObject var session: ToolSession
    @State private var seconds = 0.5

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save Shifted Copy", canRun: seconds != 0, sidebarWidth: nil, action: {
            let seconds = seconds
            session.run { try urls.map { try SubtitleTools.shift($0, by: seconds) } }
        }) {
            Form {
                Stepper(value: $seconds, in: -600...600, step: 0.1) {
                    Text(seconds >= 0 ? "Later by \(String(format: "%.1f", seconds)) s" : "Earlier by \(String(format: "%.1f", -seconds)) s")
                }
                TextField("Seconds", value: $seconds, format: .number)
                Text("Use a positive number when subtitles appear too early, negative when too late.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        } sidebar: { EmptyView() }
    }
}
