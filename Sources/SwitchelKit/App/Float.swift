import AppKit
import QuickLookThumbnailing

/// Floating shelves that hold files while you move between apps.
@MainActor
final class FloatShelf {
    static let shared = FloatShelf()
    private var floats: [FloatController] = []

    func create(with urls: [URL] = [], near point: NSPoint = NSEvent.mouseLocation) {
        let float = FloatController(urls: urls, near: point)
        float.onClose = { [weak self, weak float] in self?.floats.removeAll { $0 === float } }
        floats.append(float)
    }
}

@MainActor
final class FloatController {
    var onClose: (() -> Void)?
    private let panel: NSPanel
    private let view: FloatView

    init(urls: [URL], near point: NSPoint) {
        view = FloatView(frame: NSRect(x: 0, y: 0, width: FloatView.collapsedSize.width, height: FloatView.collapsedSize.height))
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view

        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(x: min(max(point.x + 24, screen.minX), screen.maxX - view.frame.width),
                             y: min(max(point.y - view.frame.height / 2, screen.minY), screen.maxY - view.frame.height))
        panel.setFrameOrigin(origin)

        view.onResize = { [weak self] size in self?.resize(to: size) }
        view.onEmpty = { [weak self] in self?.close() }
        view.add(urls)
        panel.orderFrontRegardless()
    }

    private func resize(to size: NSSize) {
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        panel.setFrame(Self.fitted(panel.frame, to: size, on: screen), display: true, animate: true)
    }

    /// Keeps the top edge where it is, unless that would run off the bottom of the screen.
    /// Taller than the screen is capped; the list scrolls instead.
    static func fitted(_ frame: NSRect, to size: NSSize, on screen: NSRect?) -> NSRect {
        var result = frame
        result.size = size
        if let screen { result.size.height = min(size.height, screen.height - 20) }
        result.origin.y = frame.maxY - result.height
        if let screen, result.minY < screen.minY { result.origin.y = screen.minY }
        return result
    }

    func close() {
        panel.orderOut(nil)
        onClose?()
    }
}

/// Collapsed: a stack of thumbnails you drag as a group. Expanded: a list you can drag from one by one.
final class FloatView: NSView, NSDraggingSource {
    static let collapsedSize = NSSize(width: 150, height: 170)

    var onResize: ((NSSize) -> Void)?
    var onEmpty: (() -> Void)?

    private var urls: [URL] = []
    private var thumbnails: [URL: NSImage] = [:]
    private var expanded = false
    private var scrollOffset: CGFloat = 0
    private var draggedRow: Int?
    private var mouseDownPoint: NSPoint?
    private var isDropTarget = false { didSet { needsDisplay = true } }
    private let background = NSVisualEffectView()
    private let closeButton = NSButton()
    private let expandButton = NSButton()

    private let rowHeight: CGFloat = 40
    private let header: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        background.frame = bounds
        addSubview(background)

        for (button, symbol, action) in [(closeButton, "xmark", #selector(closeClicked)), (expandButton, "list.bullet", #selector(toggleExpanded))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.isBordered = false
            button.target = self
            button.action = action
            button.contentTintColor = .secondaryLabelColor
            addSubview(button)
        }
        closeButton.toolTip = "Close Float (files stay where they are)"
        expandButton.toolTip = "Show as list"
        registerForDraggedTypes([.fileURL])
        layoutButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func add(_ newURLs: [URL]) {
        let fresh = newURLs.filter { !urls.contains($0) }
        urls += fresh
        for url in fresh { loadThumbnail(url) }
        relayout()
    }

    private func remove(_ removed: [URL]) {
        urls.removeAll { removed.contains($0) }
        if urls.isEmpty { onEmpty?() } else { relayout() }
    }

    private func loadThumbnail(_ url: URL) {
        thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 220, height: 220), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                self?.thumbnails[url] = image
                self?.needsDisplay = true
            }
        }
    }

    private func relayout() {
        let size = expanded
            ? NSSize(width: 260, height: header + CGFloat(urls.count) * rowHeight + 10)
            : FloatView.collapsedSize
        onResize?(size)
        layoutButtons()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutButtons()
        scroll(by: 0)
    }

    private var maxScroll: CGFloat { max(0, header + CGFloat(urls.count) * rowHeight + 10 - bounds.height) }

    func scroll(by delta: CGFloat) {
        scrollOffset = min(max(scrollOffset + delta, 0), maxScroll)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard expanded else { return super.scrollWheel(with: event) }
        scroll(by: -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : rowHeight / 2))
    }

    private func layoutButtons() {
        closeButton.frame = NSRect(x: 8, y: 6, width: 18, height: 18)
        expandButton.frame = NSRect(x: bounds.width - 26, y: 6, width: 18, height: 18)
        expandButton.image = NSImage(systemSymbolName: expanded ? "square.stack" : "list.bullet", accessibilityDescription: nil)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        }
        expanded ? drawList() : drawStack()
    }

    private func drawStack() {
        let area = NSRect(x: 25, y: header, width: bounds.width - 50, height: 100)
        for (depth, url) in urls.prefix(3).enumerated().reversed() {
            guard let image = thumbnails[url] else { continue }
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: area.midX, yBy: area.midY)
            transform.rotate(byDegrees: CGFloat(depth) * (depth % 2 == 0 ? 5 : -5))
            transform.translateX(by: -area.midX, yBy: -area.midY)
            transform.concat()
            image.draw(in: aspectFit(image.size, in: area), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        drawText(title, in: NSRect(x: 8, y: bounds.height - 30, width: bounds.width - 16, height: 18), size: 11, centered: true)
    }

    private func drawList() {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let list = NSRect(x: 0, y: header, width: bounds.width, height: bounds.height - header)
        NSBezierPath(rect: list).setClip()
        if maxScroll > 0 {
            // A slim bar, so it's clear there's more to scroll to.
            let height = max(24, list.height * list.height / (list.height + maxScroll))
            let y = list.minY + (list.height - height) * scrollOffset / maxScroll
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.width - 6, y: y, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        for (i, url) in urls.enumerated() {
            let row = rowRect(i)
            guard row.intersects(list) else { continue }
            if let image = thumbnails[url] {
                image.draw(in: aspectFit(image.size, in: NSRect(x: row.minX + 6, y: row.minY + 4, width: 32, height: 32)),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            drawText(url.lastPathComponent, in: NSRect(x: row.minX + 46, y: row.minY + 12, width: row.width - 52, height: 18), size: 12, centered: false)
        }
    }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 4, y: header + CGFloat(index) * rowHeight - scrollOffset, width: bounds.width - 8, height: rowHeight)
    }

    /// The row under a point, ignoring rows scrolled up behind the header.
    func row(at point: NSPoint) -> Int? {
        guard point.y >= header else { return nil }
        return urls.indices.first { rowRect($0).contains(point) }
    }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat, centered: Bool) {
        let style = NSMutableParagraphStyle()
        style.alignment = centered ? .center : .left
        style.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            .draw(in: rect)
    }

    private func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        let scale = min(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { QuickLook.shared.show(urls) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, hypot(convert(event.locationInWindow, from: nil).x - start.x,
                                                convert(event.locationInWindow, from: nil).y - start.y) > 4 else { return }
        mouseDownPoint = nil
        var dragged = urls
        draggedRow = nil
        if expanded, let row = row(at: start) {
            dragged = [urls[row]]
            draggedRow = row
        }
        let items = dragged.enumerated().map { offset, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = thumbnails[url] ?? NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(NSRect(x: start.x - 32 + CGFloat(offset) * 4, y: start.y - 32 + CGFloat(offset) * 4, width: 64, height: 64), contents: image)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .stack
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quick Look", action: #selector(showQuickLook), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copyFiles), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Float without deleting files", action: #selector(closeClicked), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func showQuickLook() { MainActor.assumeIsolated { QuickLook.shared.show(urls) } }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    @objc private func copyFiles() { MainActor.assumeIsolated { FileActions.copyFiles(urls) } }
    @objc private func closeClicked() { onEmpty?() }
    func toggleExpandedForTesting() { toggleExpanded() }

    @objc private func toggleExpanded() {
        expanded.toggle()
        scrollOffset = 0
        expandButton.toolTip = expanded ? "Show as stack" : "Show as list"
        relayout()
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic, .link] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Files that landed somewhere leave the Float.
        guard !operation.isEmpty else { return }
        if let draggedRow, urls.indices.contains(draggedRow) { remove([urls[draggedRow]]) } else { remove(urls) }
    }

    // MARK: Dropping in

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? FloatView !== self else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let dropped = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        add(dropped)
        return true
    }
}
