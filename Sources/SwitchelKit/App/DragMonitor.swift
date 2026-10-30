import AppKit

/// Watches file drags in any app (and our own Float and welcome windows) and reports
/// when a wheel's key is held mid-drag.
///
/// Mouse monitors and `NSEvent.modifierFlags` need no Accessibility permission.
/// Once a drag starts we poll at 30 Hz, because other apps' drag loops may stop
/// sending us drag events, and modifier changes arrive only as key events (which do need it).
@MainActor
final class DragMonitor {
    /// Called when a wheel's key is first pressed during a file drag, and again if it changes.
    var onModeChange: ((Mode, [URL]) -> Void)?
    /// Called when the mouse is released after a wheel was shown.
    var onDragEnd: (() -> Void)?

    private var monitors: [Any] = []
    private var timer: Timer?
    private var changeCountAtMouseDown = 0
    private var urls: [URL] = []
    private var mode: Mode?

    func start() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.startPolling() }
        }
        let localDown = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown() }
            return event
        }
        let localDrag = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            MainActor.assumeIsolated { self?.startPolling() }
            return event
        }
        monitors = [down, drag, localDown, localDrag].compactMap { $0 }
    }

    private func mouseDown() {
        reset()
        changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { finish(); return }
        if urls.isEmpty {
            // The source writes the drag pasteboard as the drag begins; until then it's stale.
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != changeCountAtMouseDown else { return }
            urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return }
        }
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let next = Settings.shared.mode(for: flags), next != mode {
            mode = next
            onModeChange?(next, urls)
        }
    }

    private func finish() {
        let wasShowing = mode != nil
        reset()
        if wasShowing { onDragEnd?() }
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        urls = []
        mode = nil
    }
}
