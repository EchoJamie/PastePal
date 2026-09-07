import PastePalLocalization
import AppKit
import ClipboardCore
import UniformTypeIdentifiers
import ImageIO

enum CardGroupDrag {
    static let pasteboardType = NSPasteboard.PasteboardType("local.pastepal.card-group-entry")
}

private enum CardLayout {
    static let inset: CGFloat = 3
    static let cornerRadius: CGFloat = 12
    static let headerHeight: CGFloat = 46
    static let footerHeight: CGFloat = 29
}

final class CardItem: NSCollectionViewItem {
    let card = CardView()
    override func loadView() { card.focusRingType = .none; view = card }
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard let image = card.makeDragPreview() else { return [] }
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = NSRect(origin: .zero, size: image.size)
        return [component]
    }
    override var isSelected: Bool { didSet { card.selected = isSelected } }
    override func prepareForReuse() {
        super.prepareForReuse()
        clearContent()
    }
    func clearContent() {
        card.entry = nil
        card.positionShortcut = nil
        card.picture = nil; card.fileIcon = nil; card.sourceIcon = nil
        card.linkIcon = nil; card.linkPicture = nil; card.toolTip = nil
        card.needsDisplay = true
    }
    func configure(_ entry: HistoryEntry, thumbnail: URL?, sourceIcon: URL?, linkIcon: URL?, linkPreview: URL?, imageCache: CardImageCache, number: Int) {
        card.entry = entry
        card.number = number
        card.picture = imageCache.image(at: thumbnail, maximumPixelSize: 480)
        card.fileIcon = entry.fileURLs.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
        card.sourceIcon = imageCache.image(at: sourceIcon, maximumPixelSize: 96)
            ?? entry.source.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
        card.linkIcon = imageCache.image(at: linkIcon, maximumPixelSize: 96)
        card.linkPicture = imageCache.image(at: linkPreview, maximumPixelSize: 480)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.button)
        card.setAccessibilityLabel(accessibilityLabel(entry))
        card.toolTip = [CardSourcePresentation.detail(entry.source), entry.hasMissingFiles ? L("文件已移动或删除") : nil].compactMap { $0 }.joined(separator: " · ")
        card.needsDisplay = true
    }
    private func accessibilityLabel(_ entry: HistoryEntry) -> String {
        let source = CardSourcePresentation.accessibilitySuffix(entry.source)
        switch entry.kind {
        case .image: return L("图片，\(entry.width ?? 0) 乘 \(entry.height ?? 0) 像素\(source)")
        case .file: return L("\(entry.fileURLs.count) 个文件，\(entry.text ?? "")\(entry.hasMissingFiles ? L("，文件已移动或删除") : "")\(source)")
        case .color: return L("颜色，\(entry.text ?? "")\(source)")
        case .text:
            if let host = entry.linkURL?.host {
                return L("链接，\(entry.linkMetadata?.title ?? host)，\(host)\(source)")
            }
            return L("文字，\(String((entry.text ?? "").prefix(100)))\(source)")
        }
    }
}

final class CardImageCache {
    private let cache = NSCache<NSString, NSImage>()
    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 24 * 1_024 * 1_024
    }
    func image(at url: URL?, maximumPixelSize: Int) -> NSImage? {
        guard let url else { return nil }
        let key = "\(url.path)#\(maximumPixelSize)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let value = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(value, forKey: key, cost: image.bytesPerRow * image.height)
        return value
    }
}

struct CardTextLayoutMetrics {
    let lineCount: Int
    let isTruncated: Bool
    let usedRect: NSRect
}

enum CardTextLayout {
    static func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let layout = makeLayout(text, size: rect.size, font: font, color: color)
        withExtendedLifetime(layout.storage) {
            let glyphRange = layout.manager.glyphRange(for: layout.container)
            layout.manager.drawGlyphs(forGlyphRange: glyphRange, at: rect.origin)
        }
    }

    static func metrics(_ text: String, size: NSSize, font: NSFont) -> CardTextLayoutMetrics {
        let layout = makeLayout(text, size: size, font: font, color: .labelColor)
        return withExtendedLifetime(layout.storage) {
            let glyphRange = layout.manager.glyphRange(for: layout.container)
            var lineCount = 0
            var isTruncated = false
            layout.manager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, _ in
                lineCount += 1
                if layout.manager.truncatedGlyphRange(inLineFragmentForGlyphAt: lineGlyphRange.location).location != NSNotFound {
                    isTruncated = true
                }
            }
            return CardTextLayoutMetrics(
                lineCount: lineCount,
                isTruncated: isTruncated,
                usedRect: layout.manager.usedRect(for: layout.container)
            )
        }
    }

    private static func makeLayout(_ text: String, size: NSSize, font: NSFont, color: NSColor) -> (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 1
        let storage = NSTextStorage(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        let container = NSTextContainer(size: size)
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byTruncatingTail
        let lineHeight = manager.defaultLineHeight(for: font) + paragraph.lineSpacing
        container.maximumNumberOfLines = max(1, Int(floor((size.height + paragraph.lineSpacing) / lineHeight)))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return (storage, manager, container)
    }
}

enum CardSourcePresentation {
    static func detail(_ source: SourceApplication?) -> String {
        guard let source else { return L("来源未知") }
        return source.attribution == .foreground ? L("推定来源：\(source.name)") : L("复制来源：\(source.name)")
    }

    static func accessibilitySuffix(_ source: SourceApplication?) -> String {
        guard let source else { return L("，来源未知") }
        return source.attribution == .foreground ? L("，推定来自\(source.name)") : L("，复制自\(source.name)")
    }

    static func fallbackIconName(_ source: SourceApplication?) -> String {
        source == nil ? "questionmark.app.dashed" : "app.dashed"
    }
}

final class CardView: NSView {
    var entry: HistoryEntry?
    var number = 0
    var positionShortcut: String? { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true; setAccessibilitySelected(selected) } }
    var picture: NSImage?
    var fileIcon: NSImage?
    var sourceIcon: NSImage?
    var linkIcon: NSImage?
    var linkPicture: NSImage?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    func makeDragPreview() -> NSImage? {
        guard bounds.width > 0, let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        let original = NSImage(size: bounds.size)
        original.addRepresentation(bitmap)
        let size = NSSize(width: min(108, bounds.width), height: min(108, bounds.width) * bounds.height / bounds.width)
        return NSImage(size: size, flipped: false) { rect in
            original.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.32)
            return true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }
        let cardRect = bounds.insetBy(dx: CardLayout.inset, dy: CardLayout.inset)
        let outline = NSBezierPath(roundedRect: cardRect, xRadius: CardLayout.cornerRadius, yRadius: CardLayout.cornerRadius)
        let header = NSRect(x: cardRect.minX, y: cardRect.minY, width: cardRect.width, height: CardLayout.headerHeight)
        let footer = NSRect(x: cardRect.minX, y: cardRect.maxY - CardLayout.footerHeight, width: cardRect.width, height: CardLayout.footerHeight)
        let body = NSRect(x: cardRect.minX, y: header.maxY, width: cardRect.width, height: footer.minY - header.maxY)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        cardSurface.setFill(); outline.fill()
        sourceColor(entry.source?.bundleID).setFill(); header.fill()
        let title = cardTitle(entry)
        drawText(title, rect: NSRect(x: cardRect.minX + 12, y: cardRect.minY + 8, width: cardRect.width - 64, height: 17), size: 11.5, color: .white, bold: true)
        drawText(relativeTime(entry.activityDate), rect: NSRect(x: cardRect.minX + 12, y: cardRect.minY + 25, width: cardRect.width - 64, height: 13), size: 9.5, color: .white.withAlphaComponent(0.82))
        let icon = sourceIcon ?? NSImage(
            systemSymbolName: CardSourcePresentation.fallbackIconName(entry.source),
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(paletteColors: [.white]))
        icon?.draw(in: NSRect(x: cardRect.maxX - 43, y: cardRect.minY + (CardLayout.headerHeight - 32) / 2, width: 32, height: 32), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        switch entry.kind {
        case .image:
            drawCheckerboard(in: body)
            if let picture { drawAspectFit(picture, in: body.insetBy(dx: 8, dy: 8)) }
            else { drawText(L("图片预览不可用"), rect: body.insetBy(dx: 12, dy: 30), size: 12, color: .secondaryLabelColor) }
        case .file:
            drawFile(entry, in: body)
        case .color:
            drawColor(entry, in: body)
        case .text:
            if entry.linkURL != nil { drawLink(entry, in: body) }
            else {
                let rect = body.insetBy(dx: 12, dy: 11)
                CardTextLayout.draw(
                    String((entry.text ?? "").prefix(1600)),
                    in: rect,
                    font: .systemFont(ofSize: 12.5),
                    color: .labelColor
                )
            }
        }
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSRect(x: footer.minX + 10, y: footer.minY, width: footer.width - 20, height: 0.5).fill()
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill(); footer.fill()
        }
        let foot = selected ? L("✓ 已选中 · ") + cardFooter(entry) : cardFooter(entry)
        drawText(foot, rect: NSRect(x: footer.minX + 12, y: footer.minY + 7, width: footer.width - 58, height: 15), size: 10, color: selected ? .labelColor : .secondaryLabelColor, bold: selected)
        if let positionShortcut {
            drawText(positionShortcut, rect: NSRect(x: footer.maxX - 94, y: footer.minY + 7, width: 82, height: 15), size: 10, color: PanelPalette.secondaryText, alignment: .right)
        }
        NSGraphicsContext.restoreGraphicsState()
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.3).setStroke(); outline.lineWidth = 6; outline.stroke()
            NSColor.controlAccentColor.setStroke(); outline.lineWidth = 4; outline.stroke()
        }
    }
    private var cardSurface: NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.105, green: 0.105, blue: 0.115, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1)
    }
    private func sourceColor(_ key: String?) -> NSColor {
        guard let key else { return .init(srgbRed: 0.21, green: 0.29, blue: 0.43, alpha: 1) }
        let hash = key.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return NSColor(calibratedHue: CGFloat(hash % 360) / 360, saturation: 0.58, brightness: 0.66, alpha: 1)
    }
    private func cardTitle(_ entry: HistoryEntry) -> String {
        switch entry.kind {
        case .image: return imageFormat(entry) == "GIF" && (entry.frameCount ?? 1) > 1 ? L("GIF 动图") : L("图片")
        case .file: return entry.fileURLs.count > 1 ? L("\(entry.fileURLs.count) 个文件") : L("文件")
        case .color: return L("颜色")
        case .text: return entry.linkURL == nil ? L("文字") : L("链接")
        }
    }
    private func cardFooter(_ entry: HistoryEntry) -> String {
        switch entry.kind {
        case .image:
            let format = imageFormat(entry)
            return "\(format) · \(entry.width ?? 0) × \(entry.height ?? 0)"
        case .file:
            if entry.hasMissingFiles { return L("文件引用失效") }
            let type = fileType(entry.fileURLs.first)
            return entry.fileURLs.count == 1 ? type : L("\(entry.fileURLs.count) 个文件 · \(type)")
        case .color:
            guard let color = entry.text.flatMap(ContentCodec.color) else { return L("颜色代码") }
            return color.alpha == 255 ? "RGB" : "RGBA · \(Int((Double(color.alpha) / 255 * 100).rounded()))%"
        case .text: return entry.linkMetadata?.siteName ?? entry.linkURL?.host ?? L("\(entry.textLength ?? entry.text?.count ?? 0) 个字符")
        }
    }
    private func imageFormat(_ entry: HistoryEntry) -> String {
        let types = Set(entry.representations.map(\.type))
        if types.contains("com.compuserve.gif") { return "GIF" }
        if types.contains("public.jpeg") { return "JPEG" }
        if types.contains("public.png") { return "PNG" }
        return "TIFF"
    }
    private func fileType(_ url: URL?) -> String {
        guard let url else { return L("文件") }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return L("文件夹") }
        if let type = UTType(filenameExtension: url.pathExtension), let name = type.localizedDescription { return name }
        return url.pathExtension.isEmpty ? L("文件") : url.pathExtension.uppercased()
    }
    private func drawFile(_ entry: HistoryEntry, in body: NSRect) {
        let iconRect = NSRect(x: body.midX - 31, y: body.minY + 14, width: 62, height: 62)
        fileIcon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: entry.hasMissingFiles ? 0.42 : 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let names = entry.fileURLs.map(\.lastPathComponent).joined(separator: "\n")
        drawText(String(names.prefix(900)), rect: NSRect(x: body.minX + 12, y: iconRect.maxY + 8, width: body.width - 24, height: body.maxY - iconRect.maxY - 16), size: 11.5, color: entry.hasMissingFiles ? .secondaryLabelColor : .labelColor, alignment: .center)
        if entry.hasMissingFiles {
            drawText(L("已移动或删除"), rect: NSRect(x: body.minX + 12, y: body.maxY - 25, width: body.width - 24, height: 16), size: 10.5, color: .systemRed, bold: true, alignment: .center)
        }
    }
    private func drawColor(_ entry: HistoryEntry, in body: NSRect) {
        guard let color = entry.text.flatMap(ContentCodec.color) else { return }
        let swatch = NSRect(x: body.midX - 48, y: body.minY + 15, width: 96, height: 96)
        drawCheckerboard(in: swatch)
        NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.alpha) / 255).setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 10, yRadius: 10).fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: swatch, xRadius: 10, yRadius: 10); border.lineWidth = 1; border.stroke()
        drawText(entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", rect: NSRect(x: body.minX + 10, y: swatch.maxY + 12, width: body.width - 20, height: 20), size: 12, color: .labelColor, bold: true, alignment: .center)
    }
    private func drawLink(_ entry: HistoryEntry, in body: NSRect) {
        let host = entry.linkURL?.host ?? L("链接")
        let title = entry.linkMetadata?.title ?? host
        if let linkPicture {
            let preview = NSRect(x: body.minX, y: body.minY, width: body.width, height: 86)
            drawAspectFill(linkPicture, in: preview)
            if let linkIcon { linkIcon.draw(in: NSRect(x: body.minX + 12, y: preview.maxY + 12, width: 22, height: 22), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            let leading: CGFloat = linkIcon == nil ? 12 : 42
            drawText(title, rect: NSRect(x: body.minX + leading, y: preview.maxY + 10, width: body.width - leading - 12, height: 38), size: 12, color: .labelColor, bold: true)
            drawText(host, rect: NSRect(x: body.minX + 12, y: body.maxY - 25, width: body.width - 24, height: 15), size: 10, color: .secondaryLabelColor)
        } else {
            let icon = linkIcon ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            icon?.draw(in: NSRect(x: body.midX - 24, y: body.minY + 18, width: 48, height: 48), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawText(title, rect: NSRect(x: body.minX + 14, y: body.minY + 78, width: body.width - 28, height: 48), size: 12.5, color: .labelColor, bold: true, alignment: .center)
            drawText(host, rect: NSRect(x: body.minX + 12, y: body.maxY - 29, width: body.width - 24, height: 16), size: 10.5, color: .secondaryLabelColor, alignment: .center)
        }
    }
    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return L("刚刚") }
        if seconds < 3600 { return L("\(seconds / 60) 分钟前") }
        if seconds < 86400 { return L("\(seconds / 3600) 小时前") }
        return L("\(seconds / 86400) 天前")
    }
    private func drawText(_ text: String, rect: NSRect, size: CGFloat, color: NSColor, bold: Bool = false, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.lineSpacing = 1; paragraph.alignment = alignment
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

func drawCheckerboard(in rect: NSRect) {
    let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    (dark ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)).setFill(); rect.fill()
    NSColor.labelColor.withAlphaComponent(0.06).setFill()
    let tile: CGFloat = 10
    for row in 0...Int(rect.height / tile) {
        for col in 0...Int(rect.width / tile) where (row + col) % 2 == 0 {
            NSRect(x: rect.minX + CGFloat(col) * tile, y: rect.minY + CGFloat(row) * tile, width: tile, height: tile).intersection(rect).fill()
        }
    }
}
func drawAspectFit(_ image: NSImage, in rect: NSRect) {
    guard image.size.width > 0, image.size.height > 0 else { return }
    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}
func drawAspectFill(_ image: NSImage, in rect: NSRect) {
    guard image.size.width > 0, image.size.height > 0 else { return }
    let scale = max(rect.width / image.size.width, rect.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
    image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
}
