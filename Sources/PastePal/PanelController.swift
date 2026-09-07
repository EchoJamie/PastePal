import PastePalLocalization
import AppKit
import ClipboardCore
import QuartzCore

final class ScrollerlessScrollView: NSScrollView {
    override var hasHorizontalScroller: Bool {
        get { false }
        set { super.hasHorizontalScroller = false }
    }
    override var hasVerticalScroller: Bool {
        get { false }
        set { super.hasVerticalScroller = false }
    }
}

final class HistorySearchCell: NSSearchFieldCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var text = super.searchTextRect(forBounds: rect)
        let start = searchButtonRect(forBounds: rect).maxX + 6
        let end = text.maxX
        text.origin.x = max(text.minX, start)
        text.size.width = max(0, end - text.minX)
        return text
    }
}

enum PanelLayout {
    static let height: CGFloat = 356
    static let cornerRadius: CGFloat = 18
    static let entranceDuration: TimeInterval = 0.16
    static let backgroundMaterial: NSVisualEffectView.Material = .popover
    static let toolbarHeight: CGFloat = 30
    static let collectionHeight: CGFloat = 300
    static let cardSize = NSSize(width: 238.0 * 284.0 / 248.0, height: 284)

    static func frame(in screenFrame: NSRect) -> NSRect {
        NSRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: height)
    }

    static func frame(at mouseLocation: NSPoint, screenFrames: [NSRect], fallback: NSRect?) -> NSRect? {
        guard let screenFrame = screenFrames.first(where: { $0.contains(mouseLocation) }) ?? fallback else { return nil }
        return frame(in: screenFrame)
    }

    static func entranceOffset(reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : -height
    }
}

enum PanelPalette {
    static let primaryText = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.95, alpha: 1)
            : NSColor(white: 0.1, alpha: 1)
    }
    static let secondaryText = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.8, alpha: 1)
            : NSColor(white: 0.28, alpha: 1)
    }
}

final class PanelBackground: NSView {
    let effectView = NSVisualEffectView()
    let contentView = NSView()
    private static let materialMask = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
        NSColor.black.withAlphaComponent(0.78).setFill()
        rect.fill()
        return true
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effectView.material = PanelLayout.backgroundMaterial
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = false
        for view in [effectView, contentView] {
            view.frame = bounds; view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        wantsLayer = true
        layer?.cornerRadius = PanelLayout.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true
        refreshAccessibilityAppearance()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAccessibilityAppearance), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func refreshAccessibilityAppearance() {
        updateMaterialMask(reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
    func updateMaterialMask(reduceTransparency: Bool) {
        effectView.maskImage = reduceTransparency ? nil : Self.materialMask
    }
}

final class HistoryPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onPasteIntoSearch: (() -> Void)?
    var handleGroupShortcut: ((NSEvent) -> Bool)?
    var handleGroupJoinKey: ((NSEvent) -> Bool)?
    var handleAppShortcut: ((NSEvent) -> Bool)?
    var handleGroupConfirmationKey: ((NSEvent) -> Bool)?
    var onUseCurrentCard: (() -> Void)?
    var isCardMode = { false }
    var shouldUseCurrentCard = { false }
    var onAfterEvent: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleGroupConfirmationKey?(event) == true { return }
        if event.type == .keyDown, handleGroupJoinKey?(event) == true { return }
        if event.type == .keyDown, handleGroupShortcut?(event) == true { return }
        if event.type == .keyDown, handleAppShortcut?(event) == true { return }
        super.sendEvent(event)
        onAfterEvent?()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleGroupConfirmationKey?(event) == true { return true }
        if handleGroupJoinKey?(event) == true { return true }
        if handleAppShortcut?(event) == true { return true }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if [36, 76].contains(event.keyCode), modifiers.isEmpty, shouldUseCurrentCard() {
            onUseCurrentCard?()
            return true
        }
        if handleGroupShortcut?(event) == true { return true }
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v" where isCardMode(): onPasteIntoSearch?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

final class HistoryCollection: NSCollectionView {
    var didBeginCardDrag = false
    var onUse: ((Int?) -> Void)?
    var onMove: ((Int) -> Void)?
    var onPreview: (() -> Void)?
    var onClose: (() -> Void)?
    var onDelete: (() -> Void)?
    var onBeginSearch: ((NSEvent) -> Void)?
    var onActivateCards: (() -> Void)?
    var handleAppShortcut: ((NSEvent) -> Bool)?
    var handleGroupJoinKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        didBeginCardDrag = false
        onActivateCards?()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let clickedItem = indexPathForItem(at: point)
        super.mouseDown(with: event)
        guard !didBeginCardDrag else { return }
        if let clickedItem, selectionIndexPaths != [clickedItem] {
            selectionIndexPaths = [clickedItem]
            delegate?.collectionView?(self, didSelectItemsAt: [clickedItem])
        }
        if event.clickCount == 2 { onUse?(nil) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleGroupJoinKey?(event) == true || handleAppShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if handleGroupJoinKey?(event) == true || handleAppShortcut?(event) == true { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !modifiers.isEmpty && [36, 76, 123, 124, 125, 126, 49, 53, 51, 117].contains(event.keyCode) {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76:
            onUse?(nil)
        case 123: onMove?(-1)
        case 124: onMove?(1)
        case 125, 126: return
        case 49: onPreview?()
        case 53: onClose?()
        case 51, 117: onDelete?()
        default:
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.intersection([.command, .control, .function]).isEmpty {
                onBeginSearch?(event)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

final class SearchBar: ToolbarInputSurface {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class SearchScopeButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

final class GroupButton: NSButton {
    let groupID: String
    var onRename: (() -> Void)?
    var onDragBegan: (() -> Bool)?
    var onDragChanged: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent?) -> Void)?
    var onCardDragValidation: ((NSDraggingInfo) -> Bool)?
    var onCardDrop: ((NSDraggingInfo) -> Bool)?
    private(set) var isCardDropHighlighted = false { didSet { needsDisplay = true } }
    var isJoinTarget = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if isCardDropHighlighted || isJoinTarget {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill(); outline.fill()
            NSColor.controlAccentColor.setStroke(); outline.stroke()
        }
        super.draw(dirtyRect)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isCardDropHighlighted = onCardDragValidation?(sender) == true
        return isCardDropHighlighted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { isCardDropHighlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { onCardDragValidation?(sender) == true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { isCardDropHighlighted = false }
        guard onCardDragValidation?(sender) == true else { return false }
        return onCardDrop?(sender) == true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { isCardDropHighlighted = false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { isCardDropHighlighted = false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRename?(); return }
        guard let window else { return }
        var dragging = false
        defer {
            if dragging { NSCursor.pop() }
        }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            guard next.timestamp >= event.timestamp else { continue }
            if next.type == .keyDown {
                if next.keyCode == 53 { if dragging { onDragEnded?(nil) }; return }
                continue
            }
            if next.type == .leftMouseDragged {
                if !dragging, hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) >= 5 {
                    guard onDragBegan?() == true else { return }
                    dragging = true; NSCursor.closedHand.push()
                }
                if dragging { onDragChanged?(next) }
            } else {
                if dragging { onDragChanged?(next); onDragEnded?(next) }
                else if bounds.contains(convert(next.locationInWindow, from: nil)) { performClick(nil) }
                return
            }
        }
        if dragging { onDragEnded?(nil) }
    }
    init(group: ClipGroup, target: AnyObject?, action: Selector) {
        groupID = group.id
        super.init(frame: .zero)
        title = group.name; self.target = target; self.action = action
        isBordered = false; focusRingType = .none; controlSize = .small
        registerForDraggedTypes([CardGroupDrag.pasteboardType])
        setAccessibilityLabel(L("分组：\(group.name)"))
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class PanelController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    enum InteractionMode: Equatable { case cards, search }

    let model: AppModel
    private let searchButton = NSButton()
    private let newGroupButton = NSButton()
    private let search = NSSearchField()
    private let idleToolbar = NSStackView()
    private let groupScroll = ScrollerlessScrollView()
    private let groupStack = NSStackView()
    private let searchToolbar = NSStackView()
    private let searchBar = SearchBar()
    private let searchScopeChip = SearchScopeButton()
    private let collection = HistoryCollection()
    private let scroll = ScrollerlessScrollView()
    private let hint = NSTextField(labelWithString: "")
    private var hintIdleTrailing: NSLayoutConstraint?
    private var hintSearchTrailing: NSLayoutConstraint?
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(labelWithString: "")
    private let emptyStack = NSStackView()
    private let background = PanelBackground()
    private var results: HistoryQueryResults?
    private var selectedID: String?
    private(set) var selectedGroupID: String?
    private var groupButtons: [GroupButton] = []
    private var draggedGroupID: String?
    private var groupDropSlot: Int?
    private var cardDragEntryID: String?
    private var groupJoinEntryID: String?
    private(set) var groupJoinTargetID: String?
    private let groupDropIndicator = NSView()
    private(set) var groupLabelEditor: GroupLabelEditor?
    private(set) var deleteGroupControl: NSButton?
    private lazy var groupShortcuts = GroupShortcutStore(defaults: model.settings.defaults)
    private lazy var appShortcuts = AppShortcutStore(defaults: model.settings.defaults)
    private var groupScrollWidthConstraint: NSLayoutConstraint?
    private var queryGeneration = 0
    private(set) var interactionMode: InteractionMode = .cards
    private var searchSessionActive = false
    private var searchOriginGroupID: String?
    private var searchOriginSelectionID: String?
    private var searchScopeGroupID: String?
    private lazy var searchCoordinator = HistorySearchCoordinator(directory: model.store.directory)
    private let imageCache = CardImageCache()
    private var preview: PreviewController?
    private var groupPicker: GroupPickerController?
    private var groupEditor: GroupEditorController?
    private(set) var groupCreationView: GroupCreationView?
    private var inlineGroupView: NSView?
    private var outsideMonitor: Any?
    private var closing = false
    private var statusMenuOpen = false
    private var restoreFocusAfterStatusMenu = true
    private var focusLossGeneration = 0
    private var returnApp: NSRunningApplication?
    private var displayPrepared = false

    var visibleQuery: String { search.stringValue }
    var visibleEntryIDs: [String] { (try? results?.allIDs()) ?? [] }
    var selectedEntryID: String? { selectedID }
    var isCollectionFocused: Bool { window?.firstResponder === collection }
    var searchControl: NSSearchField { search }
    var shortcutHintControl: NSTextField { hint }
    var isGroupDropIndicatorVisible: Bool { !groupDropIndicator.isHidden }
    var isGroupJoinVisible: Bool { groupJoinEntryID != nil }
    var searchTriggerControl: NSButton { searchButton }
    var newGroupControl: NSButton { newGroupButton }
    var searchScopeControl: NSButton { searchScopeChip }
    var isSearchControlVisible: Bool { !searchToolbar.isHidden && !searchBar.isHidden }
    var isGroupToolbarVisible: Bool { !idleToolbar.isHidden }
    var isNewGroupControlVisible: Bool { !idleToolbar.isHidden && !newGroupButton.isHidden }
    var isSearchScopeControlVisible: Bool { !searchToolbar.isHidden && !searchBar.isHidden && !searchScopeChip.isHidden }
    var groupLabelTitles: [String] { groupButtons.map(\.title) }
    var groupStripOverflows: Bool { groupStack.frame.width > groupScroll.contentView.bounds.width + 0.5 }
    var isSelectedGroupVisible: Bool {
        guard let button = groupButtons.first(where: { $0.groupID == selectedGroupID }) else { return selectedGroupID == nil }
        return groupScroll.contentView.bounds.intersects(button.convert(button.bounds, to: groupStack))
    }
    var searchScopeText: String { isSearchScopeControlVisible ? searchScopeChip.title : "" }
    var emptyStateTitle: String { emptyTitle.stringValue }
    var isGroupPickerVisible: Bool { groupPicker?.view.window === window && groupPicker != nil }
    var hasPreviewController: Bool { preview != nil }
    var previewWindow: NSWindow? { preview?.window }
    var groupPickerController: GroupPickerController? { groupPicker }
    var groupEditorController: GroupEditorController? { groupEditor }
    var isGroupDeleteConfirmationVisible: Bool { groupEditor?.isConfirmingDelete == true }
    var isGroupInteractionVisible: Bool { inlineGroupView != nil || groupLabelEditor != nil || groupCreationView != nil || draggedGroupID != nil || cardDragEntryID != nil || groupJoinEntryID != nil }
    var historyScrollView: NSScrollView { scroll }
    var visibleToolbarCenterOffset: CGFloat {
        let toolbar = searchToolbar.isHidden ? idleToolbar : searchToolbar
        return toolbar.convert(toolbar.bounds, to: background).midX - background.bounds.midX
    }
    var visibleToolbarDoesNotOverlapCount: Bool {
        let toolbar = searchToolbar.isHidden ? idleToolbar : searchToolbar
        let toolbarFrame = toolbar.convert(toolbar.bounds, to: background)
        return toolbarFrame.maxX + 16 <= background.bounds.maxX
    }
    var preferredPanelHeight: CGFloat { PanelLayout.height }
    var historyView: HistoryCollection { collection }
    var backgroundEffect: NSVisualEffectView { background.effectView }
    var panelRootView: NSView { background }
    var panelContentView: NSView { background.contentView }
    var canActOnSelectedEntry: Bool {
        isVisible && !isGroupInteractionVisible && interactionMode == .cards && selectedEntry != nil && !model.busy
    }
    var canUseSelectedEntryAsPlainText: Bool {
        canActOnSelectedEntry && selectedEntry?.supportsPlainText == true
    }
    var canAddSelectedEntryToGroup: Bool {
        guard canActOnSelectedEntry, let selectedID else { return false }
        let memberships = model.groupIDs(for: selectedID)
        return model.groups.contains { !memberships.contains($0.id) }
    }
    var activeSearchScopeGroupID: String? { isSearchPresentationVisible ? searchScopeGroupID : nil }
    var selectedGroupName: String? { resultGroupName }
    var contextualDeleteTitle: String {
        selectedGroupName.map { L("从「\($0)」移除所选（Delete）") } ?? L("永久删除所选（Delete）")
    }

    init(model: AppModel) {
        self.model = model
        let panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: PanelLayout.height), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        super.init(window: panel)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.handlePanelCancel() }
        panel.onPasteIntoSearch = { [weak self] in self?.beginSearchForPaste() }
        panel.handleGroupShortcut = { [weak self] event in self?.handleGroupShortcut(event) ?? false }
        panel.handleGroupJoinKey = { [weak self] event in self?.handleGroupJoinKey(event) ?? false }
        panel.handleGroupConfirmationKey = { [weak self] event in self?.groupEditor?.handleDeleteConfirmationKey(event) ?? false }
        panel.handleAppShortcut = { [weak self] event in self?.handleAppShortcut(event) ?? false }
        collection.handleAppShortcut = { [weak self] event in self?.handleAppShortcut(event) ?? false }
        collection.handleGroupJoinKey = { [weak self] event in self?.handleGroupJoinKey(event) ?? false }
        panel.onUseCurrentCard = { [weak self] in self?.use() }
        panel.isCardMode = { [weak self] in
            self?.interactionMode == .cards && self?.isGroupInteractionVisible == false
        }
        panel.shouldUseCurrentCard = { [weak self] in self?.shouldRouteReturnToCards == true }
        panel.onAfterEvent = { [weak self] in
            guard self?.groupEditor != nil || self?.groupPicker != nil else { return }
            self?.updateActions()
        }
        buildUI()
        appShortcutsChanged()
        model.onChange = { [weak self] in self?.modelDidChange() }
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onFeedback = { [weak self] message in self?.showFeedback(message) }
        NotificationCenter.default.addObserver(self, selector: #selector(appShortcutsChanged), name: .appShortcutsDidChange, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    var isVisible: Bool { window?.isVisible == true }
    var allowPresentation: () -> Bool = { true }
    func toggle() { isVisible ? dismiss() : show() }
    func show() {
        guard allowPresentation() else { return }
        guard !isVisible else {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            focusForCurrentMode()
            return
        }
        returnApp = NSWorkspace.shared.frontmostApplication
        if returnApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier { returnApp = nil }
        model.paste.captureTarget()
        prepareForDisplay()
        position()
        prepareEntranceAnimation()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusCards()
        installOutsideMonitor()
    }

    func prepareForDisplay() {
        closeGroupInteraction()
        displayPrepared = true
        search.stringValue = ""; selectedGroupID = nil
        interactionMode = .cards
        clearSearchSession()
        refreshGroupButtons()
        updateToolbarPresentation()
        applyResults(query: "", groupID: nil, preferredSelection: model.entries.first?.id)
        focusCards()
    }
    func dismiss() {
        displayPrepared = false
        queryGeneration += 1
        closing = true
        background.layer?.removeAnimation(forKey: "panelEntrance")
        preview?.close(); preview = nil
        closeGroupInteraction()
        window?.orderOut(nil)
        closing = false
        collection.visibleItems().compactMap { $0 as? CardItem }.forEach { $0.clearContent() }
        searchCoordinator.cancel()
        results = nil; selectedID = nil
        collection.reloadData()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let returnApp, !returnApp.isTerminated { returnApp.activate(options: []) }
    }
    private func showFeedback(_ message: String) {
        guard allowPresentation() else { return }
        let shouldAnimate = !isVisible
        position()
        if shouldAnimate { prepareEntranceAnimation() }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        hint.stringValue = message; hint.textColor = .systemOrange; installOutsideMonitor()
    }
    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let frame = PanelLayout.frame(
            at: mouse,
            screenFrames: NSScreen.screens.map(\.frame),
            fallback: NSScreen.main?.frame
        ) else { return }
        window?.setFrame(frame, display: true)
    }
    private func prepareEntranceAnimation() {
        guard let layer = background.layer else { return }
        layer.removeAnimation(forKey: "panelEntrance")
        let offset = PanelLayout.entranceOffset(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        guard offset != 0 else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = offset
        animation.toValue = 0
        animation.duration = PanelLayout.entranceDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "panelEntrance")
    }
    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.handleOutsideMouseDown(at: NSEvent.mouseLocation)
        }
    }
    func handleOutsideMouseDown(at screenLocation: NSPoint) {
        guard isVisible, window?.frame.contains(screenLocation) != true else { return }
        model.paste.invalidate(); dismiss()
    }
    static func shouldDismissAfterResigningKey(applicationIsActive: Bool, hasDifferentKeyWindow: Bool) -> Bool {
        !applicationIsActive || hasDifferentKeyWindow
    }
    func windowDidResignKey(_ notification: Notification) {
        guard !closing, !statusMenuOpen, preview?.window?.isVisible != true,
              groupPicker == nil, groupEditor == nil else { return }
        let generation = focusLossGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusLossGeneration == generation, !self.statusMenuOpen,
                  self.window?.isKeyWindow != true, self.preview?.window?.isVisible != true,
                  self.groupPicker == nil, self.groupEditor == nil else { return }
            let anotherAppWindowIsKey = NSApp.isActive && NSApp.keyWindow != nil && NSApp.keyWindow !== self.window
            guard Self.shouldDismissAfterResigningKey(
                applicationIsActive: NSApp.isActive,
                hasDifferentKeyWindow: anotherAppWindowIsKey
            ) else { return }
            self.model.paste.invalidate(); self.dismiss()
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard displayPrepared, groupPicker == nil, groupEditor == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow == true else { return }
            self.focusForCurrentMode()
        }
    }
    private func buildUI() {
        window?.contentView = background
        search.cell = HistorySearchCell(textCell: "")
        search.isEditable = true; search.isSelectable = true
        search.placeholderString = L("搜索内容或来源"); search.delegate = self; search.sendsSearchStringImmediately = true
        search.placeholderAttributedString = NSAttributedString(string: L("搜索内容或来源"), attributes: [
            .foregroundColor: PanelPalette.secondaryText, .font: NSFont.systemFont(ofSize: 13)
        ])
        search.controlSize = .regular; search.font = .systemFont(ofSize: 13)
        search.setAccessibilityLabel(L("搜索历史内容或来源"))
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        searchButton.imagePosition = .imageOnly; searchButton.isBordered = false; searchButton.focusRingType = .none
        searchButton.contentTintColor = PanelPalette.secondaryText
        searchButton.target = self; searchButton.action = #selector(searchButtonPressed)
        searchButton.toolTip = L("搜索"); searchButton.setAccessibilityLabel(L("搜索历史"))
        newGroupButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        newGroupButton.imagePosition = .imageOnly; newGroupButton.isBordered = false; newGroupButton.focusRingType = .none
        newGroupButton.contentTintColor = PanelPalette.secondaryText
        newGroupButton.target = self; newGroupButton.action = #selector(newGroupButtonPressed)
        newGroupButton.toolTip = L("新建分组"); newGroupButton.setAccessibilityLabel(L("新建分组"))
        groupStack.orientation = .horizontal; groupStack.spacing = 4; groupStack.alignment = .centerY
        groupDropIndicator.wantsLayer = true; groupDropIndicator.layer?.cornerRadius = 1
        groupDropIndicator.isHidden = true; groupStack.addSubview(groupDropIndicator)
        groupScroll.documentView = groupStack; groupScroll.drawsBackground = false
        groupScroll.hasHorizontalScroller = false; groupScroll.hasVerticalScroller = false
        groupScroll.horizontalScrollElasticity = .allowed; groupScroll.verticalScrollElasticity = .none
        groupScroll.contentView.drawsBackground = false; groupScroll.setAccessibilityLabel(L("自定义分组"))
        idleToolbar.orientation = .horizontal; idleToolbar.spacing = 6; idleToolbar.alignment = .centerY
        idleToolbar.addArrangedSubview(searchButton); idleToolbar.addArrangedSubview(newGroupButton)
        idleToolbar.addArrangedSubview(groupScroll)
        search.isBezeled = false; search.isBordered = true
        search.drawsBackground = false; search.focusRingType = .none
        search.textColor = PanelPalette.primaryText
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchScopeChip.bezelStyle = .roundRect; searchScopeChip.controlSize = .small
        searchScopeChip.isBordered = false
        searchScopeChip.contentTintColor = PanelPalette.secondaryText
        searchScopeChip.font = .systemFont(ofSize: 10.5, weight: .medium)
        searchScopeChip.target = self; searchScopeChip.action = #selector(removeSearchScope)
        searchScopeChip.cell?.lineBreakMode = .byTruncatingTail
        searchScopeChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchScopeChip.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
        searchBar.addArrangedSubview(searchScopeChip); searchBar.addArrangedSubview(search)
        searchToolbar.orientation = .horizontal; searchToolbar.alignment = .centerY
        searchToolbar.addArrangedSubview(searchBar)
        [idleToolbar, searchToolbar].forEach { background.contentView.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        searchButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        searchButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        newGroupButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        newGroupButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        groupScroll.heightAnchor.constraint(equalToConstant: 28).isActive = true
        groupScrollWidthConstraint = groupScroll.widthAnchor.constraint(equalToConstant: 0)
        groupScrollWidthConstraint?.isActive = true
        searchBar.widthAnchor.constraint(equalToConstant: 430).isActive = true
        searchBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        NSLayoutConstraint.activate([
            idleToolbar.topAnchor.constraint(equalTo: background.topAnchor, constant: 13),
            idleToolbar.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            idleToolbar.heightAnchor.constraint(equalToConstant: PanelLayout.toolbarHeight),
            searchToolbar.topAnchor.constraint(equalTo: background.topAnchor, constant: 13),
            searchToolbar.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            searchToolbar.heightAnchor.constraint(equalToConstant: PanelLayout.toolbarHeight)
        ])
        search.nextKeyView = searchScopeChip
        searchScopeChip.nextKeyView = search
        refreshGroupButtons()
        updateToolbarPresentation()
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal; layout.itemSize = PanelLayout.cardSize
        layout.minimumLineSpacing = 10; layout.minimumInteritemSpacing = 10; layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collection.collectionViewLayout = layout; collection.isSelectable = true; collection.allowsMultipleSelection = false
        collection.dataSource = self; collection.delegate = self; collection.backgroundColors = [.clear]
        collection.focusRingType = .none
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        collection.setDraggingSourceOperationMask([], forLocal: false)
        collection.register(CardItem.self, forItemWithIdentifier: .init("Card"))
        collection.setAccessibilityLabel(L("历史记录，左右键浏览，回车使用，选项回车纯文本使用，空格预览"))
        collection.onUse = { [weak self] index in self?.use(index: index) }
        collection.onMove = { [weak self] delta in self?.move(delta) }
        collection.onPreview = { [weak self] in self?.openPreview() }
        collection.onClose = { [weak self] in self?.dismiss() }
        collection.onDelete = { [weak self] in self?.deleteSelection() }
        collection.onBeginSearch = { [weak self] event in self?.beginSearch(forwarding: event) }
        collection.onActivateCards = { [weak self] in self?.activateCards() }
        scroll.documentView = collection; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.drawsBackground = false; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        background.contentView.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 49), scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8), scroll.heightAnchor.constraint(equalToConstant: PanelLayout.collectionHeight)])
        emptyIcon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        emptyIcon.contentTintColor = PanelPalette.secondaryText
        emptyTitle.font = .systemFont(ofSize: 14, weight: .semibold); emptyTitle.textColor = PanelPalette.primaryText; emptyTitle.alignment = .center
        emptyDetail.font = .systemFont(ofSize: 11); emptyDetail.textColor = PanelPalette.secondaryText; emptyDetail.alignment = .center
        emptyStack.orientation = .vertical; emptyStack.alignment = .centerX; emptyStack.spacing = 6
        [emptyIcon, emptyTitle, emptyDetail].forEach(emptyStack.addArrangedSubview)
        background.contentView.addSubview(emptyStack); emptyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([emptyStack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), emptyStack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)])
        hint.font = .systemFont(ofSize: 11, weight: .medium); hint.textColor = PanelPalette.secondaryText; hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        background.contentView.addSubview(hint); hint.translatesAutoresizingMaskIntoConstraints = false
        hintIdleTrailing = hint.trailingAnchor.constraint(lessThanOrEqualTo: idleToolbar.leadingAnchor, constant: -14)
        hintSearchTrailing = hint.trailingAnchor.constraint(lessThanOrEqualTo: searchToolbar.leadingAnchor, constant: -14)
        hintIdleTrailing?.priority = .defaultHigh; hintSearchTrailing?.priority = .defaultHigh
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            hint.centerYAnchor.constraint(equalTo: idleToolbar.centerYAnchor),
            hint.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        updateToolbarPresentation()
        window?.initialFirstResponder = collection
    }
    private func modelDidChange() {
        guard displayPrepared else { return }
        if let entryID = groupJoinEntryID {
            if !model.containsEntry(id: entryID) || model.groups.isEmpty {
                closeGroupInteraction(); restorePanelFocus()
            } else if !model.groups.contains(where: { $0.id == groupJoinTargetID }) {
                groupJoinTargetID = model.groups.first?.id
            }
        }
        if let selectedGroupID, !model.groups.contains(where: { $0.id == selectedGroupID }) {
            self.selectedGroupID = nil
        }
        if let searchOriginGroupID, !model.groups.contains(where: { $0.id == searchOriginGroupID }) {
            self.searchOriginGroupID = nil
        }
        if let searchScopeGroupID, !model.groups.contains(where: { $0.id == searchScopeGroupID }) {
            self.searchScopeGroupID = nil
        }
        refreshGroupButtons()
        groupPicker?.reloadGroups()
        updateToolbarPresentation()
        reload()
    }
    func reload() {
        queryGeneration += 1
        let generation = queryGeneration
        let query = search.stringValue
        let groupID = resultGroupID
        searchCoordinator.submit(query: query, groupID: groupID) { [weak self] result in
            guard let self, self.queryGeneration == generation, self.displayPrepared else { return }
            switch result {
            case .success(let values):
                self.render(values, query: query, groupID: groupID, preferredSelection: self.selectedID)
            case .failure(let error): self.showFeedback(L("无法读取历史：\(error.localizedDescription)"))
            }
        }
    }

    private func applyResults(query: String, groupID: String?, preferredSelection: String?) {
        queryGeneration += 1
        searchCoordinator.cancel()
        do {
            let values = try HistoryQueryResults(directory: model.store.directory, query: query, groupID: groupID)
            render(values, query: query, groupID: groupID, preferredSelection: preferredSelection)
        } catch { showFeedback(L("无法读取历史：\(error.localizedDescription)")) }
    }

    private func render(_ values: HistoryQueryResults, query: String, groupID: String?, preferredSelection: String?) {
        results = values
        if let preferredSelection, (try? values.index(of: preferredSelection)) != nil {
            selectedID = preferredSelection
        } else {
            selectedID = (try? values.entry(at: 0))?.id
        }
        collection.reloadData()
        if let selectedID, let index = try? values.index(of: selectedID) {
            collection.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        } else {
            collection.selectionIndexPaths = []
        }
        emptyStack.isHidden = inlineGroupView != nil || !values.isEmpty
        if !query.isEmpty {
            emptyIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            emptyTitle.stringValue = L("没有匹配的内容")
            emptyDetail.stringValue = L("换个关键词，或按 Esc 取消搜索")
        } else if groupID != nil {
            emptyIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            emptyTitle.stringValue = L("这个分组还没有内容")
            emptyDetail.stringValue = L("在历史中选中一条记录，按 \(appShortcuts.display(for: .addToGroup)) 加入分组")
        } else {
            emptyIcon.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
            emptyTitle.stringValue = L("还没有剪贴板记录")
            emptyDetail.stringValue = L("复制文字、图片或文件后会显示在这里")
        }
        updateActions()
    }

    private func enterSearchState() {
        guard interactionMode == .cards else { return }
        if !searchSessionActive {
            searchSessionActive = true
            searchOriginGroupID = selectedGroupID
            searchOriginSelectionID = selectedID
            searchScopeGroupID = selectedGroupID
        }
        interactionMode = .search
        updateToolbarPresentation()
        updateActions()
    }

    func beginSearch(selectAll: Bool) {
        guard !isGroupInteractionVisible else { return }
        enterSearchState()
        window?.makeFirstResponder(search)
        guard let editor = search.currentEditor() as? NSTextView
                ?? window?.fieldEditor(true, for: search) as? NSTextView else { return }
        editor.insertionPointColor = PanelPalette.primaryText
        let range = selectAll
            ? NSRange(location: 0, length: (search.stringValue as NSString).length)
            : NSRange(location: (search.stringValue as NSString).length, length: 0)
        editor.setSelectedRange(range)
    }

    func beginSearch(forwarding event: NSEvent) {
        guard !isGroupInteractionVisible else { return }
        beginSearch(selectAll: false)
        guard let editor = search.currentEditor() as? NSTextView
                ?? window?.fieldEditor(true, for: search) as? NSTextView else { return }
        editor.keyDown(with: event)
    }

    func beginSearchForPaste() {
        guard !isGroupInteractionVisible else { return }
        beginSearch(selectAll: false)
        (search.currentEditor() as? NSTextView)?.paste(nil)
    }

    func finishSearch() {
        guard interactionMode == .search else { return }
        let query = search.stringValue
        let preferred = selectedID
        let groupID = searchScopeGroupID
        interactionMode = .cards
        applyResults(query: query, groupID: groupID, preferredSelection: preferred)
        if query.isEmpty { clearSearchSession() }
        updateToolbarPresentation()
        focusCards()
        updateActions()
    }

    func cancelSearch() {
        guard interactionMode == .search else { dismiss(); return }
        let preferred = searchOriginSelectionID
        let groupID = searchOriginGroupID
        search.stringValue = ""
        interactionMode = .cards
        selectedGroupID = groupID
        clearSearchSession()
        refreshGroupButtons()
        applyResults(query: "", groupID: groupID, preferredSelection: preferred)
        updateToolbarPresentation()
        focusCards()
        updateActions()
    }

    private func activateCards() {
        guard interactionMode == .search else { return }
        finishSearch()
    }

    private func focusForCurrentMode() {
        if let groupCreationView { groupCreationView.focus(); return }
        if let groupLabelEditor { groupLabelEditor.focus(); return }
        if let groupEditor { groupEditor.focus(); return }
        if let groupPicker { groupPicker.focus(); return }
        if interactionMode == .search {
            beginSearch(selectAll: false)
        } else {
            focusCards()
        }
    }

    private func focusCards() {
        window?.initialFirstResponder = collection
        _ = window?.makeFirstResponder(collection)
    }

    private var shouldRouteReturnToCards: Bool {
        guard !isGroupInteractionVisible, interactionMode == .cards, let responder = window?.firstResponder else { return false }
        return responder === collection || responder === search || responder === search.currentEditor()
    }

    private func clearSearchSession() {
        searchSessionActive = false
        searchOriginGroupID = nil
        searchOriginSelectionID = nil
        searchScopeGroupID = nil
    }

    private func handlePanelCancel() {
        if groupJoinEntryID != nil { closeGroupInteraction(); restorePanelFocus(); return }
        if groupCreationView != nil { closeGroupInteraction(); restorePanelFocus(); return }
        if groupLabelEditor != nil { cancelGroupRename(); return }
        if let groupEditor, groupEditor.isConfirmingDelete {
            groupEditor.cancelDelete()
            updateActions()
            return
        }
        if inlineGroupView != nil { closeGroupInteraction(); restorePanelFocus(); return }
        if interactionMode == .search { cancelSearch() } else { dismiss() }
    }
    private func updateActions() {
        let previous = groupShortcuts.shortcut(for: .previous)
        let next = groupShortcuts.shortcut(for: .next)
        let keyboardHint: String
        var detail = ""
        if draggedGroupID != nil {
            keyboardHint = L("松开排序   Esc 取消")
        } else if cardDragEntryID != nil {
            keyboardHint = L("拖到组名加入   Esc 取消")
        } else if groupJoinEntryID != nil {
            keyboardHint = L("←→ 选择分组   空格 / ↩ 加入   Esc 取消")
        } else if groupCreationView != nil {
            keyboardHint = L("↩ 创建   Esc 取消")
        } else if groupLabelEditor != nil {
            keyboardHint = L("↩ 保存   Esc 取消")
            detail = L("Tab 可达前移、后移和保存")
        } else if groupEditor?.isConfirmingDelete == true {
            keyboardHint = L("Tab 切换   空格 / ↩ 执行   Esc 取消")
            detail = L("Tab / ⇧Tab 在取消和确认删除之间切换，默认选择取消")
        } else if groupEditor != nil {
            keyboardHint = L("↩ 保存   Esc 取消")
        } else if groupPicker != nil {
            keyboardHint = window?.firstResponder is GroupPickerTable
                ? L("↑↓ 选择   空格 / ↩ 确认   Esc 返回")
                : L("输入筛选   ↓ 选择列表   ↩ 确认   Esc 返回")
        } else if inlineGroupView != nil {
            keyboardHint = L("Esc 返回")
        } else if interactionMode == .search {
            keyboardHint = L("\(previous) / \(next) 切范围   ↩ 完成   Esc 取消")
        } else if !search.stringValue.isEmpty {
            let deletion = resultGroupID == nil ? L("Delete 永久删除") : L("Delete 移出当前组")
            keyboardHint = L("←→ 选择   ↩ 使用   \(previous) / \(next) 切范围")
            detail = L("\(appShortcuts.display(for: .beginSearch)) 编辑   \(deletion)   Esc 关闭")
        } else if selectedGroupName != nil {
            keyboardHint = L("←→ 选择   ↩ 使用   \(previous) / \(next) 切组")
            detail = L("双击名称编辑   拖动组名排序   \(appShortcuts.display(for: .addToGroup)) 加入其它分组   Delete 移出当前组")
        } else {
            keyboardHint = L("←→ 选择   ↩ 使用   \(previous) / \(next) 切组")
            detail = L("\(appShortcuts.display(for: .beginSearch)) 搜索   \(appShortcuts.display(for: .addToGroup)) 加入分组   Delete 永久删除   Esc 关闭")
        }
        if !isGroupInteractionVisible && interactionMode == .cards {
            detail += L("   \(appShortcuts.display(for: .usePlainText)) 纯文本使用")
        }
        hint.stringValue = model.busy ? L("正在取回内容…") : (model.status ?? (model.settings.paused ? L("已暂停记录") : keyboardHint))
        hint.textColor = model.status == nil ? PanelPalette.secondaryText : .systemOrange
        hint.toolTip = model.status == nil && !detail.isEmpty ? hint.stringValue + "   " + detail : hint.stringValue
    }
    private func resultEntry(at index: Int) -> HistoryEntry? { try? results?.entry(at: index) }
    private func resultIndex(of id: String?) -> Int? {
        guard let id else { return nil }
        return try? results?.index(of: id)
    }
    private var selectedEntry: HistoryEntry? {
        guard let index = resultIndex(of: selectedID) else { return nil }
        return resultEntry(at: index)
    }
    func statusMenuWillOpen() {
        focusLossGeneration += 1
        statusMenuOpen = true
        restoreFocusAfterStatusMenu = true
    }
    func statusMenuDidClose() {
        statusMenuOpen = false
        guard restoreFocusAfterStatusMenu, isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusForCurrentMode()
    }
    func copySelected() {
        guard canActOnSelectedEntry else { return }
        if statusMenuOpen { restoreFocusAfterStatusMenu = false }
        use(copyOnly: true)
    }
    func useSelectedAsPlainText() {
        guard canUseSelectedEntryAsPlainText else { return }
        if statusMenuOpen { restoreFocusAfterStatusMenu = false }
        use(plain: true)
    }
    func deleteSelected() {
        guard canActOnSelectedEntry else { return }
        deleteSelection()
    }
    func permanentlyDeleteSelected() {
        guard canActOnSelectedEntry, let selectedID else { return }
        model.delete(id: selectedID)
    }
    func showGroupPicker() {
        guard canActOnSelectedEntry, let selectedID else { return }
        guard !model.groups.isEmpty else {
            hint.stringValue = L("请先用 + 新建分组"); hint.toolTip = hint.stringValue
            return
        }
        groupJoinEntryID = selectedID
        groupJoinTargetID = model.groups.first { !model.groupIDs(for: selectedID).contains($0.id) }?.id ?? model.groups.first?.id
        refreshGroupButtons(); updateToolbarPresentation(); updateActions()
        focusCards()
    }
    @objc private func manageGroupsPressed() { showGroupManagement() }
    func showGroupManagement() {
        show()
        if model.groups.isEmpty { showGroupEditor(groupID: nil); return }
        presentGroupPicker(entryID: nil)
    }
    private func presentGroupPicker(entryID: String?) {
        closeGroupInteraction()
        let picker = GroupPickerController(model: model, entryID: entryID)
        picker.onClose = { [weak self] in self?.closeGroupInteraction(); self?.restorePanelFocus() }
        picker.onChooseGroup = { [weak self] id in self?.showGroupEditor(groupID: id) }
        groupPicker = picker
        embedGroupView(picker.view)
        picker.focus()
    }
    private func embedGroupView(_ view: NSView) {
        inlineGroupView = view
        scroll.isHidden = true; emptyStack.isHidden = true
        background.contentView.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        let width = view.widthAnchor.constraint(equalToConstant: 720)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            width,
            view.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -32),
            view.topAnchor.constraint(equalTo: scroll.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)
        ])
        updateActions()
    }
    func closeGroupInteraction() {
        if groupJoinEntryID != nil || cardDragEntryID != nil {
            groupJoinEntryID = nil; groupJoinTargetID = nil; cardDragEntryID = nil
            refreshGroupButtons(); updateToolbarPresentation()
        }
        if draggedGroupID != nil { finishGroupDrag(commit: false) }
        if let groupCreationView {
            window?.makeFirstResponder(nil)
            groupCreationView.onSubmit = nil; groupCreationView.onCancel = nil
            searchToolbar.removeArrangedSubview(groupCreationView); groupCreationView.removeFromSuperview()
            self.groupCreationView = nil
            updateToolbarPresentation()
        }
        if groupLabelEditor != nil {
            groupLabelEditor = nil
            refreshGroupButtons()
        }
        groupPicker?.onClose = nil; groupEditor?.onClose = nil
        groupPicker = nil; groupEditor = nil
        inlineGroupView?.removeFromSuperview(); inlineGroupView = nil
        scroll.isHidden = false; emptyStack.isHidden = (results?.isEmpty == false)
        updateActions()
    }
    private func use(index: Int? = nil, plain: Bool = false, copyOnly: Bool = false) {
        if let index {
            guard results?.indices.contains(index) == true else { return }
            selectedID = resultEntry(at: index)?.id
        }
        guard let selectedID else { return }
        model.use(id: selectedID, plainText: plain, copyOnly: copyOnly)
    }
    private func move(_ delta: Int) {
        guard (results?.isEmpty == false) else { return }
        let current = resultIndex(of: selectedID) ?? (delta > 0 ? -1 : (results?.count ?? 0))
        let index = min(max(current + delta, 0), (results?.count ?? 0) - 1)
        let indexPath = IndexPath(item: index, section: 0)
        selectedID = resultEntry(at: index)?.id; collection.selectionIndexPaths = [indexPath]
        reveal(indexPath)
        window?.makeFirstResponder(collection); updateActions()
    }
    private func reveal(_ indexPath: IndexPath) {
        collection.layoutSubtreeIfNeeded()
        guard let attributes = collection.collectionViewLayout?.layoutAttributesForItem(at: indexPath) else { return }
        let visible = collection.visibleRect
        var origin = scroll.contentView.bounds.origin
        if attributes.frame.minX < visible.minX {
            origin.x = attributes.frame.minX
        } else if attributes.frame.maxX > visible.maxX {
            origin.x = attributes.frame.maxX - visible.width
        } else {
            return
        }
        let maximumX = max(0, collection.bounds.width - visible.width)
        origin.x = min(max(0, origin.x), maximumX)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func deleteSelection() {
        guard let selectedID else { return }
        if let groupID = resultGroupID { model.remove(entryID: selectedID, fromGroup: groupID) }
        else { model.delete(id: selectedID) }
    }
    private func openPreview() {
        guard let selectedID else { return }
        model.loadContent(id: selectedID) { [weak self] result in
            guard let self, self.isVisible, self.selectedID == selectedID else { return }
            switch result {
            case .success(let content):
                self.preview = PreviewController(content: content)
                self.preview?.onClose = { [weak self] in
                    self?.preview = nil
                    self?.restorePanelFocus()
                }
                self.preview?.showWindow(nil)
            case .failure(let error): self.showFeedback(error.localizedDescription)
            }
        }
    }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        !isGroupInteractionVisible && !model.busy && !model.groups.isEmpty && indexPaths.count == 1
            && indexPaths.allSatisfy { results?.indices.contains($0.item) == true }
    }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard results?.indices.contains(indexPath.item) == true else { return nil }
        let item = NSPasteboardItem()
        guard let entry = resultEntry(at: indexPath.item) else { return nil }
        item.setString(entry.id, forType: CardGroupDrag.pasteboardType)
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        collection.didBeginCardDrag = true
        cardDragEntryID = session.draggingPasteboard.string(forType: CardGroupDrag.pasteboardType)
        let point = collectionView.convert(window?.convertPoint(fromScreen: screenPoint) ?? .zero, from: nil)
        if let index = indexPaths.first, let card = collectionView.item(at: index) as? CardItem,
           let image = card.card.makeDragPreview() {
            session.enumerateDraggingItems(options: [], for: collectionView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                item.setDraggingFrame(NSRect(x: point.x + 16, y: point.y + 18, width: image.size.width, height: image.size.height), contents: image)
            }
        }
        refreshGroupButtons(); updateToolbarPresentation(); updateActions()
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        cardDragEntryID = nil
        refreshGroupButtons(); updateToolbarPresentation(); updateActions()
    }
    private func validCardDrop(_ info: NSDraggingInfo, groupID: String) -> String? {
        guard info.draggingSource as? NSCollectionView === collection,
              info.draggingSourceOperationMask.contains(.copy),
              groupJoinEntryID == nil, inlineGroupView == nil, groupCreationView == nil,
              groupLabelEditor == nil, draggedGroupID == nil,
              let entryID = info.draggingPasteboard.string(forType: CardGroupDrag.pasteboardType),
              cardDragEntryID == nil || cardDragEntryID == entryID,
              model.containsEntry(id: entryID),
              model.groups.contains(where: { $0.id == groupID }),
              !model.groupIDs(for: entryID).contains(groupID) else { return nil }
        return entryID
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { results?.count ?? 0 }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("Card"), for: indexPath) as! CardItem
        guard let entry = resultEntry(at: indexPath.item) else { item.clearContent(); return item }
        item.configure(
            entry,
            thumbnail: model.store.thumbnailURL(for: entry),
            sourceIcon: model.store.sourceIconURL(for: entry),
            linkIcon: model.store.linkIconURL(for: entry),
            linkPreview: model.store.linkPreviewURL(for: entry),
            imageCache: imageCache,
            number: indexPath.item + 1
        )
        item.card.positionShortcut = AppShortcutAction.allCases.first { $0.position == indexPath.item }.map { appShortcuts.display(for: $0) }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, results?.indices.contains(index) == true else { return }
        selectedID = resultEntry(at: index)?.id; updateActions()
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        (search.currentEditor() as? NSTextView)?.insertionPointColor = PanelPalette.primaryText
        if interactionMode != .search { enterSearchState() }
    }
    func controlTextDidChange(_ notification: Notification) {
        if interactionMode != .search { enterSearchState() }
        selectedID = nil
        updateToolbarPresentation()
        reload()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishSearch(); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelSearch(); return true }
        return false
    }
    @objc private func searchButtonPressed() { beginSearch(selectAll: false) }
    @objc private func newGroupButtonPressed() { showGroupEditor(groupID: nil) }
    @objc func removeSearchScope() {
        guard isSearchPresentationVisible, searchScopeGroupID != nil else { return }
        let preferred = selectedID
        searchScopeGroupID = nil
        updateToolbarPresentation()
        applyResults(query: search.stringValue, groupID: nil, preferredSelection: preferred)
        if interactionMode == .search {
            window?.makeFirstResponder(search)
        } else {
            focusCards()
        }
    }
    @objc private func groupPressed(_ sender: GroupButton) {
        if groupJoinEntryID != nil {
            groupJoinTargetID = sender.groupID; refreshGroupButtons(); focusCards()
            return
        }
        guard !isGroupInteractionVisible, selectedGroupID != sender.groupID else { return }
        selectGroup(sender.groupID)
    }
    func selectGroup(_ groupID: String?) {
        closeGroupInteraction()
        guard groupID == nil || model.groups.contains(where: { $0.id == groupID }) else { return }
        let target = selectedGroupID == groupID ? nil : groupID
        let preferred = selectedID
        selectedGroupID = target
        search.stringValue = ""; interactionMode = .cards; clearSearchSession()
        refreshGroupButtons(); updateToolbarPresentation()
        applyResults(query: "", groupID: target, preferredSelection: preferred)
        focusCards()
        ensureSelectedGroupVisible()
    }
    func cycleGroup(forward: Bool) {
        guard !isGroupInteractionVisible else { return }
        let editor = search.currentEditor() as? NSTextView
        guard editor?.hasMarkedText() != true else { return }
        let isSearching = isSearchPresentationVisible && searchSessionActive
        let currentGroupID = isSearching ? searchScopeGroupID : selectedGroupID
        let selectedRange = editor?.selectedRange()
        let states: [String?] = [nil] + model.groups.map { Optional($0.id) }
        guard !states.isEmpty else { return }
        let current = states.firstIndex { $0 == currentGroupID } ?? 0
        let next = forward
            ? (current + 1) % states.count
            : (current - 1 + states.count) % states.count
        selectedGroupID = states[next]
        if isSearching {
            searchScopeGroupID = selectedGroupID
            refreshGroupButtons(); updateToolbarPresentation()
            applyResults(query: search.stringValue, groupID: searchScopeGroupID, preferredSelection: nil)
            if interactionMode == .search {
                if window?.firstResponder !== editor { window?.makeFirstResponder(search) }
                if let selectedRange { (search.currentEditor() as? NSTextView)?.setSelectedRange(selectedRange) }
            } else {
                focusCards()
            }
            return
        }
        search.stringValue = ""; clearSearchSession()
        refreshGroupButtons(); updateToolbarPresentation()
        applyResults(query: "", groupID: selectedGroupID, preferredSelection: nil)
        focusCards()
        ensureSelectedGroupVisible()
    }

    private var isSearchPresentationVisible: Bool {
        interactionMode == .search || !search.stringValue.isEmpty
    }

    private var resultGroupID: String? {
        isSearchPresentationVisible && searchSessionActive ? searchScopeGroupID : selectedGroupID
    }

    private var resultGroupName: String? {
        guard let resultGroupID else { return nil }
        return model.groups.first { $0.id == resultGroupID }?.name
    }

    private func refreshGroupButtons() {
        let editing = groupLabelEditor
        let textEditor = editing?.nameControl.currentEditor() as? NSTextView
        let selectedRange = textEditor?.selectedRange()
        let focusedControl = window?.firstResponder as? NSView
        if let editing, !model.groups.contains(where: { $0.id == editing.groupID }) { groupLabelEditor = nil }
        groupStack.arrangedSubviews.forEach { groupStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        deleteGroupControl = nil
        groupButtons = model.groups.map { group in
            let button = GroupButton(group: group, target: self, action: #selector(groupPressed(_:)))
            button.font = .systemFont(ofSize: 12, weight: group.id == selectedGroupID ? .semibold : .regular)
            button.contentTintColor = group.id == selectedGroupID ? .controlAccentColor : PanelPalette.secondaryText
            button.onRename = { [weak self] in
                guard self?.groupJoinEntryID == nil, self?.cardDragEntryID == nil else { return }
                self?.beginGroupRename(group.id)
            }
            if let entryID = groupJoinEntryID ?? cardDragEntryID, model.groupIDs(for: entryID).contains(group.id) { button.title += " ✓" }
            button.widthAnchor.constraint(equalToConstant: button.intrinsicContentSize.width + 8).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.isJoinTarget = groupJoinEntryID != nil && groupJoinTargetID == group.id
            button.onCardDragValidation = { [weak self] info in self?.validCardDrop(info, groupID: group.id) != nil }
            button.onCardDrop = { [weak self] info in
                guard let self, let entryID = self.validCardDrop(info, groupID: group.id) else { return false }
                self.model.add(entryID: entryID, toGroup: group.id)
                return true
            }
            button.onDragBegan = { [weak self] in self?.beginGroupDrag(group.id) ?? false }
            button.onDragChanged = { [weak self] event in self?.updateGroupDrag(event) }
            button.onDragEnded = { [weak self] event in self?.finishGroupDrag(commit: event != nil) }
            button.toolTip = groupJoinEntryID != nil ? L("单击选择目标，按空格或 Return 加入；✓ 表示已加入") : L("单击进入分组，双击编辑名称，拖动调整顺序；拖入卡片加入分组")
            if let editor = groupLabelEditor, editor.groupID == group.id {
                let index = model.groups.firstIndex { $0.id == group.id } ?? 0
                editor.earlierControl.isEnabled = index > 0
                editor.laterControl.isEnabled = index + 1 < model.groups.count
                groupStack.addArrangedSubview(editor)
            } else {
                groupStack.addArrangedSubview(button)
                if group.id == selectedGroupID && groupJoinEntryID == nil && cardDragEntryID == nil {
                    let delete = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!, target: self, action: #selector(requestSelectedGroupDeletion))
                    delete.isBordered = false; delete.contentTintColor = .secondaryLabelColor
                    delete.toolTip = L("删除分组：\(group.name)")
                    delete.setAccessibilityLabel(L("删除分组：\(group.name)"))
                    delete.widthAnchor.constraint(equalToConstant: 20).isActive = true
                    groupStack.addArrangedSubview(delete); deleteGroupControl = delete
                } else {
                    let space = NSView()
                    space.widthAnchor.constraint(equalToConstant: 20).isActive = true
                    groupStack.addArrangedSubview(space)
                }
            }
            return button
        }
        groupStack.frame = NSRect(origin: .zero, size: NSSize(width: max(1, groupStack.fittingSize.width), height: 28))
        let width = min(groupStack.frame.width, 620)
        groupScrollWidthConstraint?.constant = model.groups.isEmpty ? 0 : width
        groupScroll.isHidden = model.groups.isEmpty
        idleToolbar.layoutSubtreeIfNeeded()
        ensureSelectedGroupVisible()
        if let editing, editing === groupLabelEditor {
            if let selectedRange {
                editing.focus()
                (editing.nameControl.currentEditor() as? NSTextView)?.setSelectedRange(selectedRange)
            } else if let focusedControl, focusedControl.isDescendant(of: editing) {
                window?.makeFirstResponder(focusedControl)
            }
        }
    }
    private func ensureSelectedGroupVisible() {
        if let groupLabelEditor { groupLabelEditor.scrollToVisible(groupLabelEditor.bounds); return }
        guard let button = groupButtons.first(where: { $0.groupID == (groupJoinTargetID ?? selectedGroupID) }) else {
            groupScroll.contentView.scroll(to: .zero); groupScroll.reflectScrolledClipView(groupScroll.contentView); return
        }
        groupStack.layoutSubtreeIfNeeded()
        button.scrollToVisible(button.bounds)
    }

    private func beginGroupDrag(_ groupID: String) -> Bool {
        guard !isGroupInteractionVisible, model.groups.contains(where: { $0.id == groupID }) else { return false }
        draggedGroupID = groupID; groupDropSlot = nil
        updateActions()
        return true
    }

    private func updateGroupDrag(_ event: NSEvent) {
        guard let draggedGroupID, model.groups.contains(where: { $0.id == draggedGroupID }) else { return }
        let pointInScroll = groupScroll.convert(event.locationInWindow, from: nil)
        guard groupScroll.bounds.insetBy(dx: 0, dy: -8).contains(pointInScroll) else {
            groupDropSlot = nil; groupDropIndicator.isHidden = true
            return
        }
        let visible = groupScroll.contentView.bounds
        let maxOffset = max(0, groupStack.bounds.width - visible.width)
        let direction: CGFloat = pointInScroll.x < 24 ? -1 : (pointInScroll.x > groupScroll.bounds.width - 24 ? 1 : 0)
        if direction != 0 {
            groupScroll.contentView.scroll(to: NSPoint(x: min(max(visible.minX + direction * 12, 0), maxOffset), y: 0))
            groupScroll.reflectScrolledClipView(groupScroll.contentView)
        }
        groupStack.layoutSubtreeIfNeeded()
        let point = groupStack.convert(event.locationInWindow, from: nil)
        let slot = groupButtons.firstIndex { point.x < $0.frame.midX } ?? groupButtons.count
        groupDropSlot = slot
        let boundary = slot < groupButtons.count ? groupButtons[slot].frame.minX - 2 : groupStack.bounds.maxX - 3
        groupDropIndicator.frame = NSRect(x: max(0, boundary), y: 2, width: 2, height: 24)
        groupDropIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        groupDropIndicator.isHidden = false
    }

    private func finishGroupDrag(commit: Bool) {
        let source = draggedGroupID.flatMap { id in model.groups.firstIndex { $0.id == id } }
        let groupID = draggedGroupID
        let slot = groupDropSlot
        draggedGroupID = nil; groupDropSlot = nil; groupDropIndicator.isHidden = true
        updateActions()
        guard commit, let source, let groupID, let slot else { return }
        let destination = slot > source ? slot - 1 : slot
        if destination != source { model.moveGroup(id: groupID, offset: destination - source) }
    }
    private func updateToolbarPresentation() {
        let showSearch = isSearchPresentationVisible && groupJoinEntryID == nil && cardDragEntryID == nil
        let showCreation = groupCreationView != nil
        if let groupName = searchScopeGroupID.flatMap({ id in model.groups.first { $0.id == id }?.name }), showSearch {
            searchScopeChip.title = "\(groupName)  ×"
            searchScopeChip.toolTip = L("搜索范围：\(groupName)。移除后搜索完整历史")
            searchScopeChip.setAccessibilityLabel(L("搜索范围：\(groupName)。按下可移除范围并搜索完整历史"))
            searchScopeChip.isHidden = false
        } else {
            searchScopeChip.title = ""
            searchScopeChip.toolTip = nil
            searchScopeChip.setAccessibilityLabel(L("搜索范围：完整历史"))
            searchScopeChip.isHidden = true
        }
        searchBar.isHidden = showCreation
        idleToolbar.isHidden = showSearch || showCreation
        searchToolbar.isHidden = !showSearch && !showCreation
        hintIdleTrailing?.isActive = !showSearch && !showCreation
        hintSearchTrailing?.isActive = showSearch || showCreation
    }

    func showGroupEditor(groupID: String?) {
        guard isVisible else { return }
        if groupID == nil { beginGroupCreation(); return }
        closeGroupInteraction()
        let group = groupID.flatMap { id in model.groups.first { $0.id == id } }
        if groupID != nil, group == nil { return }
        focusLossGeneration += 1
        let editor = GroupEditorController(
            title: group == nil ? L("新建分组") : L("重命名分组"),
            actionTitle: group == nil ? L("新建") : L("保存"),
            value: group?.name ?? ""
        ) { [weak self] name in
            guard let self else { return L("面板已关闭") }
            guard !name.isEmpty, name.count <= 40 else { return L("请输入 1–40 个字符。") }
            let duplicate = self.model.groups.contains {
                $0.id != groupID && $0.name.compare(name, options: [.caseInsensitive, .literal]) == .orderedSame
            }
            guard !duplicate else { return L("已经有同名分组，请换一个名称。") }
            if let groupID { self.model.renameGroup(id: groupID, name: name) }
            else { self.model.createGroup(name: name) }
            return nil
        }
        editor.onClose = { [weak self, weak editor] in
            guard let self, self.groupEditor === editor else { return }
            self.closeGroupInteraction()
            self.restorePanelFocus()
        }
        groupEditor = editor
        if let groupID, let index = model.groups.firstIndex(where: { $0.id == groupID }) {
            editor.configureManagement(canMoveUp: index > 0, canMoveDown: index + 1 < model.groups.count)
            editor.onMove = { [weak self] offset in self?.model.moveGroup(id: groupID, offset: offset) }
            editor.onDelete = { [weak self] in self?.model.deleteGroup(id: groupID) }
        }
        embedGroupView(editor.view)
        editor.focus()
    }

    private func beginGroupCreation() {
        closeGroupInteraction()
        let creation = GroupCreationView()
        creation.onCancel = { [weak self] in
            self?.closeGroupInteraction()
            self?.restorePanelFocus()
        }
        creation.onSubmit = { [weak self, weak creation] name in
            guard let self, let creation, self.groupCreationView === creation else { return }
            guard !name.isEmpty, name.count <= 40 else {
                creation.showError(L("请输入 1–40 个字符。"))
                return
            }
            guard !self.model.groups.contains(where: {
                $0.name.compare(name, options: [.caseInsensitive, .literal]) == .orderedSame
            }) else {
                creation.showError(L("已经有同名分组。"))
                return
            }
            creation.isSubmitting = true
            self.model.createGroup(name: name) { [weak self, weak creation] result in
                guard let self, let creation, self.groupCreationView === creation else { return }
                switch result {
                case .success(let group): self.selectGroup(group.id)
                case .failure(let error):
                    creation.isSubmitting = false
                    creation.showError(error.localizedDescription)
                    creation.focus()
                }
            }
        }
        groupCreationView = creation
        searchToolbar.addArrangedSubview(creation)
        updateToolbarPresentation(); updateActions()
        creation.focus()
    }

    func handleGroupShortcut(_ event: NSEvent) -> Bool {
        guard !isGroupInteractionVisible, let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSTextView, editor.hasMarkedText() { return false }
        let acceptsShortcut = interactionMode == .cards ? responder === collection
            : responder === search || responder === search.currentEditor() || responder === searchScopeChip
        guard acceptsShortcut, let direction = groupShortcuts.direction(for: event) else { return false }
        cycleGroup(forward: direction == .next)
        return true
    }

    @objc private func appShortcutsChanged() {
        updateActions()
        searchButton.toolTip = L("搜索（\(appShortcuts.display(for: .beginSearch))）")
        for path in collection.indexPathsForVisibleItems() {
            (collection.item(at: path) as? CardItem)?.card.positionShortcut = AppShortcutAction.allCases.first { $0.position == path.item }.map { appShortcuts.display(for: $0) }
        }
    }

    private func handleAppShortcut(_ event: NSEvent) -> Bool {
        guard !isGroupInteractionVisible, let responder = window?.firstResponder else { return false }
        let isSearchResponder = responder === search || responder === search.currentEditor() || responder === searchScopeChip
        guard responder === collection || (interactionMode == .search && isSearchResponder) else { return false }
        let hasMarkedText = (responder as? NSTextView)?.hasMarkedText() == true
        guard let action = appShortcuts.action(for: event, context: interactionMode == .search ? .search : .cards, hasMarkedText: hasMarkedText) else { return false }
        switch action {
        case .beginSearch: beginSearch(selectAll: true)
        case .addToGroup: showGroupPicker()
        case .usePlainText: useSelectedAsPlainText()
        default: if canActOnSelectedEntry, let position = action.position { use(index: position) }
        }
        return true
    }

    private func handleGroupJoinKey(_ event: NSEvent) -> Bool {
        guard let entryID = groupJoinEntryID else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty || (event.keyCode == 48 && modifiers == .shift) else { return false }
        switch event.keyCode {
        case 53: closeGroupInteraction(); restorePanelFocus()
        case 36, 76, 49:
            if let target = groupJoinTargetID, model.groups.contains(where: { $0.id == target }),
               model.containsEntry(id: entryID), !model.groupIDs(for: entryID).contains(target) {
                model.add(entryID: entryID, toGroup: target)
            }
            closeGroupInteraction(); restorePanelFocus()
        case 123, 124, 48:
            guard !model.groups.isEmpty else { closeGroupInteraction(); restorePanelFocus(); return true }
            let current = model.groups.firstIndex { $0.id == groupJoinTargetID } ?? 0
            let delta = event.keyCode == 123 || modifiers == .shift ? -1 : 1
            groupJoinTargetID = model.groups[(current + delta + model.groups.count) % model.groups.count].id
            refreshGroupButtons(); updateActions()
        default: break
        }
        return true
    }

    func beginGroupRename(_ groupID: String) {
        guard isVisible, inlineGroupView == nil,
              let group = model.groups.first(where: { $0.id == groupID }) else { return }
        if selectedGroupID != groupID { selectGroup(groupID) }
        let editor = GroupLabelEditor(groupID: groupID, name: group.name)
        editor.onCancel = { [weak self] in self?.cancelGroupRename() }
        editor.onMove = { [weak self] offset in self?.model.moveGroup(id: groupID, offset: offset) }
        editor.onSubmit = { [weak self] name in
            guard let self else { return }
            guard !name.isEmpty, name.count <= 40 else {
                self.hint.stringValue = L("请输入 1–40 个字符。"); self.hint.textColor = .systemRed; return
            }
            guard !self.model.groups.contains(where: {
                $0.id != groupID && $0.name.compare(name, options: [.caseInsensitive, .literal]) == .orderedSame
            }) else {
                self.hint.stringValue = L("已经有同名分组，请换一个名称。"); self.hint.textColor = .systemRed; return
            }
            self.model.renameGroup(id: groupID, name: name)
            self.cancelGroupRename()
        }
        groupLabelEditor = editor
        refreshGroupButtons(); updateActions(); editor.focus()
        (editor.nameControl.currentEditor() as? NSTextView)?.selectAll(nil)
    }

    func cancelGroupRename() {
        groupLabelEditor = nil
        refreshGroupButtons(); updateActions(); focusCards()
    }

    @objc func requestSelectedGroupDeletion() {
        guard let selectedGroupID, !isGroupInteractionVisible else { return }
        showGroupEditor(groupID: selectedGroupID)
        groupEditor?.closeAfterCancelDelete = true
        groupEditor?.requestDelete()
        updateActions()
    }

    private func restorePanelFocus() {
        guard !closing, isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusForCurrentMode()
    }
}
