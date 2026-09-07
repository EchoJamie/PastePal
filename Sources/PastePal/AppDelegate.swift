import PastePalLocalization
import AppKit
import KeyboardShortcuts
import ClipboardCore
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel?
    private var accessibilityGate: AccessibilityGate?
    private var accessibilityTimer: Timer?
    private var panel: PanelController?
    private var screenshot: ScreenshotController?
    private var settingsWindow: SettingsController?
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var captureMenuItem: NSMenuItem?
    private var captureWindowMenuItem: NSMenuItem?
    private var mainCaptureMenuItem: NSMenuItem?
    private var mainCaptureWindowMenuItem: NSMenuItem?
    private var plainTextSelectionMenuItem: NSMenuItem?
    private var deleteSelectionMenuItem: NSMenuItem?
    private var permanentDeleteSelectionMenuItem: NSMenuItem?
    private var addSelectionToGroupMenuItem: NSMenuItem?
    private var manageGroupsMenuItem: NSMenuItem?
    private var lockFile: Int32 = -1
    private var quitting = false
    private var readyToQuit = false
    private let smoke = ProcessInfo.processInfo.arguments.contains("--smoke-test")
    private var smokeDriver: SmokeDriver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        do {
            let directory: URL
            let settings: SettingsStore
            if smoke {
                directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PASTEPAL_SMOKE_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("PastePalSmoke", isDirectory: true)
                let defaults = UserDefaults(suiteName: "local.pastepal.smoke")!
                defaults.removePersistentDomain(forName: "local.pastepal.smoke")
                settings = SettingsStore(defaults: defaults); settings.welcomed = true
            } else {
                directory = AppStorageMigration.liveDataDirectory
                settings = SettingsStore()
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lockFile = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFile >= 0, flock(lockFile, LOCK_EX | LOCK_NB) == 0 else {
                DistributedNotificationCenter.default().post(name: .init("local.pastepal.show"), object: nil)
                NSApp.terminate(nil); return
            }
            if !smoke { settings.appearanceMode.apply() }
            let model = try AppModel(directory: directory, settings: settings)
            self.model = model
            panel = PanelController(model: model)
            screenshot = ScreenshotController(monitor: model.monitor)
            screenshot?.beforeCapture = { [weak self] in self?.panel?.dismiss(); self?.settingsWindow?.hide() }
            screenshot?.onError = { [weak self] message in
                guard let self, let model = self.model else { return }
                self.panel?.dismiss()
                self.settingsController(for: model).showScreenshotError(message)
            }
            ScreenshotShortcutPolicy.migrateIfNeeded(defaults: settings.defaults)
            installStatusMenu()
            KeyboardShortcuts.onKeyUp(for: .captureRegion) { [weak self] in self?.captureRegion() }
            NotificationCenter.default.addObserver(self, selector: #selector(syncScreenshotShortcut), name: .screenshotSettingsDidChange, object: nil)
            syncScreenshotShortcut()
            KeyboardShortcuts.onKeyUp(for: .showHistory) { [weak self] in self?.panel?.toggle() }
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(showHistory), name: .init("local.pastepal.show"), object: nil)
            if smoke {
                smokeDriver = SmokeDriver(model: model, panel: panel!, statusItem: statusItem)
                smokeDriver?.run()
            } else {
                configureAccessibilityGate(model: model)
                if accessibilityGate?.check(presentIfDenied: true) == true, !settings.welcomed { showSettings() }
                settings.welcomed = true
            }
        } catch {
            let alert = NSAlert(); alert.messageText = L("\(AppIdentity.displayName) 未能启动"); alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("退出")); alert.runModal(); NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !readyToQuit else { return .terminateNow }
        if !quitting {
            quitting = true
            // 先让事件循环返回，再完成已接收的历史操作。
            model.prepareToQuit { [weak self] in self?.readyToQuit = true; sender.terminate(nil) }
        }
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { accessibilityTimer?.invalidate(); screenshot?.cancel(); model?.monitor.stop(); if lockFile >= 0 { close(lockFile) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let settingsWindow, settingsWindow.isPresented {
            panel?.dismiss()
            sender.unhide(nil)
            settingsWindow.showWindow(nil)
        } else {
            panel?.show()
        }
        return true
    }
    func installMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem(title: AppIdentity.displayName, action: nil, keyEquivalent: ""); let appMenu = NSMenu(title: AppIdentity.displayName)
        let settings = appMenu.addItem(withTitle: L("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("退出 \(AppIdentity.displayName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        app.submenu = appMenu; main.addItem(app)
        let edit = NSMenuItem(title: L("编辑"), action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: L("编辑"))
        for (title, action, key) in [(L("撤销"), #selector(UndoManager.undo), "z"), (L("剪切"), #selector(NSText.cut(_:)), "x"), (L("复制"), #selector(NSText.copy(_:)), "c"), (L("粘贴"), #selector(NSText.paste(_:)), "v"), (L("全选"), #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        edit.submenu = editMenu; main.addItem(edit)
        let capture = NSMenuItem(title: L("截屏"), action: nil, keyEquivalent: "")
        let captureMenu = NSMenu(title: L("截屏")); captureMenu.autoenablesItems = false
        let region = captureMenu.addItem(withTitle: L("区域截屏"), action: #selector(captureRegion), keyEquivalent: "")
        region.target = self; region.isEnabled = model?.settings.screenshotEnabled == true
        MainActor.assumeIsolated { region.setShortcut(for: .captureRegion) }
        mainCaptureMenuItem = region
        let window = captureMenu.addItem(withTitle: L("截取窗口"), action: #selector(captureWindow), keyEquivalent: "")
        window.target = self; window.isEnabled = region.isEnabled
        mainCaptureWindowMenuItem = window
        capture.submenu = captureMenu; main.addItem(capture)
        NSApp.mainMenu = main
    }
    private func installStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = StatusIcon.make()
        statusItem?.button?.toolTip = AppIdentity.displayName
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        let open = NSMenuItem(title: L("打开历史"), action: #selector(showHistory), keyEquivalent: ""); open.target = self
        MainActor.assumeIsolated { open.setShortcut(for: .showHistory) }; menu.addItem(open)
        let capture = NSMenuItem(title: L("区域截屏"), action: #selector(captureRegion), keyEquivalent: "")
        capture.target = self; captureMenuItem = capture
        MainActor.assumeIsolated { capture.setShortcut(for: .captureRegion) }; menu.addItem(capture)
        let windowCapture = NSMenuItem(title: L("截取窗口"), action: #selector(captureWindow), keyEquivalent: "")
        windowCapture.target = self; captureWindowMenuItem = windowCapture; menu.addItem(windowCapture)
        menu.addItem(.separator())
        let plain = NSMenuItem(title: L("纯文本使用所选"), action: #selector(useSelectedAsPlainText), keyEquivalent: "")
        plain.target = self; plain.isEnabled = false; plainTextSelectionMenuItem = plain; menu.addItem(plain)
        let addToGroup = NSMenuItem(title: L("将所选加入分组…"), action: #selector(addSelectedToGroup), keyEquivalent: "")
        addToGroup.target = self; addToGroup.isEnabled = false
        addSelectionToGroupMenuItem = addToGroup; menu.addItem(addToGroup)
        let delete = NSMenuItem(title: L("永久删除所选（Delete）"), action: #selector(deleteSelected), keyEquivalent: "")
        delete.target = self; delete.isEnabled = false; deleteSelectionMenuItem = delete; menu.addItem(delete)
        let permanentDelete = NSMenuItem(title: L("永久删除所选…"), action: #selector(permanentlyDeleteSelected), keyEquivalent: "")
        permanentDelete.target = self; permanentDelete.isEnabled = false; permanentDelete.isHidden = true
        permanentDeleteSelectionMenuItem = permanentDelete; menu.addItem(permanentDelete)
        menu.addItem(.separator())
        let newGroup = NSMenuItem(title: L("新建分组…"), action: #selector(createGroup), keyEquivalent: "")
        newGroup.target = self; menu.addItem(newGroup)
        let manageGroups = NSMenuItem(title: L("管理分组"), action: #selector(manageGroups), keyEquivalent: "")
        manageGroups.target = self; manageGroupsMenuItem = manageGroups; menu.addItem(manageGroups)
        menu.addItem(.separator())
        let pause = NSMenuItem(title: L("暂停记录"), action: #selector(togglePause), keyEquivalent: ""); pause.target = self
        pauseMenuItem = pause; menu.addItem(pause)
        let settings = NSMenuItem(title: L("设置…"), action: #selector(showSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        menu.addItem(.separator()); menu.addItem(withTitle: L("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        if let model { MainActor.assumeIsolated { refreshStatusShortcuts(in: menu, store: AppShortcutStore(defaults: model.settings.defaults)) } }
        statusItem?.menu = menu
    }
    @MainActor func refreshStatusShortcuts(in menu: NSMenu, store: AppShortcutStore) {
        for item in menu.items {
            if item.action == #selector(useSelectedAsPlainText) { item.setShortcut(store.shortcut(for: .usePlainText)) }
            else if item.action == #selector(addSelectedToGroup) { item.setShortcut(store.shortcut(for: .addToGroup)) }
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        if let model { MainActor.assumeIsolated { refreshStatusShortcuts(in: menu, store: AppShortcutStore(defaults: model.settings.defaults)) } }
        panel?.statusMenuWillOpen()
        pauseMenuItem?.title = model?.settings.paused == true ? L("恢复记录") : L("暂停记录")
        plainTextSelectionMenuItem?.isEnabled = panel?.canUseSelectedEntryAsPlainText == true
        addSelectionToGroupMenuItem?.isEnabled = panel?.canAddSelectedEntryToGroup == true
        deleteSelectionMenuItem?.title = panel?.contextualDeleteTitle ?? L("永久删除所选（Delete）")
        deleteSelectionMenuItem?.isEnabled = panel?.canActOnSelectedEntry == true
        permanentDeleteSelectionMenuItem?.isHidden = panel?.selectedGroupID == nil
        permanentDeleteSelectionMenuItem?.isEnabled = panel?.canActOnSelectedEntry == true
    }
    func menuDidClose(_ menu: NSMenu) { panel?.statusMenuDidClose() }
    @objc private func captureRegion() { guard model?.settings.screenshotEnabled == true, ensureAccessibility() else { return }; MainActor.assumeIsolated { screenshot?.start() } }
    @objc private func captureWindow() { guard model?.settings.screenshotEnabled == true, ensureAccessibility() else { return }; MainActor.assumeIsolated { screenshot?.start(mode: .window) } }
    @objc private func showHistory() { if panel?.isVisible != true { panel?.show() } }
    @objc private func useSelectedAsPlainText() { guard ensureAccessibility() else { return }; panel?.useSelectedAsPlainText() }
    @objc private func addSelectedToGroup() { guard ensureAccessibility() else { return }; panel?.showGroupPicker() }
    @objc private func deleteSelected() { guard ensureAccessibility() else { return }; panel?.deleteSelected() }
    @objc private func permanentlyDeleteSelected() { guard ensureAccessibility() else { return }; panel?.permanentlyDeleteSelected() }
    @objc private func createGroup() { guard ensureAccessibility() else { return }; panel?.show(); panel?.showGroupEditor(groupID: nil) }
    @objc private func manageGroups() { guard ensureAccessibility() else { return }; panel?.showGroupManagement() }
    @objc private func togglePause() { guard ensureAccessibility() else { return }; if let model { model.setPaused(!model.settings.paused) } }
    @objc private func syncScreenshotShortcut() {
        let enabled = model?.settings.screenshotEnabled == true
        ScreenshotShortcutPolicy.apply(enabled: enabled)
        captureMenuItem?.isEnabled = enabled
        captureWindowMenuItem?.isEnabled = enabled
        mainCaptureMenuItem?.isEnabled = enabled
        mainCaptureWindowMenuItem?.isEnabled = enabled
        if !enabled { MainActor.assumeIsolated { screenshot?.cancel() } }
    }
    private func configureAccessibilityGate(model: AppModel) {
        let gate = AccessibilityGate(permission: { [weak model] in model?.paste.trusted == true })
        gate.onChange = { [weak self, weak model] granted in
            guard let model else { return }
            if granted { model.start(); model.monitor.resetBaseline(); model.monitor.start() }
            else {
                model.monitor.stop(); model.paste.invalidate()
                self?.panel?.dismiss()
                MainActor.assumeIsolated { self?.screenshot?.cancel() }
            }
        }
        gate.onGuidance = { [weak self] in
            self?.showSettings()
            self?.settingsWindow?.showAccessibilityGuidance()
        }
        accessibilityGate = gate
        panel?.allowPresentation = { [weak gate] in gate?.check(presentIfDenied: true) == true }
        model.onAccessibilityRequired = { [weak gate] in gate?.check(presentIfDenied: true) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak gate] _ in gate?.check() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }
    private func ensureAccessibility() -> Bool {
        accessibilityGate?.check(presentIfDenied: true) ?? smoke
    }
    @objc private func showSettings() {
        guard let model else { return }
        panel?.dismiss()
        settingsController(for: model).showWindow(nil)
    }
    func settingsController(for model: AppModel) -> SettingsController {
        if let settingsWindow { return settingsWindow }
        let controller = SettingsController(model: model)
        controller.onPresentationChange = { [weak self] presented in
            guard let self, !self.smoke, !self.quitting else { return }
            let policy: NSApplication.ActivationPolicy = presented ? .regular : .accessory
            if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        }
        settingsWindow = controller
        return controller
    }
}
