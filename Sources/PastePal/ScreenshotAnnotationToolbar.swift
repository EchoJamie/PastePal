import PastePalLocalization
import AppKit

private final class ScreenshotToolButton: NSButton {
    var isPrimary = false
    var showsSelection = false
    private var hovered = false
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let selected = showsSelection && state == .on
        if selected || isPrimary || (hovered && isEnabled) {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            let color = isPrimary ? NSColor.controlAccentColor : (selected ? NSColor.controlAccentColor.withAlphaComponent(0.3) : NSColor.labelColor.withAlphaComponent(0.1))
            color.setFill(); outline.fill()
        }
        super.draw(dirtyRect)
    }
}

private final class ScreenshotColorButton: NSButton {
    let color: ScreenshotAnnotationColor
    init(color: ScreenshotAnnotationColor, target: AnyObject?, action: Selector) {
        self.color = color
        super.init(frame: .zero)
        self.target = target; self.action = action
        isBordered = false; title = ""; focusRingType = .none; setButtonType(.pushOnPushOff)
        setAccessibilityLabel(color.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let disk = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 5, yRadius: 5)
        (NSColor(cgColor: color.cgColor) ?? .black).setFill(); disk.fill()
        NSColor.separatorColor.setStroke(); disk.stroke()
        if state == .on {
            let checkColor: NSColor = [.yellow, .green, .white].contains(color) ? .black : .white
            checkColor.setStroke()
            let check = NSBezierPath()
            let direction: CGFloat = isFlipped ? -1 : 1
            check.move(to: NSPoint(x: bounds.midX - 5, y: bounds.midY))
            check.line(to: NSPoint(x: bounds.midX - 1, y: bounds.midY - 4 * direction))
            check.line(to: NSPoint(x: bounds.midX + 6, y: bounds.midY + 5 * direction))
            check.lineWidth = 2; check.lineCapStyle = .round; check.lineJoinStyle = .round
            check.stroke()
        }
    }
}

final class ScreenshotAnnotationToolbar: NSVisualEffectView {
    static let size = NSSize(width: 528, height: 56)
    private(set) var preferredSize = ScreenshotAnnotationToolbar.size
    var onSizeChange: (() -> Void)?
    private(set) var toolButtons: [ScreenshotAnnotationModel.Tool: NSButton] = [:]
    private(set) var colorButtons: [ScreenshotAnnotationColor: NSButton] = [:]
    private(set) var undoButton = NSButton()
    private(set) var deleteButton = NSButton()
    private(set) var redoButton = NSButton()
    private(set) var widthControl = NSSegmentedControl()
    private(set) var effectControl = NSSegmentedControl()
    private(set) var strengthControl = NSSegmentedControl()
    private(set) var fontControl = NSSegmentedControl()
    private var colorOptions = NSStackView()
    private var strokeOptions = NSStackView()
    private var textOptions = NSStackView()
    private var obscureOptions = NSStackView()
    private var options = NSStackView()
    private var cursorTracking: NSTrackingArea?
    var onTool: ((ScreenshotAnnotationModel.Tool) -> Void)?
    var onColor: ((ScreenshotAnnotationColor) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onWidth: ((ScreenshotStrokeWidth) -> Void)?
    var onEffect: ((ScreenshotObscureStyle, ScreenshotObscureStrength) -> Void)?
    var onFontSize: ((ScreenshotFontSize) -> Void)?
    var onPin: (() -> Void)?
    var onSave: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }
    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityRole(.toolbar); setAccessibilityLabel(L("截屏标注工具栏"))
        material = .hudWindow; state = .active; wantsLayer = true
        layer?.cornerRadius = 14; layer?.masksToBounds = true
        layer?.borderWidth = 1; updateBorderColor()
        let tools = row(spacing: 4)
        for tool in ScreenshotAnnotationModel.Tool.allCases {
            let button = icon(tool.symbol, title: tool.title, shortcut: tool.shortcut, action: #selector(toolPressed(_:)))
            button.tag = tool.rawValue; button.setButtonType(.pushOnPushOff)
            (button as? ScreenshotToolButton)?.showsSelection = true
            toolButtons[tool] = button; tools.addArrangedSubview(button)
        }
        let colors = row(spacing: 6)
        colors.setAccessibilityLabel(L("标注颜色"))
        for color in ScreenshotAnnotationColor.allCases {
            let button = ScreenshotColorButton(color: color, target: self, action: #selector(colorPressed(_:)))
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            colorButtons[color] = button; colors.addArrangedSubview(button)
        }
        let actions = row(spacing: 4)
        undoButton = icon("arrow.uturn.backward", title: L("撤销标注"), shortcut: "⌘Z", action: #selector(undoPressed))
        redoButton = icon("arrow.uturn.forward", title: L("重做标注"), shortcut: "⇧⌘Z", action: #selector(redoPressed))
        let cancel = icon("xmark", title: L("取消截屏"), shortcut: "Esc", action: #selector(cancelPressed))
        let confirm = icon("doc.on.doc", title: L("复制"), shortcut: "Enter", action: #selector(confirmPressed))
        (confirm as? ScreenshotToolButton)?.isPrimary = true
        confirm.contentTintColor = .white
        let pin = icon("pin", title: L("贴图"), shortcut: "⌘P", action: #selector(pinPressed))
        let save = icon("square.and.arrow.down", title: L("美化并保存"), shortcut: "⌘S", action: #selector(savePressed))
        [undoButton, redoButton, pin, save, confirm, cancel].forEach(actions.addArrangedSubview)
        let mainRow = row(spacing: 10)
        [tools, NSView(), divider(), actions].forEach(mainRow.addArrangedSubview)
        widthControl = NSSegmentedControl(labels: ScreenshotStrokeWidth.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(widthChanged))
        for (index, width) in ScreenshotStrokeWidth.allCases.enumerated() {
            widthControl.setLabel("", forSegment: index)
            widthControl.setImage(Self.strokeImage(width.rawValue), forSegment: index)
            widthControl.setToolTip(L("线宽：\(width.title)"), forSegment: index)
        }
        widthControl.segmentStyle = .rounded
        widthControl.setAccessibilityLabel(L("标注线条粗细"))
        widthControl.widthAnchor.constraint(equalToConstant: 96).isActive = true
        deleteButton = icon("trash", title: L("删除所选标注"), shortcut: "Delete", action: #selector(deletePressed))
        effectControl = NSSegmentedControl(labels: ScreenshotObscureStyle.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(effectChanged))
        strengthControl = NSSegmentedControl(labels: ScreenshotObscureStrength.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(effectChanged))
        fontControl = NSSegmentedControl(labels: ScreenshotFontSize.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(fontChanged))
        for (index, symbol) in ["square.grid.3x3.fill", "drop.halffull"].enumerated() {
            effectControl.setLabel("", forSegment: index)
            effectControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: ScreenshotObscureStyle.allCases[index].title), forSegment: index)
            effectControl.setToolTip("\(ScreenshotObscureStyle.allCases[index].title)(\(index == 0 ? "X" : "U"))", forSegment: index)
        }
        for (index, strength) in ScreenshotObscureStrength.allCases.enumerated() {
            strengthControl.setLabel("", forSegment: index)
            strengthControl.setImage(Self.strengthImage(index + 1), forSegment: index)
            strengthControl.setToolTip(L("强度：\(strength.title)"), forSegment: index)
        }
        effectControl.setAccessibilityLabel(L("遮挡效果")); strengthControl.setAccessibilityLabel(L("遮挡强度")); fontControl.setAccessibilityLabel(L("文字字号"))
        effectControl.widthAnchor.constraint(equalToConstant: 80).isActive = true
        strengthControl.widthAnchor.constraint(equalToConstant: 96).isActive = true
        fontControl.widthAnchor.constraint(equalToConstant: 110).isActive = true
        [widthControl, effectControl, strengthControl, fontControl].forEach { $0.focusRingType = .none }
        colorOptions = row(spacing: 8); [colors].forEach(colorOptions.addArrangedSubview)
        strokeOptions = row(spacing: 8); [widthControl].forEach(strokeOptions.addArrangedSubview)
        textOptions = row(spacing: 8); [fontControl].forEach(textOptions.addArrangedSubview)
        obscureOptions = row(spacing: 12); [effectControl, strengthControl].forEach(obscureOptions.addArrangedSubview)
        options = row(spacing: 14)
        options.heightAnchor.constraint(equalToConstant: 32).isActive = true
        [colorOptions, strokeOptions, textOptions, obscureOptions, deleteButton].forEach(options.addArrangedSubview)
        let stack = NSStackView(views: [mainRow, options])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.detachesHiddenViews = true
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            mainRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        update(tool: nil, color: .red, canUndo: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func updateTrackingAreas() {
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self)
        cursorTracking = tracking; addTrackingArea(tracking)
        super.updateTrackingAreas()
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    func update(tool: ScreenshotAnnotationModel.Tool?, color: ScreenshotAnnotationColor, canUndo: Bool, canRedo: Bool = false, lineWidth: ScreenshotStrokeWidth = .medium, selected: ScreenshotAnnotation? = nil, effect: ScreenshotObscureStyle = .pixelate, strength: ScreenshotObscureStrength = .medium, fontSize: ScreenshotFontSize = .medium) {
        for (value, button) in toolButtons {
            button.state = value == tool ? .on : .off
            button.contentTintColor = value == tool ? .labelColor : .secondaryLabelColor
            button.setAccessibilityValue(value == tool ? L("使用中") : L("未使用"))
            button.needsDisplay = true
        }
        for (value, button) in colorButtons {
            button.state = value == (selected?.annotationColor ?? color) ? .on : .off
            button.isEnabled = tool?.usesColor == true || selected?.annotationColor != nil
            button.toolTip = value.title
            button.needsDisplay = true
            button.setAccessibilityValue(value == (selected?.annotationColor ?? color) ? L("已选择") : L("未选择"))
        }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        deleteButton.isEnabled = selected != nil
        widthControl.isEnabled = tool?.usesStroke == true || selected?.strokeWidth != nil
        widthControl.selectedSegment = ScreenshotStrokeWidth.allCases.firstIndex(of: selected?.strokeWidth.flatMap(ScreenshotStrokeWidth.init(rawValue:)) ?? lineWidth) ?? 1
        colorOptions.isHidden = !(tool?.usesColor == true || selected?.annotationColor != nil)
        strokeOptions.isHidden = !(tool?.usesStroke == true || selected?.strokeWidth != nil)
        textOptions.isHidden = !(tool == .text || selected?.fontSize != nil)
        obscureOptions.isHidden = !(tool == .obscure || selected?.obscureStyle != nil)
        deleteButton.isHidden = selected == nil
        effectControl.selectedSegment = (selected?.obscureStyle ?? effect).rawValue
        strengthControl.selectedSegment = ScreenshotObscureStrength.allCases.firstIndex(of: selected?.obscureStrength ?? strength) ?? 1
        fontControl.selectedSegment = ScreenshotFontSize.allCases.firstIndex(of: selected?.fontSize.flatMap(ScreenshotFontSize.init(rawValue:)) ?? fontSize) ?? 1
        options.isHidden = [colorOptions, strokeOptions, textOptions, obscureOptions, deleteButton].allSatisfy(\.isHidden)
        let nextSize = NSSize(width: Self.size.width, height: options.isHidden ? Self.size.height : 98)
        if preferredSize != nextSize {
            preferredSize = nextSize
            setFrameSize(nextSize)
            onSizeChange?()
        }
        window?.invalidateCursorRects(for: self)
    }
    private func icon(_ symbol: String, title: String, shortcut: String, action: Selector) -> NSButton {
        let button = ScreenshotToolButton()
        button.setButtonType(.momentaryChange)
        button.target = self; button.action = action; button.isBordered = false
        button.title = ""; button.imagePosition = .imageOnly; button.focusRingType = .none
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        button.toolTip = "\(title)(\(shortcut))"; button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }
    private static func strokeImage(_ width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: (16 - width) / 2, width: 18, height: width), xRadius: width / 2, yRadius: width / 2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
    private static func strengthImage(_ count: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            for index in 0..<3 {
                NSColor.white.withAlphaComponent(index < count ? 1 : 0.25).setFill()
                NSBezierPath(roundedRect: NSRect(x: CGFloat(index * 7), y: 3, width: 5, height: CGFloat(4 + index * 3)), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
    private func row(spacing: CGFloat) -> NSStackView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = spacing
        return row
    }
    private func divider() -> NSView {
        let divider = NSBox(); divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return divider
    }
    @objc private func toolPressed(_ sender: NSButton) {
        guard let tool = ScreenshotAnnotationModel.Tool(rawValue: sender.tag) else { return }
        onTool?(tool)
    }
    @objc private func colorPressed(_ sender: ScreenshotColorButton) { onColor?(sender.color) }
    @objc private func undoPressed() { onUndo?() }
    @objc private func redoPressed() { onRedo?() }
    @objc private func widthChanged() {
        guard ScreenshotStrokeWidth.allCases.indices.contains(widthControl.selectedSegment) else { return }
        onWidth?(ScreenshotStrokeWidth.allCases[widthControl.selectedSegment])
    }
    @objc private func effectChanged() {
        guard let effect = ScreenshotObscureStyle(rawValue: effectControl.selectedSegment), ScreenshotObscureStrength.allCases.indices.contains(strengthControl.selectedSegment) else { return }
        onEffect?(effect, ScreenshotObscureStrength.allCases[strengthControl.selectedSegment])
    }
    @objc private func fontChanged() {
        guard ScreenshotFontSize.allCases.indices.contains(fontControl.selectedSegment) else { return }
        onFontSize?(ScreenshotFontSize.allCases[fontControl.selectedSegment])
    }
    @objc private func pinPressed() { onPin?() }
    @objc private func savePressed() { onSave?() }
    @objc private func deletePressed() { onDelete?() }
    @objc private func cancelPressed() { onCancel?() }
    @objc private func confirmPressed() { onConfirm?() }
}
