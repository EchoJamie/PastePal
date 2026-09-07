import PastePalLocalization
import AppKit

enum ScreenshotOutputAction { case clipboard, pin, save }

enum ScreenshotDragPhase { case begin, change, end }

@MainActor final class ScreenshotSelection: NSObject, NSTextFieldDelegate {
    let frames: [ScreenshotFrame]
    private var windows: [NSWindow] = []
    private var toolbar: NSPanel?
    private var toolbarContent: ScreenshotAnnotationToolbar?
    private var region: ScreenshotRegionModel
    private var annotationModel = ScreenshotAnnotationModel()
    private var annotationGestureActive = false
    var annotations: [ScreenshotAnnotation] { annotationModel.annotations }
    var selectedTool: ScreenshotAnnotationModel.Tool? { annotationModel.tool }
    var onSave: ((CGRect) -> Void)?
    private(set) var isSuspended = false
    private let screenConfiguration = NSScreen.screens.map(\.frame)
    private var pointerMonitor: Any?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var textField: NSTextField?
    private var textOrigin: CGPoint?
    private var editingExistingText = false
    private(set) var outputAction: ScreenshotOutputAction = .clipboard
    private let windowCandidates: [ScreenshotWindowCandidate]
    private let onPickWindow: ((CGWindowID) -> Void)?
    private var hoveredWindow: ScreenshotWindowCandidate?
    private var didComplete = false
    private var cursorPushed = false
    private let completion: (CGRect?) -> Void

    init(frames: [ScreenshotFrame], initialSelection: CGRect? = nil, windowCandidates: [ScreenshotWindowCandidate] = [], onPickWindow: ((CGWindowID) -> Void)? = nil, completion: @escaping (CGRect?) -> Void) {
        self.frames = frames; self.completion = completion
        self.windowCandidates = windowCandidates; self.onPickWindow = onPickWindow
        region = ScreenshotRegionModel(desktopBounds: frames.reduce(CGRect.null) { $0.union($1.bounds) })
        super.init()
        if let initialSelection { region.begin(at: initialSelection.origin); region.end(at: CGPoint(x: initialSelection.maxX, y: initialSelection.maxY)) }
    }

    func show() {
        guard windows.isEmpty else { return }
        for frame in frames {
            let window = ScreenshotWindow(contentRect: frame.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.title = onPickWindow == nil ? L("截屏标注") : L("选择要截取的窗口")
            window.level = .screenSaver; window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = true; window.hasShadow = false; window.acceptsMouseMovedEvents = true
            let view = ScreenshotSelectionView(frame: CGRect(origin: .zero, size: frame.bounds.size), image: frame.image)
            view.onHover = { [weak self] in self?.hoverWindow(at: $0) }
            view.onDoubleClick = { [weak self] in self?.editText(at: $0) ?? false }
            view.onDrag = { [weak self] phase, point in self?.handleDrag(phase, at: point) }
            view.onCursor = { [weak self] point in self?.cursor(at: point) ?? .crosshair }
            window.contentView = view; windows.append(window)
            window.orderFrontRegardless()
        }
        windows.first?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handleKey(event) }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, !isSuspended, event.window === toolbar || windows.contains(where: { $0 === event.window }) else { return event }
            DispatchQueue.main.async { [weak self] in self?.updateCursor() }
            return event
        }
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.complete(nil) }
            })
        }
        NSCursor.crosshair.push(); cursorPushed = true
        refresh()
        if region.selection != nil { showToolbar() }
        if onPickWindow != nil { hoverWindow(at: NSEvent.mouseLocation) }
    }

    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard !isSuspended else { return event }
        if textField != nil { return event }
        if event.keyCode == 53 { complete(nil); return nil }
        if onPickWindow != nil {
            if event.keyCode == 36, let hoveredWindow { pickWindow(hoveredWindow) }
            return nil
        }
        if (event.keyCode == 51 || event.keyCode == 117), annotationModel.tool == .edit { annotationModel.deleteSelected(); refresh(); return nil }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "s" { confirm(action: .save); return nil }
            if event.charactersIgnoringModifiers?.lowercased() == "p" { confirm(action: .pin); return nil }
        }
        if event.keyCode == 36 || event.keyCode == 76 { confirm(); return nil }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }; return nil
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            guard !event.isARepeat else { return nil }
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "x" || key == "u" {
                commitText(); region.cancelDrag(); annotationGestureActive = false; annotationModel.toggleObscure(key == "x" ? .pixelate : .blur); refresh(); return nil
            }
            if !event.isARepeat, let tool = ScreenshotAnnotationModel.Tool.allCases.first(where: { $0.shortcut.lowercased() == event.charactersIgnoringModifiers?.lowercased() }) {
                selectTool(tool)
            }
        }
        return nil
    }

    func selectTool(_ tool: ScreenshotAnnotationModel.Tool) {
        commitText(); region.cancelDrag(); annotationGestureActive = false; annotationModel.toggleTool(tool); refresh()
    }

    func selectColor(_ color: ScreenshotAnnotationColor) {
        annotationModel.color = color
        annotationModel.styleSelected(color: color)
        textField?.textColor = NSColor(cgColor: color.cgColor)
        refresh()
    }

    func selectWidth(_ width: ScreenshotStrokeWidth) {
        annotationModel.lineWidth = width; annotationModel.styleSelected(width: width); refresh()
    }

    func selectEffect(_ effect: ScreenshotObscureStyle, strength: ScreenshotObscureStrength) {
        annotationModel.changeObscure(style: effect, strength: strength); refresh()
    }
    func selectFontSize(_ size: ScreenshotFontSize) {
        annotationModel.changeFontSize(size)
        if let textField { textField.font = .systemFont(ofSize: size.rawValue, weight: .semibold); textField.setFrameSize(CGSize(width: textField.frame.width, height: size.rawValue + 12)) }
        refresh()
    }

    func cursor(at point: CGPoint) -> NSCursor {
        if onPickWindow != nil { return windowCandidates.contains { $0.bounds.contains(point) } ? .pointingHand : .arrow }
        if region.selection == nil { return .crosshair }
        if region.isDragging { return Self.cursor(for: region.interaction(at: point), dragging: true) }
        if !annotationGestureActive, let interaction = regionAdjustment(at: point) {
            return Self.cursor(for: interaction, dragging: false)
        }
        guard let tool = annotationModel.tool else { return .arrow }
        if tool == .edit {
            guard let interaction = annotationModel.editInteraction(at: point) else { return .arrow }
            return Self.cursor(for: interaction, dragging: annotationModel.isEditingGesture)
        }
        guard region.selection?.contains(point) == true else { return .operationNotAllowed }
        return ScreenshotCursors.drawing(tool: tool, effect: annotationModel.obscureStyle)
    }

    private func regionAdjustment(at point: CGPoint) -> ScreenshotRegionModel.Interaction? {
        guard region.selection != nil else { return .create }
        let interaction = region.interaction(at: point)
        if case .resize = interaction { return interaction }
        return annotationModel.tool == nil ? interaction : nil
    }

    private static func cursor(for interaction: ScreenshotRegionModel.Interaction, dragging: Bool) -> NSCursor {
        switch interaction {
        case .create: return .crosshair
        case .move: return dragging ? .closedHand : .openHand
        case .resize(let x, let y):
            let position: NSCursor.FrameResizePosition
            switch (x, y) {
            case (-1, -1): position = .bottomLeft
            case (-1, 1): position = .topLeft
            case (1, -1): position = .bottomRight
            case (1, 1): position = .topRight
            case (-1, _): position = .left
            case (1, _): position = .right
            case (_, -1): position = .bottom
            default: position = .top
            }
            return .frameResize(position: position, directions: .all)
        }
    }

    func handleDrag(_ phase: ScreenshotDragPhase, at point: CGPoint) {
        guard !didComplete, !isSuspended else { return }
        if onPickWindow != nil {
            hoverWindow(at: point)
            if phase == .end, let hoveredWindow { pickWindow(hoveredWindow) }
            return
        }
        if phase == .begin {
            commitText()
            if regionAdjustment(at: point) != nil {
                annotationModel.cancelGesture(); annotationGestureActive = false
                region.begin(at: point); toolbar?.orderOut(nil)
            } else {
                annotationGestureActive = region.selection?.contains(point) == true
            }
        }
        if region.isDragging {
            switch phase {
            case .begin: break
            case .change: region.update(to: point)
            case .end: region.end(at: point)
            }
        } else if annotationModel.tool == nil {
            return
        } else if annotationModel.tool == .edit {
            guard let bounds = region.selection else { return }
            switch phase {
            case .begin: if bounds.contains(point) { annotationModel.beginEdit(at: point, within: bounds) }
            case .change: annotationModel.updateEdit(to: point)
            case .end: annotationModel.endEdit(at: point)
            }
        } else if annotationModel.tool == .text {
            if phase == .begin, region.selection?.contains(point) == true { beginText(at: point) }
        } else {
            guard let selection = region.selection else { return }
            let clipped = CGPoint(x: min(max(point.x, selection.minX), selection.maxX), y: min(max(point.y, selection.minY), selection.maxY))
            switch phase {
            case .begin: if selection.contains(point) { annotationModel.begin(at: clipped) }
            case .change: annotationModel.update(to: clipped)
            case .end: annotationModel.end(at: clipped)
            }
        }
        if phase == .end { annotationGestureActive = false }
        refresh()
        if phase == .end, region.selection != nil { showToolbar() }
    }

    private func refresh() {
        let selection = onPickWindow != nil ? hoveredWindow?.bounds : region.selection
        let scale = frames.filter { frame in selection.map { !$0.intersection(frame.bounds).isEmpty } ?? false }.map(\.scale).max() ?? 1
        for window in windows {
            guard let view = window.contentView as? ScreenshotSelectionView else { continue }
            view.screenOrigin = window.frame.origin
            view.selection = selection
            view.annotations = annotationModel.annotations
            view.pixelScale = scale
            view.showHandles = onPickWindow == nil && !region.isDragging
            view.editHandles = annotationModel.tool == .edit ? annotationModel.selectedAnnotation?.editHandles ?? [] : []
            view.instruction = onPickWindow != nil ? (hoveredWindow?.title ?? L("指向窗口并单击 · Esc 取消")) : nil
            view.needsDisplay = true
            window.invalidateCursorRects(for: view)
        }
        toolbarContent?.update(tool: annotationModel.tool, color: annotationModel.color, canUndo: annotationModel.canUndo, canRedo: annotationModel.canRedo, lineWidth: annotationModel.lineWidth, selected: annotationModel.tool == .edit ? annotationModel.selectedAnnotation : nil, effect: annotationModel.obscureStyle, strength: annotationModel.obscureStrength, fontSize: annotationModel.fontSize)
        updateCursor()
    }

    private func updateCursor() {
        guard !isSuspended, !windows.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        if let toolbar, toolbar.isVisible, toolbar.frame.contains(mouse) { NSCursor.arrow.set(); return }
        guard let window = windows.first(where: { $0.frame.contains(mouse) }) else { NSCursor.arrow.set(); return }
        let local = window.convertPoint(fromScreen: mouse)
        if let textField, textField.window === window, textField.frame.contains(local) { NSCursor.iBeam.set(); return }
        cursor(at: mouse).set()
    }

    private func showToolbar() {
        guard !windows.isEmpty, region.selection != nil else { return }
        if toolbar == nil {
            let content = ScreenshotAnnotationToolbar()
            let panel = ScreenshotToolbarPanel(contentRect: NSRect(origin: .zero, size: ScreenshotAnnotationToolbar.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false; panel.hasShadow = true
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.contentView = content
            content.onTool = { [weak self] in self?.selectTool($0) }
            content.onColor = { [weak self] in self?.selectColor($0) }
            content.onEffect = { [weak self] in self?.selectEffect($0, strength: $1) }
            content.onFontSize = { [weak self] in self?.selectFontSize($0) }
            content.onWidth = { [weak self] in self?.selectWidth($0) }
            content.onRedo = { [weak self] in self?.commitText(); self?.redo() }
            content.onUndo = { [weak self] in self?.commitText(); self?.undo() }
            content.onCancel = { [weak self] in self?.cancel() }
            content.onDelete = { [weak self] in self?.annotationModel.deleteSelected(); self?.refresh() }
            content.onPin = { [weak self] in self?.confirm(action: .pin) }
            content.onSave = { [weak self] in self?.confirm(action: .save) }
            content.onConfirm = { [weak self] in self?.confirm() }
            content.onSizeChange = { [weak self] in self?.positionToolbar() }
            toolbarContent = content
            toolbar = panel
        }
        refresh()
        positionToolbar()
        toolbar?.orderFrontRegardless()
    }

    private func positionToolbar() {
        guard let selection = region.selection, let toolbar, let toolbarContent else { return }
        let targetScreen = NSScreen.screens.max { $0.frame.intersection(selection).area < $1.frame.intersection(selection).area }?.visibleFrame ?? frames.max { $0.bounds.intersection(selection).area < $1.bounds.intersection(selection).area }?.bounds ?? region.desktopBounds
        let width = toolbarContent.preferredSize.width, height = toolbarContent.preferredSize.height
        let x = min(max(selection.midX - width / 2, targetScreen.minX + 8), targetScreen.maxX - width - 8)
        let below = selection.minY - height - 12
        let y = below >= targetScreen.minY + 8 ? below : min(selection.maxY + 12, targetScreen.maxY - height - 8)
        toolbar.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func hoverWindow(at point: CGPoint) {
        guard onPickWindow != nil else { return }
        let next = windowCandidates.first { $0.bounds.contains(point) }
        guard next?.id != hoveredWindow?.id else { return }
        hoveredWindow = next; refresh()
    }
    private func pickWindow(_ candidate: ScreenshotWindowCandidate) {
        guard !didComplete else { return }
        didComplete = true; onPickWindow?(candidate.id)
    }
    private func editText(at point: CGPoint) -> Bool {
        guard annotationModel.tool == .edit, regionAdjustment(at: point) == nil else { return false }
        commitText(); annotationModel.selectAnnotation(at: point)
        guard case let .text(text, origin, _, _) = annotationModel.selectedAnnotation else { refresh(); return false }
        annotationModel.cancelGesture(); beginText(at: origin, existing: text); refresh(); return true
    }
    private func beginText(at point: CGPoint, existing: String? = nil) {
        guard let window = windows.first(where: { $0.frame.contains(point) }), let selection = region.selection else { return }
        let origin = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        let fieldWidth = min(260, max(160, selection.maxX - point.x), window.frame.width)
        let field = NSTextField(frame: CGRect(x: min(origin.x, window.frame.width - fieldWidth), y: min(max(0, origin.y - 3), window.frame.height - 30), width: fieldWidth, height: 30))
        field.font = .systemFont(ofSize: existing != nil ? annotationModel.selectedAnnotation?.fontSize ?? annotationModel.fontSize.rawValue : annotationModel.fontSize.rawValue, weight: .semibold)
        field.setFrameSize(CGSize(width: field.frame.width, height: max(30, (field.font?.pointSize ?? 20) + 12)))
        field.delegate = self
        field.textColor = NSColor(cgColor: (existing != nil ? annotationModel.selectedAnnotation?.annotationColor ?? annotationModel.color : annotationModel.color).cgColor); field.backgroundColor = .textBackgroundColor
        field.placeholderString = L("输入文字，回车完成")
        field.stringValue = existing ?? ""
        editingExistingText = existing != nil
        field.target = self; field.action = #selector(textConfirmed)
        field.setAccessibilityLabel(L("截屏标注文字"))
        window.contentView?.addSubview(field)
        textField = field; textOrigin = point
        window.makeKey(); window.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() else { return false }
        textField?.removeFromSuperview(); textField = nil; textOrigin = nil; editingExistingText = false
        windows.first?.makeFirstResponder(windows.first?.contentView); refresh(); return true
    }

    @objc private func textConfirmed() { commitText(); refresh() }

    private func commitText() {
        guard let textField else { return }
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if editingExistingText { annotationModel.replaceSelectedText(text) }
        else if !text.isEmpty, let textOrigin { annotationModel.addText(text, at: textOrigin) }
        editingExistingText = false
        textField.window?.makeFirstResponder(textField.superview)
        textField.removeFromSuperview(); self.textField = nil; textOrigin = nil
    }

    private func undo() { annotationModel.undo(); refresh() }
    private func redo() { annotationModel.redo(); refresh() }
    func confirm(action: ScreenshotOutputAction = .clipboard) {
        commitText(); outputAction = action
        guard !isSuspended, !didComplete else { return }
        if let selection = region.selection {
            if action == .save, let onSave { onSave(selection) }
            else { complete(selection) }
        }
    }
    func suspendForExport() {
        commitText(); annotationModel.cancelGesture(); isSuspended = true; close()
    }
    @discardableResult func resumeAfterExport() -> Bool {
        guard screenConfiguration == NSScreen.screens.map(\.frame) else { return false }
        isSuspended = false; didComplete = false; outputAction = .clipboard; show(); return true
    }
    func cancel() { complete(nil) }

    private func complete(_ rect: CGRect?) {
        guard !didComplete, !isSuspended else { return }
        didComplete = true; completion(rect)
    }

    func close() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }; pointerMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        textField?.removeFromSuperview(); textField = nil
        toolbar?.orderOut(nil); toolbar?.contentView = nil; toolbar?.close(); toolbar = nil
        toolbarContent = nil
        for window in windows { window.orderOut(nil); window.contentView = nil; window.close() }
        windows.removeAll()
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private final class ScreenshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
private final class ScreenshotToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

@MainActor final class ScreenshotSelectionView: NSView {
    private let image: NSImage
    private let capturedImage: CGImage
    private var obscurer: ScreenshotObscureRenderer?
    private var obscurerBounds: CGRect?
    var editHandles: [CGPoint] = []
    var instruction: String?
    var onDrag: ((ScreenshotDragPhase, CGPoint) -> Void)?
    var onHover: ((CGPoint) -> Void)?
    var onDoubleClick: ((CGPoint) -> Bool)?
    var onCursor: ((CGPoint) -> NSCursor)?
    private var cursorTracking: NSTrackingArea?
    var screenOrigin = CGPoint.zero
    var selection: CGRect?
    var annotations: [ScreenshotAnnotation] = []
    var pixelScale: CGFloat = 1
    var showHandles = false
    init(frame: CGRect, image: CGImage) {
        self.image = NSImage(cgImage: image, size: frame.size)
        capturedImage = image
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved], owner: self)
        cursorTracking = tracking; addTrackingArea(tracking)
        super.updateTrackingAreas()
    }
    override func resetCursorRects() {
        let point = NSEvent.mouseLocation
        addCursorRect(bounds, cursor: onCursor?(point) ?? .arrow)
    }
    override func cursorUpdate(with event: NSEvent) { updateCursor(for: event) }
    override func mouseEntered(with event: NSEvent) { updateCursor(for: event) }
    override func mouseMoved(with event: NSEvent) {
        if let window { onHover?(window.convertPoint(toScreen: event.locationInWindow)) }
        updateCursor(for: event)
    }
    private func updateCursor(for event: NSEvent) {
        let hit = hitTest(convert(event.locationInWindow, from: nil))
        guard !(hit is NSTextField), !(hit is NSTextView) else { return }
        guard let window else { return }
        (onCursor?(window.convertPoint(toScreen: event.locationInWindow)) ?? .crosshair).set()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        if event.clickCount == 2, let window, onDoubleClick?(window.convertPoint(toScreen: event.locationInWindow)) == true { return }
        sendDrag(.begin, event: event); updateCursor(for: event)
    }
    override func mouseDragged(with event: NSEvent) { sendDrag(.change, event: event); updateCursor(for: event) }
    override func mouseUp(with event: NSEvent) { sendDrag(.end, event: event); updateCursor(for: event) }
    private func sendDrag(_ phase: ScreenshotDragPhase, event: NSEvent) {
        guard let window else { return }
        onDrag?(phase, window.convertPoint(toScreen: event.locationInWindow))
    }
    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        let sourceBounds = CGRect(origin: screenOrigin, size: bounds.size)
        if obscurerBounds != sourceBounds { obscurer = ScreenshotObscureRenderer(image: capturedImage, bounds: sourceBounds); obscurerBounds = sourceBounds }
        let localSelection = selection?.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
        if let selection, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState(); context.translateBy(x: -screenOrigin.x, y: -screenOrigin.y)
            context.clip(to: selection)
            ScreenshotAnnotationRenderer.draw(annotations: annotations, in: context, obscurer: obscurer)
            context.restoreGState()
        }
        let shade = NSBezierPath(rect: bounds)
        if let visible = localSelection?.intersection(bounds), !visible.isEmpty {
            shade.appendRect(visible); shade.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.42).setFill(); shade.fill()
        if let localSelection {
            let outline = NSBezierPath(rect: localSelection)
            outline.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.4).setStroke(); outline.lineWidth = 3; outline.stroke()
            NSColor.white.withAlphaComponent(0.95).setStroke(); outline.lineWidth = 1; outline.stroke()
            if showHandles {
                for x in [localSelection.minX, localSelection.midX, localSelection.maxX] {
                    for y in [localSelection.minY, localSelection.midY, localSelection.maxY] where x != localSelection.midX || y != localSelection.midY {
                        let handle = NSBezierPath(ovalIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
                        NSColor.white.setFill(); handle.fill()
                        NSColor.controlAccentColor.setStroke(); handle.lineWidth = 1.5; handle.stroke()
                    }
                }
            }
            for point in editHandles {
                let local = CGPoint(x: point.x - screenOrigin.x, y: point.y - screenOrigin.y)
                let dot = NSBezierPath(ovalIn: CGRect(x: local.x - 3, y: local.y - 3, width: 6, height: 6))
                NSColor.white.setFill(); dot.fill()
                NSColor.controlAccentColor.setStroke(); dot.stroke()
            }
            let label = instruction ?? "\(Int(ceil(localSelection.width * pixelScale))) × \(Int(ceil(localSelection.height * pixelScale))) px"
            let visible = localSelection.intersection(bounds)
            if !visible.isEmpty {
                drawLabel(label, at: CGPoint(x: min(max(visible.minX, 8), max(8, bounds.width - 180)), y: min(visible.maxY + 8, bounds.height - 30)))
            }
        } else { drawLabel(instruction ?? L("拖动选择区域 · Esc 取消"), at: CGPoint(x: 24, y: bounds.height - 48)) }
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: CGRect(x: point.x - 6, y: point.y - 3, width: size.width + 16, height: size.height + 8), xRadius: 7, yRadius: 7).fill()
        text.draw(at: point, withAttributes: attributes)
    }
}
