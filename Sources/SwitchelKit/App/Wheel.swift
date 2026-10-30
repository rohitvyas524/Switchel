import AppKit

/// A panel under the cursor that accepts the drop, or, opened from the keyboard, takes arrow keys and clicks.
@MainActor
final class WheelController {
    var onPick: ((WheelItem, [URL]) -> Void)?

    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let panel: KeyablePanel
    private let view: WheelView
    private let glass = NSVisualEffectView()
    private var urls: [URL] = []
    private var mode: Mode = .convert
    /// Bumped on every show, so a delayed hide from an earlier drag can't close a newer wheel.
    private var generation = 0

    init() {
        view = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.size, height: WheelView.size))
        panel = KeyablePanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Glass style: a blurred material behind the wheel, masked to a circle.
        let container = NSView(frame: view.frame)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        for subview in [glass, view] {
            subview.frame = container.bounds
            subview.autoresizingMask = [.width, .height]
            container.addSubview(subview)
        }
        panel.contentView = container
        view.onDrop = { [weak self] item, urls in
            self?.hide()
            self?.onPick?(item, urls)
        }
        view.onChoose = { [weak self] item in
            guard let self else { return }
            hide()
            onPick?(item, urls)
        }
        view.onCancel = { [weak self] in self?.hide() }
        view.onCycleMode = { [weak self] in self?.cycleMode() }
    }

    /// For drags: the wheel follows the held key.
    func show(mode: Mode, urls: [URL], at point: NSPoint) {
        generation += 1
        self.mode = mode
        self.urls = urls
        view.keyboardMode = false
        present(at: point)
    }

    /// For the keyboard shortcut: the wheel takes focus.
    func showForKeyboard(urls: [URL], at point: NSPoint) {
        generation += 1
        self.urls = urls
        mode = Mode.allCases.first(where: Settings.shared.isEnabled) ?? .convert
        view.keyboardMode = true
        present(at: point)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    private func present(at point: NSPoint) {
        let items = Catalog.items(for: mode, urls: urls)
        glass.isHidden = Settings.shared.wheelStyle != .glass
        view.configure(mode: mode, items: items, fileCount: urls.count)
        let size = WheelView.size
        let center = panel.isVisible ? NSPoint(x: panel.frame.midX, y: panel.frame.midY) : point
        let screen = NSScreen.screens.first { $0.frame.contains(center) }?.visibleFrame ?? .zero
        var frame = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - size)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - size)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func cycleMode() {
        let enabled = Mode.allCases.filter(Settings.shared.isEnabled)
        guard let index = enabled.firstIndex(of: mode), enabled.count > 1 else { return }
        mode = enabled[(index + 1) % enabled.count]
        present(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Waits a moment so a drop on the wheel is delivered before the panel goes away.
    func hideAfterDragEnds() {
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation == shown, !self.view.keyboardMode else { return }
            self.hide()
        }
    }
}

final class WheelView: NSView {
    static let size: CGFloat = 400
    /// Up to nine slices fit comfortably; longer lists show seven per page plus More.
    static let maxSlices = 9
    static let itemsPerPage = 7

    private enum Slice {
        case item(WheelItem)
        case more, back

        var title: String {
            switch self {
            case .item(let item): item.title
            case .more: "More"
            case .back: "Back"
            }
        }

        var symbol: String {
            switch self {
            case .item(let item): item.symbol
            case .more: "ellipsis.circle"
            case .back: "arrow.uturn.backward.circle"
            }
        }

        var isNavigation: Bool {
            if case .item = self { return false }
            return true
        }
    }

    var onDrop: ((WheelItem, [URL]) -> Void)?
    var onChoose: ((WheelItem) -> Void)?
    var onCancel: (() -> Void)?
    var onCycleMode: (() -> Void)?
    var keyboardMode = false

    private var mode: Mode = .convert
    private var items: [WheelItem] = []
    private var page = 0
    private var slices: [Slice] = []
    private var fileCount = 0
    private var tracking: NSTrackingArea?
    private var dwell: DispatchWorkItem?
    private var highlighted: Int? {
        didSet {
            guard highlighted != oldValue else { return }
            needsDisplay = true
            scheduleDwell()
            guard highlighted != nil else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            if Settings.shared.hoverSound {
                Self.tick?.stop()
                Self.tick?.play()
            }
        }
    }

    private static let tick: NSSound? = {
        let sound = NSSound(named: "Tink")?.copy() as? NSSound
        sound?.volume = 0.25
        return sound
    }()

    private let innerRadius: CGFloat = 64
    private var outerRadius: CGFloat { bounds.width / 2 - 12 }
    private var labelRadius: CGFloat { (innerRadius + outerRadius) / 2 + 2 }
    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    func configure(mode: Mode, items: [WheelItem], fileCount: Int) {
        self.mode = mode
        self.items = items
        self.fileCount = fileCount
        show(page: 0)
    }

    private var pageCount: Int {
        items.count <= Self.maxSlices ? 1 : Int(ceil(Double(items.count) / Double(Self.itemsPerPage)))
    }

    /// Each page holds seven items plus More (or Back, on the last page).
    private func show(page: Int) {
        self.page = page
        if pageCount == 1 {
            slices = items.map(Slice.item)
        } else {
            let start = page * Self.itemsPerPage
            slices = items[start..<min(start + Self.itemsPerPage, items.count)].map(Slice.item) + [page < pageCount - 1 ? .more : .back]
        }
        highlighted = keyboardMode && !slices.isEmpty ? 0 : nil
        needsDisplay = true
    }

    private func turnPage(forward: Bool) {
        let next = forward ? (page + 1) % pageCount : 0
        show(page: next)
        if !keyboardMode { highlighted = nil }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// While dragging, resting on More or Back for a moment turns the page.
    private func scheduleDwell() {
        dwell?.cancel()
        guard !keyboardMode, let highlighted, slices.indices.contains(highlighted), slices[highlighted].isNavigation else { return }
        let forward = { if case .more = slices[highlighted] { return true } else { return false } }()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.highlighted == highlighted else { return }
            self.turnPage(forward: forward)
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func activate(_ index: Int) {
        guard slices.indices.contains(index) else { return }
        switch slices[index] {
        case .item(let item): onChoose?(item)
        case .more: turnPage(forward: true)
        case .back: turnPage(forward: false)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Geometry

    /// Slices are numbered clockwise from 12 o'clock; the hole in the middle cancels.
    private func segment(at point: NSPoint) -> Int? {
        guard !slices.isEmpty else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let radius = hypot(dx, dy)
        guard radius >= innerRadius, radius <= outerRadius + 40 else { return nil }
        var angle = atan2(dx, dy)
        if angle < 0 { angle += 2 * .pi }
        let span = 2 * .pi / CGFloat(slices.count)
        return Int((angle + span / 2) / span) % slices.count
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let outer = outerRadius
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        // Over the glass material only a light tint is needed.
        NSColor.windowBackgroundColor.withAlphaComponent(Settings.shared.wheelStyle == .glass ? 0.35 : 0.97).setFill()
        disc.fill()
        NSColor.separatorColor.setStroke()
        disc.stroke()

        let span = 360 / CGFloat(max(slices.count, 1))
        // The widest a label may be: most of its slice's arc, and no wider than the ring.
        let labelWidth = min(2 * .pi * labelRadius / CGFloat(max(slices.count, 1)) * 0.82, (outer - innerRadius) * 1.15)
        for (i, slice) in slices.enumerated() {
            // NSBezierPath angles are degrees counter-clockwise from 3 o'clock.
            let mid = 90 - CGFloat(i) * span
            let isHighlighted = i == highlighted
            if isHighlighted {
                let wedge = NSBezierPath()
                wedge.appendArc(withCenter: center, radius: outer - 5, startAngle: mid + span / 2, endAngle: mid - span / 2, clockwise: true)
                wedge.appendArc(withCenter: center, radius: innerRadius + 5, startAngle: mid - span / 2, endAngle: mid + span / 2)
                wedge.close()
                (slice.isNavigation ? NSColor.secondaryLabelColor : NSColor.controlAccentColor).setFill()
                wedge.fill()
            }
            if slices.count > 1 {
                let edge = (mid + span / 2) * .pi / 180
                let divider = NSBezierPath()
                divider.move(to: point(at: edge, radius: innerRadius + 8))
                divider.line(to: point(at: edge, radius: outer - 8))
                NSColor.separatorColor.setStroke()
                divider.stroke()
            }
            let color: NSColor = isHighlighted ? .white : slice.isNavigation ? .secondaryLabelColor : .labelColor
            drawLabel(slice, at: point(at: mid * .pi / 180, radius: labelRadius), width: labelWidth, color: color)
        }

        let hole = NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius, y: center.y - innerRadius,
                                               width: innerRadius * 2, height: innerRadius * 2))
        NSColor.controlBackgroundColor.setFill()
        hole.fill()
        NSColor.separatorColor.setStroke()
        hole.stroke()
        let key = Settings.shared.key(for: mode).symbol
        let subtitle: String
        if items.isEmpty { subtitle = "Nothing for\nthese files" }
        else if pageCount > 1 { subtitle = "Page \(page + 1) of \(pageCount)" }
        else if keyboardMode { subtitle = "⇥ next wheel" }
        else { subtitle = fileCount == 1 ? "1 file" : "\(fileCount) files" }
        drawText("\(key) \(mode.title)", font: .systemFont(ofSize: 14, weight: .bold), color: .labelColor, centeredAt: NSPoint(x: center.x, y: center.y + 10), width: innerRadius * 2)
        drawText(subtitle, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, centeredAt: NSPoint(x: center.x, y: center.y - 10), width: innerRadius * 2)
    }

    private func point(at radians: CGFloat, radius: CGFloat) -> NSPoint {
        NSPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    /// Icon over title. The title shrinks to fit the slice, then wraps onto two lines.
    private func drawLabel(_ slice: Slice, at p: NSPoint, width: CGFloat, color: NSColor) {
        var fontSize: CGFloat = 12
        func measure(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]).size().width
        }
        let title = slice.title
        while fontSize > 9.5 && measure(title) > width { fontSize -= 0.5 }
        let wraps = measure(title) > width && title.contains(" ")
        let textHeight = (fontSize + 3) * (wraps ? 2 : 1)
        let iconSize: CGFloat = 18
        let top = p.y + (iconSize + 4 + textHeight) / 2

        let config = NSImage.SymbolConfiguration(pointSize: iconSize - 2, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let symbol = NSImage(systemSymbolName: slice.symbol, accessibilityDescription: title)?.withSymbolConfiguration(config) {
            symbol.draw(at: NSPoint(x: p.x - symbol.size.width / 2, y: top - symbol.size.height), from: .zero, operation: .sourceOver, fraction: 1)
        }
        let text = wraps ? title.replacingOccurrences(of: " ", with: "\n", options: [], range: title.range(of: " ")) : title
        drawText(text, font: .systemFont(ofSize: fontSize, weight: .semibold), color: color,
                 centeredAt: NSPoint(x: p.x, y: top - iconSize - 4 - textHeight / 2), width: width)
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, centeredAt point: NSPoint, width: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let height = string.boundingRect(with: NSSize(width: width, height: 100), options: .usesLineFragmentOrigin).height
        string.draw(with: NSRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), options: .usesLineFragmentOrigin)
    }

    // MARK: Keyboard and mouse (keyboard mode)

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 123, 126: move(-1)  // ← ↑
        case 124, 125: move(1)  // → ↓
        case 48: onCycleMode?()  // ⇥
        case 36, 76: if let highlighted { activate(highlighted) }  // ↩
        case 53: onCancel?()  // ⎋
        default: super.keyDown(with: event)
        }
    }

    private func move(_ step: Int) {
        guard !slices.isEmpty else { return }
        highlighted = ((highlighted ?? -step) + step + slices.count) % slices.count
    }

    override func mouseMoved(with event: NSEvent) {
        guard keyboardMode else { return }
        if let index = segment(at: convert(event.locationInWindow, from: nil)) { highlighted = index }
    }

    override func mouseDown(with event: NSEvent) {
        guard keyboardMode else { return }
        if let index = segment(at: convert(event.locationInWindow, from: nil)) { activate(index) } else { onCancel?() }
    }

    override func resignFirstResponder() -> Bool {
        if keyboardMode { DispatchQueue.main.async { [weak self] in self?.onCancel?() } }
        return true
    }

    // MARK: Dropping

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = segment(at: convert(sender.draggingLocation, from: nil))
        guard let highlighted, !slices[highlighted].isNavigation else { return [] }
        return Self.operation(for: sender.draggingSourceOperationMask)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = highlighted, case .item(let item) = slices[index],
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        // Let the drag session finish before the panel closes.
        DispatchQueue.main.async { self.onDrop?(item, urls) }
        return true
    }

    /// Prefer operations that leave the source file where it is. Finder offers only
    /// Move while ⌘ is held, and doesn't delete the source when another app accepts it.
    private static func operation(for mask: NSDragOperation) -> NSDragOperation {
        for operation: NSDragOperation in [.copy, .generic, .link, .move] where mask.contains(operation) {
            return operation
        }
        return []
    }
}
