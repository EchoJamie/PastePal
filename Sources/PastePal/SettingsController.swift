import AppKit
import PastePalLocalization
import ClipboardCore
import ServiceManagement
import KeyboardShortcuts
import UniformTypeIdentifiers

private final class SettingsWindow: NSWindow {
    var onVisibilityChange: (() -> Void)?
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onVisibilityChange?()
    }
    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        onVisibilityChange?()
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        onVisibilityChange?()
    }
}

final class SettingsBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}

private final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsDetailScrollView: NSScrollView {
    var documentWidthConstraint: NSLayoutConstraint?
    override func tile() {
        super.tile()
        guard let documentWidthConstraint, documentWidthConstraint.constant != contentSize.width else { return }
        documentWidthConstraint.constant = contentSize.width
    }
}

private final class SettingsCategoryCell: NSTableCellView {
    let categoryIcon: NSImageView
    let categoryTitle: NSTextField

    init(symbol: String, title: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
        image.isTemplate = true
        categoryIcon = NSImageView(image: image)
        categoryTitle = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        imageView = categoryIcon; textField = categoryTitle
        [categoryIcon, categoryTitle].forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            categoryIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            categoryIcon.widthAnchor.constraint(equalToConstant: 18),
            categoryIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            categoryTitle.leadingAnchor.constraint(equalTo: categoryIcon.trailingAnchor, constant: 8),
            categoryTitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            categoryTitle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }
    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let color: NSColor = selected ? .selectedMenuItemTextColor : .secondaryLabelColor
        categoryIcon.contentTintColor = color
        categoryIcon.symbolConfiguration = NSImage.SymbolConfiguration(hierarchicalColor: color)
        categoryTitle.textColor = selected ? .selectedMenuItemTextColor : .labelColor
    }
}

final class SettingsController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let model: AppModel
    private let groupShortcuts: GroupShortcutStore
    private let appShortcuts: AppShortcutStore
    private let shortcutFeedback = NSTextField(wrappingLabelWithString: "")
    private let usageShortcuts = SettingsUsageView()
    private var localRecorders: [SettingsShortcutRecorder] = []
    private var acceptedGlobalShortcut: KeyboardShortcuts.Shortcut?
    private var acceptedCaptureShortcut: KeyboardShortcuts.Shortcut?
    private lazy var retentionControl = RetentionSettingsControl(
        readPolicy: { [model] in model.settings.retentionPolicy },
        savePolicy: { [model] policy, completion in model.setRetentionPolicy(policy, completion: completion) })
    private let sidebar = NSTableView()
    private let detailScroll = SettingsDetailScrollView()
    private let pageStack = NSStackView()
    private var pages: [NSStackView] = []
    private let categories = [L("常规"), L("快捷键"), L("历史与存储"), L("隐私与权限"), L("使用说明")]
    private let categorySymbols = ["gearshape", "keyboard", "clock", "hand.raised", "book"]
    private let appearancePicker = NSPopUpButton()
    private let languagePicker = NSPopUpButton()
    private let languageNotice = NSTextField(wrappingLabelWithString: "")
    private let screenshotEnabled = NSButton(checkboxWithTitle: L("启用区域截屏"), target: nil, action: nil)
    private var captureRecorder: KeyboardShortcuts.RecorderCocoa?
    private let paused = NSButton(checkboxWithTitle: L("暂停记录（重启后仍保持）"), target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: L("登录时启动"), target: nil, action: nil)
    private let permission = NSTextField(labelWithString: "")
    private let permissionGuide = NSTextField(wrappingLabelWithString: "")
    private let screenshotPermission = NSTextField(labelWithString: "")
    private let requestScreenPermission = NSButton(title: L("请求屏幕录制权限"), target: nil, action: nil)
    private let screenPermissionGuide = NSTextField(wrappingLabelWithString: "")
    private let screenPermissionCheck: () -> Bool
    private let screenPermissionRequest: () -> Bool
    private var didRequestScreenPermission = false
    private let screenshotFeedback = NSTextField(wrappingLabelWithString: "")
    private let recording = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private var timer: Timer?
    var hasRefreshTimer: Bool { timer != nil }
    private(set) var isPresented = false
    var onPresentationChange: ((Bool) -> Void)?
    init(model: AppModel,
         screenPermissionCheck: @escaping () -> Bool = { ScreenshotPermission.isGranted },
         screenPermissionRequest: @escaping () -> Bool = { ScreenshotPermission.request() }) {
        self.model = model
        self.screenPermissionCheck = screenPermissionCheck
        self.screenPermissionRequest = screenPermissionRequest
        groupShortcuts = GroupShortcutStore(defaults: model.settings.defaults)
        appShortcuts = AppShortcutStore(defaults: model.settings.defaults)
        acceptedGlobalShortcut = KeyboardShortcuts.getShortcut(for: .showHistory)
        acceptedCaptureShortcut = KeyboardShortcuts.getShortcut(for: .captureRegion)
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("\(AppIdentity.displayName) · 设置"); window.isReleasedWhenClosed = false
        window.contentView = SettingsBackground(frame: window.contentView!.bounds)
        super.init(window: window)
        window.delegate = self
        window.onVisibilityChange = { [weak self] in self?.startRefreshTimer() }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationVisibilityDidChange), name: NSApplication.didHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationVisibilityDidChange), name: NSApplication.didUnhideNotification, object: nil)
        window.contentMinSize = NSSize(width: 720, height: 360)
        buildUI(); window.setContentSize(NSSize(width: 920, height: 600)); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func showWindow(_ sender: Any?) {
        if !isPresented { refresh(); loadRetentionDraft() }
        setPresented(true)
        NSApp.activate(ignoringOtherApps: true); super.showWindow(sender); window?.makeKeyAndOrderFront(nil)
        if let screen = window?.screen, let window {
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
        startRefreshTimer()
    }
    func showScreenshotError(_ message: String) {
        showWindow(nil)
        sidebar.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        screenshotFeedback.stringValue = L("上次截屏未完成：\(message)")
    }
    func showAccessibilityGuidance() {
        showWindow(nil)
        sidebar.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
    }
    func hide() {
        setPresented(false)
        stopRefreshTimer()
        localRecorders.forEach { $0.cancelRecording() }
        window?.orderOut(nil)
    }
    deinit {
        if isPresented { onPresentationChange?(false) }
        stopRefreshTimer()
        NotificationCenter.default.removeObserver(self)
    }
    func windowWillClose(_ notification: Notification) {
        setPresented(false)
        stopRefreshTimer()
        localRecorders.forEach { $0.cancelRecording() }
    }
    func windowDidResignKey(_ notification: Notification) {
        localRecorders.forEach { $0.cancelRecording() }
    }
    private func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
        onPresentationChange?(presented)
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { startRefreshTimer() }
    func windowDidBecomeKey(_ notification: Notification) { startRefreshTimer() }
    @objc private func applicationVisibilityDidChange(_ notification: Notification) {
        if notification.name == NSApplication.didHideNotification { stopRefreshTimer() }
        else { startRefreshTimer() }
    }
    private var needsPeriodicRefresh: Bool {
        window?.isVisible == true && window?.isMiniaturized == false && !NSApp.isHidden && [0, 3].contains(sidebar.selectedRow)
    }
    private func stopRefreshTimer() {
        timer?.invalidate()
        timer = nil
    }
    private func startRefreshTimer() {
        guard needsPeriodicRefresh else { stopRefreshTimer(); return }
        guard timer == nil else { return }
        refreshCurrentDynamicPage()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.needsPeriodicRefresh else { self.stopRefreshTimer(); return }
            self.refreshCurrentDynamicPage()
        }
    }
    private func refreshCurrentDynamicPage() {
        switch sidebar.selectedRow {
        case 0: refreshGeneralStatus()
        case 3: refreshPermissionStatus()
        default: break
        }
    }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let sidebarBackground = NSVisualEffectView()
        sidebarBackground.material = .sidebar; sidebarBackground.blendingMode = .behindWindow
        let navigation = NSScrollView()
        navigation.drawsBackground = false; navigation.documentView = sidebar
        let column = NSTableColumn(identifier: .init("category"))
        sidebar.addTableColumn(column); sidebar.headerView = nil
        sidebar.rowHeight = 38; sidebar.style = .sourceList
        sidebar.backgroundColor = .clear; sidebar.allowsEmptySelection = false
        sidebar.delegate = self; sidebar.dataSource = self
        sidebar.setAccessibilityLabel(L("设置分类"))
        sidebarBackground.addSubview(navigation)
        let separator = NSBox(); separator.boxType = .separator
        [sidebarBackground, separator, detailScroll].forEach {
            content.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false
        }
        navigation.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.drawsBackground = false; detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true; detailScroll.hasHorizontalScroller = false
        let document = SettingsDocument()
        detailScroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        pageStack.orientation = .vertical; pageStack.alignment = .leading
        document.addSubview(pageStack); pageStack.translatesAutoresizingMaskIntoConstraints = false
        // 文档跟随视口宽度，避免内容的 fitting size 反向改变窗口。
        let documentWidth = document.widthAnchor.constraint(equalToConstant: max(1, content.bounds.width - 175))
        detailScroll.documentWidthConstraint = documentWidth
        NSLayoutConstraint.activate([
            sidebarBackground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarBackground.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarBackground.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarBackground.widthAnchor.constraint(equalToConstant: 174),
            navigation.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor, constant: 8),
            navigation.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor, constant: -8),
            navigation.topAnchor.constraint(equalTo: sidebarBackground.topAnchor, constant: 16),
            navigation.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.topAnchor.constraint(equalTo: content.topAnchor),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: content.topAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            documentWidth,
            document.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            pageStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            pageStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            pageStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            pageStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        let general = page(L("常规"), L("管理外观、语言、启动和剪贴板记录行为。"))
        appearancePicker.addItems(withTitles: AppAppearanceMode.allCases.map(\.title))
        appearancePicker.selectItem(at: AppAppearanceMode.allCases.firstIndex(of: model.settings.appearanceMode)!)
        appearancePicker.target = self; appearancePicker.action = #selector(changeAppearance)
        appearancePicker.setAccessibilityLabel(L("外观模式"))
        append(settingRow(L("外观"), appearancePicker), to: general)
        languagePicker.addItems(withTitles: AppLanguage.allCases.map(\.title))
        languagePicker.selectItem(at: AppLanguage.allCases.firstIndex(of: model.settings.language)!)
        languagePicker.target = self; languagePicker.action = #selector(changeLanguage)
        languagePicker.setAccessibilityLabel(L("应用语言"))
        append(settingRow(L("语言"), languagePicker), to: general)
        languageNotice.font = .systemFont(ofSize: 11); languageNotice.textColor = .secondaryLabelColor
        languageNotice.stringValue = L("重新打开应用后，语言设置生效。")
        append(settingRow("", languageNotice), to: general)
        section(L("启动与记录"), in: general)
        login.target = self; login.action = #selector(toggleLogin)
        append(settingRow(L("启动"), login), to: general)
        paused.title = L("暂停记录"); paused.toolTip = L("重启后仍保持暂停状态")
        paused.target = self; paused.action = #selector(togglePause)
        append(settingRow(L("剪贴板记录"), paused), to: general)
        recording.font = .systemFont(ofSize: 11); recording.textColor = .secondaryLabelColor
        recording.lineBreakMode = .byWordWrapping; recording.maximumNumberOfLines = 0
        append(settingRow("", recording), to: general)
        append(settingRow(L("使用内容"), note(L("确认使用后直接粘贴到原窗口。需要辅助功能权限，可在“隐私与权限”中管理；首次使用前需授予辅助功能权限。授权后若无法恢复输入位置，会提示手动按 ⌘V。"))), to: general)

        section(L("可选功能"), in: general)
        screenshotEnabled.target = self; screenshotEnabled.action = #selector(toggleScreenshot)
        append(settingRow(L("区域截屏"), screenshotEnabled), to: general)
        append(settingRow("", note(L("关闭时停用截屏快捷键，不占用其他应用按键，也不影响剪贴板。仅启用后主动请求权限或截屏时，才请求屏幕录制权限。"))), to: general)

        let shortcuts = page(L("快捷键"), L("配置应用功能组合键。固定按键和按场景操作方法请查看“使用说明”。"))
        section(L("可配置 · 全局操作"), in: shortcuts)
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .showHistory) { [weak self] shortcut in
            guard let self else { return }
            if let conflict = self.globalShortcutConflict(shortcut, other: .captureRegion, otherTitle: L("区域截屏")) {
                KeyboardShortcuts.setShortcut(self.acceptedGlobalShortcut, for: .showHistory)
                self.shortcutFeedback.stringValue = conflict
            } else {
                self.acceptedGlobalShortcut = shortcut
                self.shortcutFeedback.stringValue = ""
            }
        }
        recorder.setAccessibilityLabel(L("呼出历史快捷键"))
        let resetHistory = SettingsShortcutResetButton(label: L("呼出历史")) { [weak self] in self?.restoreGlobalShortcut(.showHistory) }
        append(settingRow(L("呼出历史"), row([recorder, resetHistory])), to: shortcuts)
        append(settingRow("", note(L("全局生效，在其他应用中也可呼出历史。"))), to: shortcuts)
        let captureRecorder = KeyboardShortcuts.RecorderCocoa(for: .captureRegion) { [weak self] shortcut in
            guard let self else { return }
            if let conflict = self.globalShortcutConflict(shortcut, other: .showHistory, otherTitle: L("呼出历史")) {
                KeyboardShortcuts.setShortcut(self.acceptedCaptureShortcut, for: .captureRegion)
                self.shortcutFeedback.stringValue = conflict
            } else {
                self.acceptedCaptureShortcut = shortcut
                self.shortcutFeedback.stringValue = ""
            }
            ScreenshotShortcutPolicy.apply(enabled: self.model.settings.screenshotEnabled)
        }
        self.captureRecorder = captureRecorder
        captureRecorder.isEnabled = model.settings.screenshotEnabled
        captureRecorder.setAccessibilityLabel(L("区域截屏快捷键"))
        let resetCapture = SettingsShortcutResetButton(label: L("区域截屏")) { [weak self] in self?.restoreGlobalShortcut(.captureRegion) }
        append(settingRow(L("区域截屏"), row([captureRecorder, resetCapture])), to: shortcuts)
        append(settingRow("", note(L("在“常规”中启用后全局生效，默认 ⌘⇧A。关闭时不占用快捷键；权限状态见“隐私与权限”。"))), to: shortcuts)
        buildFunctionShortcuts(in: shortcuts)
        shortcutFeedback.font = .systemFont(ofSize: 11)
        shortcutFeedback.textColor = .secondaryLabelColor
        shortcutFeedback.setAccessibilityLabel(L("快捷键设置状态"))
        append(settingRow("", shortcutFeedback), to: shortcuts)

        let history = page(L("历史与存储"), L("管理未分组历史的保留方式和本机数据。"))
        append(settingRow(L("保留最近"), retentionControl), to: history)
        append(settingRow("", note(L("自动清理超出保留范围的未分组旧记录，分组内容长期保留。时间从最后复制或确认使用起计算。"))), to: history)
        section(L("本机存储"), in: history)
        let dataFolder = NSButton(title: L("打开数据目录"), target: self, action: #selector(openData))
        dataFolder.bezelStyle = .rounded
        append(settingRow(L("数据目录"), dataFolder), to: history)
        append(settingRow("", note(L("历史仅保存在此 Mac。"))), to: history)
        section(L("清理历史"), in: history)
        let clear = NSButton(title: L("清空未分组历史…"), target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded; clear.contentTintColor = .systemRed
        append(settingRow(L("历史清理"), clear), to: history)
        append(settingRow("", note(L("分组内容会保留。删除前会再次确认。"))), to: history)

        let privacy = page(L("隐私与权限"), L("管理辅助功能、屏幕录制权限和不记录的应用。"))
        permission.font = .systemFont(ofSize: 11); permission.textColor = .secondaryLabelColor
        permissionGuide.font = .systemFont(ofSize: 12)
        permissionGuide.setAccessibilityLabel(L("辅助功能使用前置条件"))
        append(permissionGuide, to: privacy)
        append(settingRow(L("辅助功能"), permission), to: privacy)
        let permissions = NSButton(title: L("打开辅助功能设置"), target: self, action: #selector(openPermissions))
        permissions.bezelStyle = .rounded
        append(settingRow("", permissions), to: privacy)
        section(L("区域截屏权限"), in: privacy)
        screenshotFeedback.font = .systemFont(ofSize: 12)
        screenshotFeedback.textColor = .systemRed
        screenshotFeedback.setAccessibilityLabel(L("最近一次截屏错误"))
        append(screenshotFeedback, to: privacy)
        screenshotPermission.font = .systemFont(ofSize: 11)
        screenshotPermission.textColor = .secondaryLabelColor
        screenshotPermission.setAccessibilityLabel(L("屏幕录制权限状态"))
        append(settingRow(L("屏幕录制"), screenshotPermission), to: privacy)
        requestScreenPermission.target = self; requestScreenPermission.action = #selector(requestScreenshotPermissions)
        requestScreenPermission.bezelStyle = .rounded
        requestScreenPermission.setAccessibilityLabel(L("请求屏幕录制权限"))
        append(settingRow("", requestScreenPermission), to: privacy)
        let screenSettings = NSButton(title: L("打开屏幕录制设置"), target: self, action: #selector(openScreenshotPermissions))
        screenSettings.bezelStyle = .rounded
        append(settingRow("", screenSettings), to: privacy)
        screenPermissionGuide.font = .systemFont(ofSize: 11)
        screenPermissionGuide.textColor = .secondaryLabelColor
        screenPermissionGuide.setAccessibilityLabel(L("屏幕录制授权说明"))
        append(settingRow("", screenPermissionGuide), to: privacy)
        refreshScreenPermission()
        section(L("不记录的应用"), in: privacy)
        let appColumn = NSTableColumn(identifier: .init("app")); appColumn.width = 360
        table.addTableColumn(appColumn); table.headerView = nil; table.rowHeight = 28
        table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = false
        table.setAccessibilityLabel(L("不记录的应用"))
        let excluded = NSScrollView(); excluded.documentView = table; excluded.hasVerticalScroller = true
        excluded.autohidesScrollers = true; excluded.borderType = .bezelBorder
        excluded.heightAnchor.constraint(equalToConstant: 140).isActive = true
        append(excluded, to: privacy)
        let add = NSButton(title: L("添加应用…"), target: self, action: #selector(addExcluded))
        let remove = NSButton(title: L("移除所选"), target: self, action: #selector(removeExcluded))
        add.bezelStyle = .rounded; remove.bezelStyle = .rounded
        append(row([add, remove]), to: privacy)
        let usage = page(L("使用说明"), L("常用快捷键一览，显示当前配置。"))
        append(usageShortcuts, to: usage)
        loadRetentionDraft()
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showCategory(0)
    }
    private func page(_ title: String, _ description: String) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 23, weight: .semibold)
        append(heading, to: stack); append(note(description), to: stack)
        pages.append(stack)
        return stack
    }
    private func append(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func section(_ title: String, in stack: NSStackView) {
        let divider = NSBox(); divider.boxType = .separator; append(divider, to: stack)
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        append(heading, to: stack)
    }
    private func showCategory(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        localRecorders.forEach { $0.cancelRecording() }
        for view in pageStack.arrangedSubviews { pageStack.removeArrangedSubview(view); view.removeFromSuperview() }
        append(pages[index], to: pageStack)
        detailScroll.contentView.scroll(to: .zero); detailScroll.reflectScrolledClipView(detailScroll.contentView)
        window?.recalculateKeyViewLoop()
        refresh()
        startRefreshTimer()
    }
    private func buildFunctionShortcuts(in stack: NSStackView) {
        section(L("可配置 · 应用功能组合键"), in: stack)
        append(note(L("搜索在卡片和搜索框中生效；其余绑定仅在卡片区域生效，不替换文本编辑和输入法按键。")), to: stack)
        for action in AppShortcutAction.allCases {
            let recorder = SettingsShortcutRecorder(label: action.title, shortcut: appShortcuts.shortcut(for: action), save: { [weak self] shortcut in
                self?.appShortcuts.setShortcut(shortcut, for: action)
            }, feedback: { [weak self] message in self?.shortcutFeedback.stringValue = message })
            localRecorders.append(recorder)
            let reset = SettingsShortcutResetButton(label: action.title) { [weak self, weak recorder] in
                guard let self else { return }
                if let error = self.appShortcuts.restoreDefault(for: action) { self.shortcutFeedback.stringValue = error }
                else { recorder?.reloadShortcut(self.appShortcuts.shortcut(for: action)); self.shortcutFeedback.stringValue = L("已恢复默认快捷键。") }
            }
            append(settingRow(action.title, row([recorder, reset])), to: stack)
        }
    }
    private func restoreGlobalShortcut(_ name: KeyboardShortcuts.Name) {
        let other: KeyboardShortcuts.Name = name == .showHistory ? .captureRegion : .showHistory
        let otherTitle = name == .showHistory ? L("区域截屏") : L("呼出历史")
        if let error = globalShortcutConflict(name.defaultShortcut, other: other, otherTitle: otherTitle) {
            shortcutFeedback.stringValue = error; return
        }
        KeyboardShortcuts.setShortcut(name.defaultShortcut, for: name)
        if name == .showHistory { acceptedGlobalShortcut = name.defaultShortcut }
        else { acceptedCaptureShortcut = name.defaultShortcut }
        ScreenshotShortcutPolicy.apply(enabled: model.settings.screenshotEnabled)
        shortcutFeedback.stringValue = L("已恢复默认快捷键。")
    }
    private func globalShortcutConflict(_ shortcut: KeyboardShortcuts.Shortcut?, other: KeyboardShortcuts.Name, otherTitle: String) -> String? {
        guard let shortcut else { return nil }
        let modifiers = shortcut.modifiers.intersection([.command, .control, .option, .shift])
        if modifiers.contains(.command), [0, 6, 7, 8, 9, 12, 43].contains(shortcut.carbonKeyCode) {
            // 全局呼出历史默认 ⌘⇧V 是独立功能组合，保留兼容。
            if shortcut != KeyboardShortcuts.Name.showHistory.defaultShortcut && shortcut != ScreenshotShortcutPolicy.defaultShortcut {
                return L("此组合保留给文本编辑、设置或退出。")
            }
        }
        if shortcut == KeyboardShortcuts.getShortcut(for: other) {
            return L("不能与全局“\(otherTitle)”快捷键相同。")
        }
        return appShortcuts.globalShortcutConflict(shortcut) ?? groupShortcuts.globalShortcutConflict(shortcut)
    }
    private func loadRetentionDraft() {
        retentionControl.reload()
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }
    private func settingRow(_ title: String, _ control: NSView) -> NSView {
        let line = NSView()
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        [label, control].forEach { line.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: 88),
            label.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 14),
            control.topAnchor.constraint(equalTo: line.topAnchor),
            control.bottomAnchor.constraint(equalTo: line.bottomAnchor),
            control.trailingAnchor.constraint(lessThanOrEqualTo: line.trailingAnchor),
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
        if control is NSScrollView || control is NSTextField {
            control.trailingAnchor.constraint(equalTo: line.trailingAnchor).isActive = true
        }
        return line
    }
    private func note(_ value: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor
        return field
    }
    private func refresh() {
        if sidebar.selectedRow == 4 { usageShortcuts.refresh(shortcuts: appShortcuts, screenshotEnabled: model.settings.screenshotEnabled) }
        refreshGeneralStatus()
        refreshPermissionStatus()
        let selected = table.selectedRow
        table.reloadData()
        if model.settings.excludedApps.indices.contains(selected) {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
    }
    private func refreshGeneralStatus() {
        paused.state = model.settings.paused ? .on : .off
        screenshotEnabled.state = model.settings.screenshotEnabled ? .on : .off
        captureRecorder?.isEnabled = model.settings.screenshotEnabled
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        recording.stringValue = model.status ?? (model.settings.paused ? L("记录已暂停，普通复制粘贴不受影响。") : L("正在记录后续复制的常见文字、图片与文件。"))
        recording.toolTip = recording.stringValue
    }
    private func refreshPermissionStatus() {
        permission.stringValue = model.paste.trusted ? L("辅助功能已授权，可以使用") : L("未授权：请先开启辅助功能权限")
        permissionGuide.stringValue = model.paste.trusted
            ? L("辅助功能权限已就绪。可从状态栏或快捷键打开历史，确认使用后直接粘贴。")
            : L("使用贴伴需要辅助功能权限。请点击下方按钮，在系统设置中开启贴伴；授权前不会进入历史使用流程。授权后自动重新检查，设置和退出仍可使用。")
        refreshScreenPermission()
    }
    private func refreshScreenPermission() {
        let captureEnabled = model.settings.screenshotEnabled
        let screenGranted = captureEnabled && screenPermissionCheck()
        screenshotPermission.stringValue = !captureEnabled ? L("区域截屏未启用")
            : (screenGranted ? L("屏幕录制已授权") : L("未授权，仅区域截屏不可用"))
        requestScreenPermission.isEnabled = captureEnabled && !screenGranted && !didRequestScreenPermission
        if !captureEnabled {
            screenPermissionGuide.stringValue = L("请先在“常规”中启用区域截屏，再主动请求权限。关闭时不会发起权限请求，剪贴板不受影响。")
        } else if screenGranted {
            screenPermissionGuide.stringValue = L("屏幕录制权限已就绪。区域截屏不采集音频；也可在系统设置中管理权限。")
        } else if didRequestScreenPermission {
            screenPermissionGuide.stringValue = L("已向系统请求权限。若尚未允许，请打开屏幕录制设置为贴伴开启权限；本窗口不会重复请求。此次操作不会截屏或写入剪贴板。")
        } else {
            screenPermissionGuide.stringValue = L("点击“请求屏幕录制权限”向系统发起授权，使贴伴可出现在权限列表中；之后可打开系统设置管理。此操作不会截屏、采集音频或写入剪贴板。")
        }
    }
    @objc private func toggleScreenshot() {
        model.settings.screenshotEnabled = screenshotEnabled.state == .on
        ScreenshotShortcutPolicy.apply(enabled: model.settings.screenshotEnabled)
        refresh()
    }
    @objc private func togglePause() { model.setPaused(paused.state == .on); refresh() }
    @objc private func openPermissions() { model.paste.requestAccessibilitySettings() }
    @objc private func requestScreenshotPermissions() {
        guard model.settings.screenshotEnabled, !screenPermissionCheck(), !didRequestScreenPermission else { return }
        didRequestScreenPermission = true
        requestScreenPermission.isEnabled = false
        _ = screenPermissionRequest()
        refresh()
    }
    @objc private func openScreenshotPermissions() { ScreenshotPermission.openSystemSettings() }
    @objc private func changeAppearance() {
        guard AppAppearanceMode.allCases.indices.contains(appearancePicker.indexOfSelectedItem) else { return }
        model.settings.appearanceMode = AppAppearanceMode.allCases[appearancePicker.indexOfSelectedItem]
        model.settings.appearanceMode.apply()
    }
    @objc private func changeLanguage() {
        guard AppLanguage.allCases.indices.contains(languagePicker.indexOfSelectedItem) else { return }
        model.settings.language = AppLanguage.allCases[languagePicker.indexOfSelectedItem]
    }
    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { alert(L("登录项等待系统批准，请在系统设置 → 通用 → 登录项中开启。")) }
        } catch { alert(L("登录启动设置未成功：\(error.localizedDescription)")) }
        refresh()
    }
    @objc private func addExcluded() {
        let picker = NSOpenPanel(); picker.title = L("选择不记录的应用"); picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications"); picker.allowsMultipleSelection = true; picker.canChooseDirectories = false
        guard picker.runModal() == .OK else { return }
        var ids = Set(model.settings.excludedApps)
        for url in picker.urls { if let id = Bundle(url: url)?.bundleIdentifier { ids.insert(id) } }
        model.settings.excludedApps = Array(ids); model.monitor.resetBaseline(); refresh()
    }
    @objc private func removeExcluded() {
        let ids = model.settings.excludedApps
        guard ids.indices.contains(table.selectedRow) else { return }
        model.settings.excludedApps = ids.enumerated().filter { $0.offset != table.selectedRow }.map(\.element)
        model.monitor.resetBaseline(); refresh()
    }
    @objc private func clearHistory() {
        let prompt = NSAlert(); prompt.messageText = L("清空未分组历史？")
        prompt.informativeText = L("将删除全部未分组历史及其图片。分组中的长期保留内容和系统当前剪贴板不受影响，此操作无法撤销。")
        prompt.addButton(withTitle: L("清空未分组历史")); prompt.addButton(withTitle: L("取消"))
        if prompt.runModal() == .alertFirstButtonReturn { model.clear() }
    }
    @objc private func openData() { NSWorkspace.shared.open(model.store.directory) }
    private func alert(_ message: String) { let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: L("好")); alert.runModal() }
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebar ? categories.count : model.settings.excludedApps.count
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let selected = notification.object as? NSTableView, selected === sidebar else { return }
        showCategory(sidebar.selectedRow)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebar {
            return SettingsCategoryCell(symbol: categorySymbols[row], title: categories[row])
        }
        let id = model.settings.excludedApps[row]
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
        let field = NSTextField(labelWithString: "\(name)  ·  \(id)"); field.font = .systemFont(ofSize: 12); return field
    }
}
