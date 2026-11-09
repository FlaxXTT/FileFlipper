import AppKit

/// Owns the transparent floating panel that hosts the bubble arc.
final class PickerController {
    static let size: CGFloat = 280

    var onPick: ((PickerItem, [URL]) -> Void)?

    private var panel: NSPanel?
    private var arcView: BubbleArcView?
    private var urls: [URL] = []
    private var hideToken = 0

    func show(at point: NSPoint, urls: [URL], tools: Bool) {
        hideToken += 1
        self.urls = urls

        let panel = self.panel ?? makePanel()
        let size = Self.size
        var frame = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - size))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - size))
        }
        panel.setFrame(frame, display: false)
        setToolsMode(tools)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func setToolsMode(_ tools: Bool) {
        arcView?.configure(items: Catalog.items(for: urls, tools: tools), urls: urls, tools: tools)
    }

    /// Hides after a short delay so a drop that lands at the same moment
    /// the mouse is released still gets delivered to the picker.
    func hide(afterDelay delay: TimeInterval = 0) {
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == self.hideToken, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: {
                guard token == self.hideToken else { return }
                panel.orderOut(nil)
            })
        }
    }

    private func makePanel() -> NSPanel {
        let size = Self.size
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = BubbleArcView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.setBoundsSize(NSSize(width: 420, height: 420))
        view.onDrop = { [weak self] item, urls in
            guard let self else { return }
            self.hideToken += 1
            self.hide()
            self.onPick?(item, urls)
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.addSubview(view)
        panel.contentView = container

        self.panel = panel
        self.arcView = view
        return panel
    }
}
