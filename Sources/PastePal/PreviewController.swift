import PastePalLocalization
import AppKit
import ClipboardCore
import ImageIO

final class PreviewImageView: NSView {
    let image: NSImage
    init(image: NSImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { drawCheckerboard(in: bounds); drawAspectFit(image, in: bounds.insetBy(dx: 16, dy: 16)) }
}
final class PreviewColorView: NSView {
    let color: ClipboardColor
    let label: String
    init(color: ClipboardColor, label: String) { self.color = color; self.label = label; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let side = min(bounds.width - 80, bounds.height - 120)
        let swatch = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2 - 18, width: side, height: side)
        drawCheckerboard(in: swatch)
        NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.alpha) / 255).setFill()
        let path = NSBezierPath(roundedRect: swatch, xRadius: 18, yRadius: 18); path.fill()
        NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (label as NSString).draw(in: NSRect(x: 30, y: swatch.maxY + 22, width: bounds.width - 60, height: 28), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
    }
}
final class PreviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}
final class PreviewController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    init(content: ClipboardContent) {
        let window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        switch content.kind {
        case .image: window.title = L("图片预览 · \(content.width ?? 0) × \(content.height ?? 0)")
        case .file: window.title = L("文件预览 · \(content.fileURLs.count) 项")
        case .color: window.title = L("颜色预览")
        case .text: window.title = L("文字预览")
        }
        window.level = .floating; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        switch content.kind {
        case .text:
            window.contentView = textView(content.text ?? "", frame: window.contentView!.bounds)
        case .file:
            let lines = content.fileURLs.map { url in
                let state = FileManager.default.fileExists(atPath: url.path) ? "" : L("  [已移动或删除]")
                return "\(url.lastPathComponent)\(state)\n\(url.path)"
            }
            window.contentView = textView(lines.joined(separator: "\n\n"), frame: window.contentView!.bounds)
        case .color:
            if let value = content.text, let color = ContentCodec.color(from: value) {
                window.contentView = PreviewColorView(color: color, label: value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case .image:
            if let image = firstFrame(in: content.representations) {
                window.contentView = PreviewImageView(image: image)
            }
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { onClose?() }
    private func textView(_ value: String, frame: NSRect) -> NSScrollView {
        let scroll = NSScrollView(frame: frame)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 15)
        text.textColor = .labelColor; text.backgroundColor = .textBackgroundColor; text.string = value
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        return scroll
    }
    private func firstFrame(in representations: [Representation]) -> NSImage? {
        for value in representations {
            guard let source = CGImageSourceCreateWithData(value.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_600,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { continue }
            return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        }
        return nil
    }
}
