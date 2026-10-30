import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum PDFEditors {
    static func organize(_ url: URL) async throws -> [URL] {
        _ = try PDFConverter.open(url)
        return try await ToolWindow.present("Organize \(url.lastPathComponent)", size: CGSize(width: 920, height: 660)) { PDFOrganizerView(url: url, session: $0) }
    }

    static func split(_ url: URL) async throws -> [URL] {
        let doc = try PDFConverter.open(url)
        return try await ToolWindow.present("Split \(url.lastPathComponent)", size: CGSize(width: 460, height: 320)) { PDFSplitView(url: url, pageCount: doc.pageCount, session: $0) }
    }

    /// Asks how pages should become Word, Pages or PowerPoint, then converts every file.
    static func convertToOffice(_ urls: [URL], format: PDFFormat) async throws -> [URL] {
        try await ToolWindow.present("Convert to \(format.rawValue.uppercased())", size: CGSize(width: 520, height: 330)) { session in
            OfficeLayoutView(urls: urls, format: format, session: session)
        }
    }
}

// MARK: Organize

/// Reorder by dragging, rotate, delete, and add pages from other PDFs.
private struct PDFOrganizerView: View {
    let url: URL
    @ObservedObject var session: ToolSession
    @State private var pages: [PDFTools.PageEdit]
    @State private var thumbnails: [UUID: NSImage] = [:]
    @State private var dragging: UUID?

    init(url: URL, session: ToolSession) {
        self.url = url
        self.session = session
        let count = PDFDocument(url: url)?.pageCount ?? 0
        _pages = State(initialValue: (0..<count).map { PDFTools.PageEdit(source: url, index: $0) })
    }

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Save Organized PDF", canRun: !pages.isEmpty, sidebarWidth: nil, action: save) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Drag pages to reorder. Hover a page to rotate or remove it. \(pages.count) pages; the original is untouched.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add PDF…", action: addPDF)
                }
                .padding([.horizontal, .top], 16)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                        ForEach(pages) { page in tile(page) }
                    }
                    .padding(16)
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { dropped, _ in
                            guard let dropped, dropped.pathExtension.lowercased() == "pdf" else { return }
                            DispatchQueue.main.async { append(dropped) }
                        }
                    }
                    return true
                }
            }
            .task { loadThumbnails() }
        } sidebar: { EmptyView() }
    }

    private func tile(_ page: PDFTools.PageEdit) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: thumbnails[page.id] ?? NSImage())
                .resizable().aspectRatio(contentMode: .fit)
                .rotationEffect(.degrees(Double(page.rotation)))
                .frame(width: 140, height: 160)
                .background(Color.white)
                .shadow(radius: 2, y: 1)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 2) {
                        Button { rotate(page) } label: { Image(systemName: "rotate.right") }
                        Button { pages.removeAll { $0.id == page.id } } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).padding(4)
                }
            Text(page.source == url ? "Page \(page.index + 1)" : "\(page.source.deletingPathExtension().lastPathComponent) p\(page.index + 1)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .opacity(dragging == page.id ? 0.4 : 1)
        .onDrag {
            dragging = page.id
            return NSItemProvider(object: page.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDelegate(target: page, pages: $pages, dragging: $dragging))
    }

    private func loadThumbnails() {
        var documents: [URL: PDFDocument] = [:]
        for page in pages where thumbnails[page.id] == nil {
            if documents[page.source] == nil { documents[page.source] = PDFDocument(url: page.source) }
            thumbnails[page.id] = documents[page.source]?.page(at: page.index)?.thumbnail(of: NSSize(width: 240, height: 240), for: .mediaBox)
        }
    }

    private func addPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(append)
    }

    private func append(_ other: URL) {
        guard let doc = PDFDocument(url: other), !doc.isLocked else {
            session.error = "Couldn't open \(other.lastPathComponent)"
            return
        }
        pages += (0..<doc.pageCount).map { PDFTools.PageEdit(source: other, index: $0) }
        loadThumbnails()
    }

    private func rotate(_ page: PDFTools.PageEdit) {
        guard let i = pages.firstIndex(where: { $0.id == page.id }) else { return }
        pages[i].rotation = (pages[i].rotation + 90) % 360
    }

    private func save() {
        let pages = pages
        session.run { [try PDFTools.rearrange(url, pages: pages)] }
    }
}

private struct ReorderDelegate: DropDelegate {
    let target: PDFTools.PageEdit
    @Binding var pages: [PDFTools.PageEdit]
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target.id,
              let from = pages.firstIndex(where: { $0.id == dragging }),
              let to = pages.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation { pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: Split

private struct PDFSplitView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case everyPage, everyN, ranges
        var id: Self { self }
        var title: String {
            switch self {
            case .everyPage: "Every page"
            case .everyN: "Every N pages"
            case .ranges: "Page ranges"
            }
        }
    }

    let url: URL
    let pageCount: Int
    @ObservedObject var session: ToolSession
    @State private var mode: Mode = .everyPage
    @State private var n = 2
    @State private var ranges = ""

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Split", sidebarWidth: nil, action: save) {
            Form {
                LabeledContent("Pages", value: "\(pageCount)")
                Picker("Split", selection: $mode) { ForEach(Mode.allCases) { Text($0.title).tag($0) } }
                switch mode {
                case .everyPage: EmptyView()
                case .everyN: Stepper("Every \(n) pages", value: $n, in: 1...max(pageCount, 1))
                case .ranges:
                    TextField("Ranges", text: $ranges, prompt: Text("1-3, 4, 5-\(pageCount)"))
                    Text("Each range becomes its own PDF.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } sidebar: { EmptyView() }
    }

    private func save() {
        let split: PDFTools.SplitMode = switch mode {
        case .everyPage: .everyPage
        case .everyN: .every(n)
        case .ranges: .ranges(ranges)
        }
        session.run { [try PDFTools.split(url, split)] }
    }
}

// MARK: PDF → Office layout

private struct OfficeLayoutView: View {
    let urls: [URL]
    let format: PDFFormat
    @ObservedObject var session: ToolSession
    @AppStorage("officeLayout") private var layout: OfficeLayout = .editable

    var body: some View {
        ToolScaffold(session: session, actionTitle: "Convert", sidebarWidth: nil, action: convert) {
            VStack(alignment: .leading, spacing: 14) {
                Text("How should the pages come across?").font(.headline)
                choice(.editable, title: "Editable text",
                       detail: "Selectable, editable text with headings kept. Pictures and complex layouts may be simplified.")
                choice(.exact, title: "Exact pages",
                       detail: "Every page as a sharp image, including tables, equations and scans. Looks identical, but text can't be edited.")
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } sidebar: { EmptyView() }
    }

    private func choice(_ option: OfficeLayout, title: String, detail: String) -> some View {
        Button { layout = option } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: layout == option ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(layout == option ? Color.accentColor : .secondary).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).bold()
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(layout == option ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func convert() {
        let layout = layout
        session.run {
            var outputs: [URL] = []
            for url in urls { outputs.append(try await PDFConverter.convert(url, to: format, layout: layout)) }
            return outputs
        }
    }
}
