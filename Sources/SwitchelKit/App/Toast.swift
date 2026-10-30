import AppKit

/// A small HUD near the cursor for progress and results. Clicking it reveals the outputs.
@MainActor
final class Toast: NSObject {
    static let shared = Toast()

    private var panel: NSPanel?
    private var outputs: [URL] = []
    private var hideTask: DispatchWorkItem?

    func show(_ message: String, outputs: [URL] = [], isError: Bool = false, sticky: Bool = false) {
        hideTask?.cancel()
        panel?.orderOut(nil)
        self.outputs = outputs

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = isError ? .systemRed : .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        let width = min(max(label.fittingSize.width + 32, 160), 420)
        let height: CGFloat = 40

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? .zero
        var frame = NSRect(x: mouse.x + 16, y: mouse.y - height - 24, width: width, height: height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - height)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.frame = NSRect(x: 16, y: (height - label.fittingSize.height) / 2,
                             width: width - 32, height: label.fittingSize.height)
        background.addSubview(label)
        background.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = background
        panel.orderFrontRegardless()
        self.panel = panel

        guard !sticky else { return }
        let task = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 6 : 4), execute: task)
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    @objc private func clicked() {
        if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        panel?.orderOut(nil)
    }
}
