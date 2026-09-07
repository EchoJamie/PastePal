import PastePalLocalization
import AppKit
import UniformTypeIdentifiers

@MainActor final class ScreenshotExportController: NSWindowController, NSWindowDelegate {
    private let source: CGImage
    private(set) var options = ScreenshotBeautyOptions()
    private(set) var renderedImage: CGImage?
    private let preview = ScreenshotExportPreview()
    private let backdrop = NSSegmentedControl(labels: ScreenshotBackdrop.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let padding = NSSlider(value: 48, minValue: 0, maxValue: 128, target: nil, action: nil)
    private let radius = NSSlider(value: 16, minValue: 0, maxValue: 48, target: nil, action: nil)
    private let shadow = NSButton(checkboxWithTitle: L("阴影"), target: nil, action: nil)
    private let dimensions = NSTextField(labelWithString: "")
    private let save = NSButton(title: L("保存 PNG…"), target: nil, action: nil)
    private(set) var didSave = false
    var onClose: (() -> Void)?
    init(image: CGImage, options: ScreenshotBeautyOptions = ScreenshotBeautyOptions(), returnToEditing: Bool = false) {
        source = image; self.options = options
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("美化并保存"); window.isReleasedWhenClosed = false; window.minSize = CGSize(width: 760, height: 480)
        super.init(window: window); window.delegate = self
        let root = ScreenshotExportBackground(); window.contentView = root
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        preview.setAccessibilityLabel(L("导出效果预览"))
        let controls = NSStackView(); controls.orientation = .vertical; controls.distribution = .fill; controls.alignment = .leading; controls.spacing = 14
        controls.setHuggingPriority(.required, for: .vertical)
        backdrop.target = self; backdrop.action = #selector(changed); backdrop.selectedSegment = options.backdrop.rawValue
        backdrop.setAccessibilityLabel(L("截图背景"))
        padding.integerValue = options.padding; padding.target = self; padding.action = #selector(changed); padding.isContinuous = false; padding.setAccessibilityLabel(L("背景留边"))
        radius.integerValue = options.cornerRadius; radius.target = self; radius.action = #selector(changed); radius.isContinuous = false; radius.setAccessibilityLabel(L("截图圆角"))
        shadow.target = self; shadow.action = #selector(changed); shadow.state = options.shadow ? .on : .off
        for (title, view) in [(L("背景"), backdrop as NSView), (L("留边"), padding), (L("圆角"), radius)] {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
            let row = NSStackView(views: [label, view]); row.orientation = .vertical; row.spacing = 8; row.alignment = .leading
            row.heightAnchor.constraint(equalToConstant: 52).isActive = true
            controls.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
            view.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        controls.addArrangedSubview(shadow)
        shadow.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let cancel = NSButton(title: returnToEditing ? L("返回编辑") : L("取消"), target: self, action: #selector(cancelled)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        save.target = self; save.action = #selector(savePressed); save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        dimensions.font = .systemFont(ofSize: 11); dimensions.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [dimensions, NSView(), cancel, save]); footer.spacing = 12
        footer.setHuggingPriority(.required, for: .vertical)
        for view in [preview, controls, footer] { root.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 24), preview.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -24),
            controls.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 24), controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            controls.widthAnchor.constraint(equalToConstant: 220), controls.topAnchor.constraint(equalTo: preview.topAnchor),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -24),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        changed(); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func showWindow(_ sender: Any?) { NSApp.activate(ignoringOtherApps: true); super.showWindow(sender); window?.makeKeyAndOrderFront(nil) }
    @objc private func changed() {
        options = ScreenshotBeautyOptions(backdrop: ScreenshotBackdrop(rawValue: backdrop.selectedSegment) ?? .original,
            padding: padding.integerValue, cornerRadius: radius.integerValue, shadow: shadow.state == .on)
        let decorated = options.backdrop != .original
        padding.isEnabled = decorated; radius.isEnabled = decorated; shadow.isEnabled = decorated
        do {
            let image = try ScreenshotBeautifier.render(source, options: options); renderedImage = image
            preview.image = NSImage(cgImage: image, size: .zero)
            dimensions.stringValue = "\(image.width) × \(image.height) px"; save.isEnabled = true
        } catch { renderedImage = nil; dimensions.stringValue = error.localizedDescription; save.isEnabled = false }
    }
    @objc private func cancelled() { close() }
    @objc private func savePressed() {
        guard let window, let image = renderedImage else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = L("截图-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-"))")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try Self.write(image, to: url); self?.didSave = true; self?.close() }
            catch {
                let alert = NSAlert(); alert.messageText = L("保存失败"); alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }
    static func write(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ScreenshotFailure.encoding }
        try data.write(to: url, options: .atomic)
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

private final class ScreenshotExportBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

private final class ScreenshotExportPreview: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
        super.draw(dirtyRect)
    }
}
