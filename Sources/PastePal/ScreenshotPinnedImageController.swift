import PastePalLocalization
import AppKit

@MainActor final class ScreenshotPinnedImageController: NSWindowController, NSWindowDelegate {
    private(set) var zoom: ScreenshotPinnedZoom
    private let imageView: ScreenshotPinnedView
    var onClose: (() -> Void)?

    init(image: CGImage, originalFrame: CGRect? = nil) {
        let pixels = CGSize(width: image.width, height: image.height)
        let sourceFrame = originalFrame.flatMap { frame in
            frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0 ? frame : nil
        }
        let size = sourceFrame?.size ?? pixels
        zoom = ScreenshotPinnedZoom(originalSize: size)
        imageView = ScreenshotPinnedView(image: NSImage(cgImage: image, size: size), displaySize: size)
        let window = ScreenshotPinnedPanel(contentRect: CGRect(origin: .zero, size: zoom.windowSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = L("贴图 · \(image.width) × \(image.height)")
        window.level = .floating; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        super.init(window: window); window.delegate = self
        imageView.onClose = { [weak self] in self?.close() }
        imageView.onScroll = { [weak self] event in self?.scroll(event) }
        imageView.onExit = { [weak self] in self?.zoom.resetScroll() }
        let menu = NSMenu()
        menu.addItem(withTitle: L("恢复原始大小（100%）"), action: #selector(resetZoom), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for (title, value) in [(L("不透明"), 100), (L("75% 不透明度"), 75), (L("50% 不透明度"), 50)] {
            let item = menu.addItem(withTitle: title, action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = value; item.target = self; item.state = value == 100 ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("关闭贴图"), action: #selector(closePin), keyEquivalent: "").target = self
        imageView.menu = menu
        window.contentView = imageView
        if let sourceFrame {
            window.setFrameOrigin(CGPoint(x: sourceFrame.midX - zoom.windowSize.width / 2,
                                          y: sourceFrame.midY - zoom.windowSize.height / 2))
        } else { window.center() }
        updateImage()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func scroll(_ event: NSEvent) {
        guard let window, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) { zoom.resetScroll() }
        let changed = zoom.scroll(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { zoom.resetScroll() }
        guard changed else { return }
        let anchor = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrame(zoom.frame(anchoredAt: anchor, in: window.frame), display: true)
        updateImage()
    }
    @objc private func resetZoom() {
        guard let window else { return }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        zoom.reset()
        window.setFrame(zoom.frame(anchoredAt: center, in: window.frame), display: true)
        updateImage()
    }
    private func updateImage() {
        imageView.displaySize = zoom.imageSize
        imageView.toolTip = L("\(Int((zoom.scale * 100).rounded()))% · 滚轮缩放 · 双击关闭")
        imageView.setAccessibilityValue(L("缩放 \(Int((zoom.scale * 100).rounded()))%"))
    }
    @objc private func setOpacity(_ item: NSMenuItem) {
        window?.alphaValue = CGFloat(item.tag) / 100
        imageView.menu?.items.filter { $0.action == #selector(setOpacity(_:)) }.forEach {
            $0.state = $0 === item ? .on : .off
        }
    }
    @objc private func closePin() { close() }
    func windowWillClose(_ notification: Notification) {
        let callback = onClose; onClose = nil; callback?()
    }
}

private final class ScreenshotPinnedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") { close() }
        else { super.keyDown(with: event) }
    }
}

private final class ScreenshotPinnedView: NSView {
    private let image: NSImage
    var displaySize: CGSize { didSet { needsDisplay = true } }
    var onScroll: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?

    init(image: NSImage, displaySize: CGSize) {
        self.image = image; self.displaySize = displaySize
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel(L("置顶截图"))
        setAccessibilityHelp(L("拖动移动，滚轮缩放，双击关闭，右键调整透明度或恢复原始大小"))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        image.draw(in: CGRect(x: bounds.midX - displaySize.width / 2, y: bounds.midY - displaySize.height / 2,
                              width: displaySize.width, height: displaySize.height))
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { onClose?() }
        else { window?.performDrag(with: event) }
    }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        tracking = area; addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
