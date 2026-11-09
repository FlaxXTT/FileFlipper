import AppKit
import QuartzCore

/// Circular drag destination. The centre cancels; each sector selects one action.
final class BubbleArcView: NSView {
    var onDrop: ((PickerItem, [URL]) -> Void)?
    private var items: [PickerItem] = []
    private var urls: [URL] = []
    private var isTools = false
    private var glassSectors: [NSVisualEffectView] = []
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            toolTip = hovered.flatMap { items[$0].detail }
            needsDisplay = true
            if hovered != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }
    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private let outer: CGFloat = 190
    private let inner: CGFloat = 76

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [PickerItem], urls: [URL], tools: Bool) {
        self.items = items
        self.urls = urls
        isTools = tools
        hovered = nil
        glassSectors.forEach { $0.removeFromSuperview() }
        glassSectors = items.indices.map { index in
            let glass = NSVisualEffectView(frame: frame)
            glass.material = .popover
            glass.appearance = NSAppearance(named: .aqua)
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.alphaValue = 0.72
            glass.wantsLayer = true
            let mask = CAShapeLayer()
            mask.frame = glass.bounds
            var scale = CGAffineTransform(scaleX: frame.width / bounds.width, y: frame.height / bounds.height)
            mask.path = sectorPath(index).cgPath.copy(using: &scale)
            glass.layer?.mask = mask
            superview?.addSubview(glass, positioned: .below, relativeTo: self)
            return glass
        }
        updateAccessibility()
        needsDisplay = true
    }

    private func index(at point: NSPoint) -> Int? {
        items.indices.first { sectorPath($0).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - outer - 5, y: center.y - outer - 5,
                                               width: (outer + 5) * 2, height: (outer + 5) * 2))
        NSColor.white.withAlphaComponent(0.65).setStroke()
        disc.lineWidth = 1.5
        disc.stroke()
        for index in items.indices { drawSector(index) }
        drawCenter()
    }

    private func sectorPath(_ index: Int) -> NSBezierPath {
        let step = 360.0 / CGFloat(items.count)
        let mid = 90 - CGFloat(index) * step
        let gap = min(2.0, step * 0.08)
        let start = mid - step / 2 + gap, end = mid + step / 2 - gap
        let outside = outer - 6, inside = inner + 4
        let corner: CGFloat = min(12, inside * (end - start) * .pi / 720)
        let outerAngle = corner / outside * 180 / .pi
        let innerAngle = corner / inside * 180 / .pi
        func point(_ radius: CGFloat, _ degrees: CGFloat) -> NSPoint {
            let angle = degrees * .pi / 180
            return NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        let path = NSBezierPath()
        func rounded(to endPoint: NSPoint, through control: NSPoint) {
            let startPoint = path.currentPoint
            let c1 = NSPoint(x: startPoint.x + (control.x - startPoint.x) * 2 / 3,
                             y: startPoint.y + (control.y - startPoint.y) * 2 / 3)
            let c2 = NSPoint(x: endPoint.x + (control.x - endPoint.x) * 2 / 3,
                             y: endPoint.y + (control.y - endPoint.y) * 2 / 3)
            path.curve(to: endPoint, controlPoint1: c1, controlPoint2: c2)
        }
        path.move(to: point(outside, start + outerAngle))
        path.appendArc(withCenter: center, radius: outside, startAngle: start + outerAngle, endAngle: end - outerAngle, clockwise: false)
        rounded(to: point(outside - corner, end), through: point(outside, end))
        path.line(to: point(inside + corner, end))
        rounded(to: point(inside, end - innerAngle), through: point(inside, end))
        path.appendArc(withCenter: center, radius: inside, startAngle: end - innerAngle, endAngle: start + innerAngle, clockwise: true)
        rounded(to: point(inside + corner, start), through: point(inside, start))
        path.line(to: point(outside - corner, start))
        rounded(to: point(outside, start + outerAngle), through: point(outside, start))
        path.close()
        return path
    }

    private func drawSector(_ index: Int) {
        let mid = 90 - CGFloat(index) * 360.0 / CGFloat(items.count)
        let path = sectorPath(index)
        path.lineJoinStyle = .round
        // The view behind this shape blurs the desktop; these translucent highlights
        // add a thin glass surface without covering it with a solid colour.
        let selected = hovered == index
        let top = NSColor.white.withAlphaComponent(selected ? 0.38 : 0.18)
        let bottom = NSColor.white.withAlphaComponent(selected ? 0.18 : 0.05)
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 115)
        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor.white.withAlphaComponent(0.48)
        glow.shadowBlurRadius = 5
        glow.shadowOffset = .zero
        glow.set()
        NSColor.white.withAlphaComponent(selected ? 1.0 : 0.78).setStroke()
        path.lineWidth = 1.4
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
        let sheen = NSGradient(starting: NSColor.white.withAlphaComponent(0.30),
                               ending: NSColor.white.withAlphaComponent(0.0))
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        let highlight = NSRect(x: path.bounds.minX, y: path.bounds.midY,
                               width: path.bounds.width, height: path.bounds.height / 2)
        sheen?.draw(in: highlight, angle: 90)
        NSGraphicsContext.current?.restoreGraphicsState()

        let radians = mid * .pi / 180
        let radius = (outer + inner) / 2
        let point = NSPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
        let color: NSColor = .black
        let item = items[index]
        let symbolName = item.symbol ?? Catalog.formatSymbol(for: item.title)
        let showIcon = isTools
        if showIcon, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: item.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) {
            image.draw(in: NSRect(x: point.x - 10, y: point.y + 2, width: 20, height: 20))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: items.count > 8 ? 14 : 16, weight: .bold), .foregroundColor: color, .paragraphStyle: paragraph])
        text.draw(in: NSRect(x: point.x - 43, y: point.y - (showIcon ? 17 : 8), width: 86, height: 20))
    }

    private func drawCenter() {
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - inner + 5, y: center.y - inner + 5,
                                                 width: (inner - 5) * 2, height: (inner - 5) * 2))
        NSColor.white.withAlphaComponent(0.24).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
        let icon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 36, weight: .light)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.black])))
        icon?.draw(in: NSRect(x: center.x - 20, y: center.y + 5, width: 40, height: 40))
        let value: String
        if let hovered { value = items[hovered].title }
        else if items.isEmpty { value = L("Unsupported selection") }
        else if let first = urls.first, urls.count == 1 { value = FileInfo.sizeString(of: first) }
        else { value = L("%@ files", String(urls.count)) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
        NSAttributedString(string: value, attributes: attrs).draw(in: NSRect(x: center.x - 60, y: center.y - 22, width: 120, height: 20))
        let description = hovered.flatMap { items[$0].detail }
        let name = description ?? (urls.count == 1 ? (urls.first?.lastPathComponent ?? "") : (isTools ? L("TOOLS") : L("CONVERT")))
        let detailParagraph = NSMutableParagraphStyle()
        detailParagraph.alignment = .center
        detailParagraph.lineBreakMode = description == nil ? .byTruncatingMiddle : .byWordWrapping
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.black, .paragraphStyle: detailParagraph]
        NSAttributedString(string: name, attributes: small).draw(in: NSRect(x: center.x - 61, y: center.y - (description == nil ? 43 : 62), width: 122, height: description == nil ? 18 : 42))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hovered != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = hovered, items.indices.contains(index) else { return false }
        let item = items[index]
        let dropped = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let targets = dropped.isEmpty ? urls : dropped
        hovered = nil
        DispatchQueue.main.async { [weak self] in self?.onDrop?(item, targets) }
        return true
    }
    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = index(at: convert(sender.draggingLocation, from: nil))
        guard hovered != nil else { return [] }
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        return []
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.orderOut(nil); return }
        guard !items.isEmpty else { return }
        switch event.keyCode {
        case 123, 126: hovered = ((hovered ?? 0) + items.count - 1) % items.count
        case 124, 125, 48: hovered = ((hovered ?? -1) + 1) % items.count
        case 36, 49: if let hovered { onDrop?(items[hovered], urls) }
        default: super.keyDown(with: event)
        }
    }

    private func updateAccessibility() {
        setAccessibilityElement(false)
        let children = items.indices.map { index -> RingAction in
            let action = RingAction()
            action.setAccessibilityRole(.button)
            action.setAccessibilityLabel(items[index].title)
            action.setAccessibilityHelp(items[index].detail)
            action.setAccessibilityParent(self)
            let rect = convert(sectorPath(index).bounds, to: nil)
            action.setAccessibilityFrame(window?.convertToScreen(rect) ?? rect)
            action.press = { [weak self] in
                guard let self, self.items.indices.contains(index) else { return }
                self.onDrop?(self.items[index], self.urls)
            }
            return action
        }
        setAccessibilityChildren(children)
    }
}

private final class RingAction: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
}
