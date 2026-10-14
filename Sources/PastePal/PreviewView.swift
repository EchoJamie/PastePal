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
        let side = max(0, min(bounds.width - 80, bounds.height - 120))
        let swatch = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2 - 18, width: side, height: side)
        drawCheckerboard(in: swatch)
        NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.alpha) / 255).setFill()
        let path = NSBezierPath(roundedRect: swatch, xRadius: 18, yRadius: 18); path.fill()
        NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (label as NSString).draw(in: NSRect(x: 30, y: swatch.maxY + 22, width: bounds.width - 60, height: 28), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
    }
}
final class PreviewView: NSView {
    var onClose: (() -> Void)?
    private let contentView: NSView
    var textView: NSTextView? { (contentView as? NSScrollView)?.documentView as? NSTextView }

    init(content: ClipboardContent) {
        let title: String
        switch content.kind {
        case .image: title = L("图片预览 · \(content.width ?? 0) × \(content.height ?? 0)")
        case .file: title = L("文件预览 · \(content.fileURLs.count) 项")
        case .color: title = L("颜色预览")
        case .text: title = L("文字预览")
        }
        switch content.kind {
        case .text:
            contentView = Self.makeTextView(content.text ?? "")
        case .file:
            let lines = content.fileURLs.map { url in
                let state = FileManager.default.fileExists(atPath: url.path) ? "" : L("  [已移动或删除]")
                return "\(url.lastPathComponent)\(state)\n\(url.path)"
            }
            contentView = Self.makeTextView(lines.joined(separator: "\n\n"))
        case .color:
            if let value = content.text, let color = ContentCodec.color(from: value) {
                contentView = PreviewColorView(color: color, label: value.trimmingCharacters(in: .whitespacesAndNewlines))
            } else { contentView = NSView() }
        case .image:
            if let image = Self.firstFrame(in: content.representations) {
                contentView = PreviewImageView(image: image)
            } else { contentView = NSView() }
        }
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let close = NSButton()
        close.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        close.target = self; close.action = #selector(closePreview)
        close.isBordered = false; close.focusRingType = .none
        close.toolTip = L("收起预览（Esc）"); close.setAccessibilityLabel(L("收起预览（Esc）"))
        let separator = NSBox(); separator.boxType = .separator
        for view in [label, close, contentView, separator] {
            addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        }
        let width = contentView.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: centerXAnchor), width,
            contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 1100),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            close.widthAnchor.constraint(equalToConstant: 28), close.heightAnchor.constraint(equalToConstant: 28),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func closePreview() { onClose?() }
    private static func makeTextView(_ value: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 360))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 15)
        text.textColor = .labelColor; text.backgroundColor = .textBackgroundColor; text.string = value
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        return scroll
    }
    private static func firstFrame(in representations: [Representation]) -> NSImage? {
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
