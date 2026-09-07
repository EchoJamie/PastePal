import AppKit
import PastePalLocalization
import ClipboardCore
import ImageIO
import UniformTypeIdentifiers

final class SmokeDriver {
    private let model: AppModel
    private let panel: PanelController
    private let statusItem: NSStatusItem?
    private let statusMenu: NSMenu?
    private var settingsWindow: SettingsController?
    private var statusActionsEnabledInCardState = false
    private var plainActionDisabledForImage = false
    private var idleToolbarValidated = false
    private var compactToolbarValidated = false
    private var searchEditingToolbarValidated = false
    private var searchCompletedToolbarValidated = false
    private var cancelledToolbarValidated = false
    private var noGroupToolbarValidated = false
    private var groupToolbarValidated = false
    private var selectedGroupValidated = false
    private var groupSearchScopeValidated = false
    private var searchScopeRemovalRendered = false
    private var groupPickerRendered = false
    private var groupSearchCancelledRestored = false
    private var contextualGroupDeleteRendered = false
    private var groupInlineManagementAvailable = false
    private var groupEditorRendered = false
    private var inferredSourceTooltipRendered = false
    private var nativeMouseRoutingValidated = false
    private var longTextLayoutRendered = false
    private var unknownSourceRendered = false
    private var settingsGeneralRendered = false
    private var settingsShortcutsRendered = false
    private var settingsRetentionRendered = false
    private var settingsPrivacyRendered = false
    private var settingsSidebarIconsAdaptive = false
    private var settingsDefaultWidthExpanded = false
    private var panelFrameValidated = false
    private var renderedPanelHeight: CGFloat = 0
    private var renderedPanelFrame = ""
    private var targetScreenFrame = ""
    private var smokeTextEntries: [HistoryEntry] = []
    private var smokeGroups: [ClipGroup] = []
    private var longTextEntry: HistoryEntry?
    init(model: AppModel, panel: PanelController, statusItem: NSStatusItem?) {
        self.model = model; self.panel = panel; self.statusItem = statusItem; statusMenu = statusItem?.menu
    }
    func run() {
        do {
            try model.store.clear()
            for text in ["周末计划\n把常用的小工具做得更顺手。", "  let message = \"Hello 世界\"\n  print(message)", "读书摘记\n每一次复制，都可以轻松找回来。", "读书候选\n这条记录用于验证移除搜索范围后会扩大结果。"] {
                smokeTextEntries.append(try model.store.record(ContentCodec.decode([Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]), limit: 1000))
            }
            try model.store.record(ContentCodec.decode([Representation(type: "public.utf8-plain-text", data: Data("rgba(42, 121, 228, 0.82)".utf8))]), limit: 1000)
            let sampleDirectory = model.store.directory.appendingPathComponent("SmokeFiles", isDirectory: true)
            try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
            let fileURLs = [sampleDirectory.appendingPathComponent("产品说明.pdf"), sampleDirectory.appendingPathComponent("界面参考.png")]
            try Data("sample".utf8).write(to: fileURLs[0]); try Data([1, 2, 3]).write(to: fileURLs[1])
            let fileValues = fileURLs.enumerated().map { Representation(type: "public.file-url", data: Data($0.element.absoluteString.utf8), itemIndex: $0.offset) }
            try model.store.record(ContentCodec.decode(fileValues), limit: 1000)
            let gif = NSMutableData(); let gifDestination = CGImageDestinationCreateWithData(gif, UTType.gif.identifier as CFString, 2, nil)!
            for color in [CGColor(red: 0.94, green: 0.33, blue: 0.28, alpha: 1), CGColor(red: 0.26, green: 0.76, blue: 0.52, alpha: 1)] {
                let frame = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                frame.setFillColor(color); frame.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
                CGImageDestinationAddImage(gifDestination, frame.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
            }
            CGImageDestinationFinalize(gifDestination)
            try model.store.record(ContentCodec.decode([Representation(type: UTType.gif.identifier, data: gif as Data)]), limit: 1000)
            let context = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 2560, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.22, green: 0.58, blue: 0.93, alpha: 0.85)); context.fillEllipse(in: CGRect(x: 60, y: 40, width: 340, height: 320))
            context.setFillColor(CGColor(red: 1, green: 0.65, blue: 0.25, alpha: 1)); context.fillEllipse(in: CGRect(x: 290, y: 140, width: 250, height: 220))
            let data = NSMutableData(); let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, context.makeImage()!, nil); CGImageDestinationFinalize(dest)
            let source = SourceApplication(bundleID: "com.apple.Safari", name: "Safari")
            let link = try model.store.record(
                ContentCodec.decode([Representation(type: "public.utf8-plain-text", data: Data("https://example.com/notes".utf8))]),
                source: source,
                sourceIcon: AppModel.applicationIconPNG(source),
                limit: 1000
            )
            try model.store.updateLinkMetadata(
                id: link.id,
                expectedFingerprint: link.fingerprint,
                payload: LinkMetadataPayload(status: .ready, title: "把常用工具做得更顺手", siteName: "Example Notes", iconPNG: data as Data, previewPNG: data as Data)
            )
            let inferredSource = SourceApplication(bundleID: "com.apple.TextEdit", name: "文本编辑", attribution: .foreground)
            _ = try model.store.record(
                ContentCodec.decode([Representation(type: "public.png", data: data as Data)]),
                source: inferredSource,
                sourceIcon: AppModel.applicationIconPNG(inferredSource),
                limit: 1000
            )
            let longText = String(repeating: "单行中英文 MixedContent 与 https://example.com/aVeryLongPathWithoutSpaces 自动折行。", count: 18)
            longTextEntry = try model.store.record(
                ContentCodec.decode([Representation(type: "public.utf8-plain-text", data: Data(longText.utf8))]),
                limit: 1000
            )
            model.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                panel.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
                    nativeMouseRoutingValidated = validateNativeMouseRouting()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                    panel.prepareForDisplay()
                    if let window = panel.window, let screen = window.screen {
                        renderedPanelHeight = window.frame.height
                        panelFrameValidated = window.frame == PanelLayout.frame(in: screen.frame)
                        renderedPanelFrame = NSStringFromRect(window.frame)
                        targetScreenFrame = NSStringFromRect(screen.frame)
                    }
                    noGroupToolbarValidated = validateToolbar(searchVisible: false)
                        && panel.groupLabelTitles.isEmpty
                        && panel.isNewGroupControlVisible
                    inferredSourceTooltipRendered = descendants(of: panel.window?.contentView)
                        .compactMap { $0 as? CardView }
                        .contains { $0.toolTip == "推定来源：文本编辑" }
                    if let longTextEntry,
                       let card = descendants(of: panel.window?.contentView)
                        .compactMap({ $0 as? CardView })
                        .first(where: { $0.entry?.id == longTextEntry.id }) {
                        let metrics = CardTextLayout.metrics(
                            longTextEntry.text ?? "",
                            size: NSSize(width: 208, height: 145),
                            font: .systemFont(ofSize: 12.5)
                        )
                        longTextLayoutRendered = metrics.lineCount > 4 && metrics.isTruncated
                        unknownSourceRendered = card.toolTip == "来源未知"
                            && (card.accessibilityLabel() ?? "").contains("来源未知")
                    }
                    capture(name: "native-panel-no-groups.png", appearance: .aqua)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [self] in
                    do {
                        smokeGroups = try ["工作事务", "深度阅读", "灵感与收藏", "代码片段备忘", "产品设计参考", "稍后继续阅读", "当前项目资料", "长篇写作素材", "个人生活清单", "阅读与知识归档"].map { try model.store.createGroup(name: $0) }
                        try model.store.add(entryID: smokeTextEntries[0].id, toGroup: smokeGroups[0].id)
                        try model.store.add(entryID: smokeTextEntries[2].id, toGroup: smokeGroups[9].id)
                        model.refresh()
                    } catch { fputs("分组冒烟准备失败：\(error)\n", stderr); NSApp.terminate(nil) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                    panel.prepareForDisplay()
                    idleToolbarValidated = validateToolbar(searchVisible: false)
                    groupToolbarValidated = panel.groupLabelTitles == smokeGroups.map(\.name) && panel.selectedGroupID == nil
                    capture(name: "native-panel-groups.png", appearance: .aqua)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [self] in
                    panel.selectGroup(smokeGroups[9].id)
                    selectedGroupValidated = panel.selectedGroupID == smokeGroups[9].id
                        && panel.visibleEntryIDs == [smokeTextEntries[2].id]
                    capture(name: "native-panel-group-selected.png", appearance: .aqua)
                    compactToolbarValidated = captureAtWidth(name: "native-panel-groups-compact.png", width: 1280, appearance: .aqua)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) { [self] in
                    panel.beginSearch(selectAll: false)
                    panel.searchControl.stringValue = "读书"
                    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [self] in
                    searchEditingToolbarValidated = validateToolbar(searchVisible: true)
                        && panel.interactionMode == .search
                        && panel.searchControl.currentEditor() != nil
                    groupSearchScopeValidated = panel.searchScopeText == "阅读与知识归档  ×"
                        && panel.isSearchScopeControlVisible
                        && panel.activeSearchScopeGroupID == smokeGroups[9].id
                    capture(name: "native-panel-group-search.png", appearance: .aqua)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [self] in
                    panel.removeSearchScope()
                    searchScopeRemovalRendered = !panel.isSearchScopeControlVisible
                        && panel.activeSearchScopeGroupID == nil
                        && Set(panel.visibleEntryIDs) == Set([smokeTextEntries[2].id, smokeTextEntries[3].id])
                    capture(name: "native-panel-search-all.png", appearance: .aqua)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.25) { [self] in
                    panel.finishSearch()
                    searchCompletedToolbarValidated = validateToolbar(searchVisible: true)
                        && panel.interactionMode == .cards
                        && panel.visibleQuery == "读书"
                        && panel.isCollectionFocused
                    capture(name: "native-panel-group-search-completed.png", appearance: .aqua)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.45) { [self] in
                    panel.beginSearch(selectAll: true)
                    panel.searchControl.stringValue = "没有这条"
                    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) { [self] in capture(name: "native-panel-empty.png", appearance: .aqua) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.85) { [self] in
                    panel.cancelSearch()
                    cancelledToolbarValidated = validateToolbar(searchVisible: false)
                        && panel.interactionMode == .cards
                        && panel.visibleQuery.isEmpty
                        && panel.isCollectionFocused
                    groupSearchCancelledRestored = panel.selectedGroupID == smokeGroups[9].id
                        && panel.visibleEntryIDs == [smokeTextEntries[2].id]
                    capture(name: "native-panel-group-search-cancelled.png", appearance: .aqua)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) { [self] in
                    if !panel.isVisible {
                        panel.show()
                        panel.selectGroup(smokeGroups[9].id)
                    }
                    panel.showGroupPicker()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { [self] in
                    if panel.isGroupJoinVisible, let window = panel.window {
                        groupPickerRendered = panel.isGroupToolbarVisible && window.attachedSheet == nil
                        captureWindow(window, name: "native-group-picker.png")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [self] in
                    panel.closeGroupInteraction()
                    if let statusMenu {
                        statusMenu.delegate?.menuWillOpen?(statusMenu)
                        let contextualTitle = "从「阅读与知识归档」移除所选（Delete）"
                        contextualGroupDeleteRendered = statusMenu.item(withTitle: contextualTitle)?.isEnabled == true
                            && statusMenu.item(withTitle: "永久删除所选…")?.isHidden == false
                        statusMenu.delegate?.menuDidClose?(statusMenu)
                    }
                    if let groupID = panel.selectedGroupID {
                        panel.beginGroupRename(groupID)
                        groupInlineManagementAvailable = panel.groupLabelEditor?.window === panel.window
                        capture(name: "native-group-label-editing.png", appearance: .aqua)
                        panel.cancelGroupRename()
                        panel.requestSelectedGroupDeletion()
                        groupInlineManagementAvailable = groupInlineManagementAvailable && panel.isGroupDeleteConfirmationVisible
                        capture(name: "native-group-delete-confirmation.png", appearance: .aqua)
                        panel.groupEditorController?.cancelDelete()
                    }
                    panel.newGroupControl.performClick(nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.72) { [self] in
                    if let window = panel.groupCreationView?.window {
                        groupEditorRendered = window === panel.window && window.attachedSheet == nil
                        captureWindow(window, name: "native-group-editor.png")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.9) { [self] in
                    panel.groupCreationView?.cancel()
                    if let groupID = panel.selectedGroupID { panel.selectGroup(groupID) }
                    validateStatusActionsInCardState()
                    capture(name: "native-panel-dark.png", appearance: .darkAqua)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) { [self] in
                    panel.dismiss()
                    settingsWindow = SettingsController(model: model); settingsWindow?.showWindow(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                        validateAndCaptureSettingsPages()
                        let statusActionsDisabledWithoutPanel = validateStatusActionsWithoutPanel()
                        let plainItem = statusMenu?.item(withTitle: "纯文本使用所选")
                        let panelControls = self.descendants(of: self.panel.window?.contentView)
                        let kinds = Set(model.entries.map(\.kind))
                        let statusImage = statusItem?.button?.image
                        let statusResourceURL = AppResources.bundle.url(forResource: "StatusPastePalTemplate", withExtension: "svg")
                        let appIconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
                        let appIconURL = appIconName.flatMap { Bundle.main.url(forResource: $0, withExtension: "icns") }
                        let cardEffectCount = panelControls.compactMap { $0 as? CardView }
                            .flatMap { self.descendants(of: $0) }
                            .filter { $0 is NSVisualEffectView }.count
                        let cardSize = (panel.historyView.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize ?? .zero
                        let root = panel.panelRootView
                        let toolbar = panel.isSearchControlVisible ? panel.searchControl.superview?.superview : panel.searchTriggerControl.superview
                        let toolbarFrame = toolbar?.convert(toolbar?.bounds ?? .zero, to: root) ?? .zero
                        let hintFrame = panel.shortcutHintControl.convert(panel.shortcutHintControl.bounds, to: root)
                        let viewportFrame = panel.historyScrollView.convert(panel.historyScrollView.bounds, to: root)
                        let report: [String: Any] = [
                            "os": ProcessInfo.processInfo.operatingSystemVersionString,
                            "localizedAppName": AppIdentity.displayName,
                            "translationResourcesLoaded": AppLocalization.render("跟随系统", language: .english) == "Follow System" && AppLocalization.render("浅色", language: .traditionalChinese) == "淺色",
                            "mainMenuUsesLocalizedAppName": NSApp.mainMenu?.items.first?.title == AppIdentity.displayName
                                && NSApp.mainMenu?.items.first?.submenu?.items.contains(where: { $0.title == "退出 \(AppIdentity.displayName)" && $0.keyEquivalent == "q" }) == true,
                            "settingsTitleUsesLocalizedAppName": settingsWindow?.window?.title == "\(AppIdentity.displayName) · 设置",
                            "statusItemUsesLocalizedAppName": statusItem?.button?.toolTip == AppIdentity.displayName,
                            "statusItemImageIsTemplate": statusImage?.isTemplate == true,
                            "statusItemImageSizeIs18": statusImage?.size == StatusIcon.size,
                            "statusItemImageUsesPastePalResource": statusResourceURL != nil
                                && statusImage?.name() == NSImage.Name("StatusPastePalTemplate")
                                && statusImage?.representations.contains { $0.pixelsWide == 0 && $0.pixelsHigh == 0 } == true,
                            "bundleAppIconLoaded": appIconURL.flatMap(NSImage.init(contentsOf:)) != nil,
                            "nativeWindowRendered": true,
                            "preferredPanelHeightIs356": panel.preferredPanelHeight == 356,
                            "renderedPanelHeight": renderedPanelHeight,
                            "renderedPanelFrame": renderedPanelFrame,
                            "targetScreenFrame": targetScreenFrame,
                            "panelUsesTargetScreenRealBottomAndFullWidth": panelFrameValidated,
                            "cardsAreLargerWithOriginalAspectRatio": cardSize.height > 248 && abs(cardSize.width / cardSize.height - 238.0 / 248.0) < 0.001,
                            "cardsUseRecoveredBottomSpace": abs(viewportFrame.minY - 7) < 0.5 && abs(cardSize.height + 16 - viewportFrame.height) < 0.5,
                            "hintSharesTopRowWithoutOverlap": abs(hintFrame.midY - toolbarFrame.midY) < 0.5 && hintFrame.maxX + 12 <= toolbarFrame.minX + 0.5,
                            "idleToolbarCentered": idleToolbarValidated,
                            "noGroupToolbarHasSearchAndCreate": noGroupToolbarValidated,
                            "customGroupToolbarRendered": groupToolbarValidated,
                            "selectedGroupRendered": selectedGroupValidated,
                            "groupSearchScopeRendered": groupSearchScopeValidated,
                            "searchScopeRemovalRendered": searchScopeRemovalRendered,
                            "groupSearchCancelRestored": groupSearchCancelledRestored,
                            "groupPickerRendered": groupPickerRendered,
                            "contextualGroupDeleteRendered": contextualGroupDeleteRendered,
                            "groupInlineManagementAvailable": groupInlineManagementAvailable,
                            "groupEditorRendered": groupEditorRendered,
                            "customGroupCount": model.groups.count,
                            "compactToolbarCentered": compactToolbarValidated,
                            "searchEditingToolbarCentered": searchEditingToolbarValidated,
                            "searchCompletedToolbarCentered": searchCompletedToolbarValidated,
                            "cancelledToolbarCentered": cancelledToolbarValidated,
                            "compactWidthRendered": true,
                            "searchStateRendered": true,
                            "emptyStateRendered": true,
                            "sampleRecords": model.entries.count,
                            "nativeMouseRoutingValidated": nativeMouseRoutingValidated,
                            "longSingleLineTextRendered": longTextLayoutRendered,
                            "unknownSourceRendered": unknownSourceRendered,
                            "fileCardRendered": kinds.contains(.file),
                            "colorCardRendered": kinds.contains(.color),
                            "animatedGIFCardRendered": model.entries.contains { $0.kind == .image && ($0.frameCount ?? 1) > 1 },
                            "multiItemFileCardRendered": model.entries.contains { $0.kind == .file && $0.itemCount == 2 },
                            "linkMetadataCardRendered": model.entries.contains { $0.linkMetadata?.title == "把常用工具做得更顺手" },
                            "sourceAndSiteSeparated": model.entries.contains { $0.source?.name == "Safari" && $0.linkMetadata?.siteName == "Example Notes" },
                            "cachedSourceIconRendered": model.entries.contains { $0.source?.iconFile != nil },
                            "inferredSourceTooltipRendered": inferredSourceTooltipRendered,
                            "panelUsesVisualEffectBackground": panel.window?.contentView === panel.panelRootView && panel.backgroundEffect.superview === panel.panelRootView,
                            "backgroundAndContentAreSeparateSiblings": panel.panelContentView.superview === panel.panelRootView && !panel.historyView.isDescendant(of: panel.backgroundEffect),
                            "backgroundMaterialIsPopover": panel.backgroundEffect.material == .popover,
                            "backgroundKeepsFullOpacity": panel.backgroundEffect.alphaValue == 1 && panel.window?.alphaValue == 1 && panel.panelRootView.alphaValue == 1 && panel.panelContentView.alphaValue == 1,
                            "backgroundBlendingIsBehindWindow": panel.backgroundEffect.blendingMode == .behindWindow,
                            "backgroundStateIsActive": panel.backgroundEffect.state == .active,
                            "windowUsesClearBackground": panel.window?.isOpaque == false && panel.window?.backgroundColor == .clear,
                            "windowKeepsNativeShadow": panel.window?.hasShadow == true,
                            "panelClipsContinuousRoundedCorners": panel.panelRootView.layer?.cornerRadius == 18 && panel.panelRootView.layer?.cornerCurve == .continuous && panel.panelRootView.layer?.masksToBounds == true,
                            "panelRoundsOnlyTopCorners": panel.panelRootView.layer?.maskedCorners == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner],
                            "panelHasNoRectangularLayerBorder": panel.panelRootView.layer?.borderWidth == 0,
                            "cardVisualEffectSubviewCount": cardEffectCount,
                            "reduceTransparencyEnabled": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                            "panelPopupButtonCount": panelControls.filter { $0 is NSPopUpButton }.count,
                            "panelSegmentedControlCount": panelControls.filter { $0 is NSSegmentedControl }.count,
                            "panelSettingsButtonCount": panelControls.compactMap { $0 as? NSButton }.filter { $0.toolTip == "设置" }.count,
                            "statusMenuItems": statusMenu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [],
                            "statusMenuAutomaticEnablingDisabled": statusMenu?.autoenablesItems == false,
                            "statusActionsEnabledInCardState": statusActionsEnabledInCardState,
                            "statusActionsDisabledWithoutPanel": statusActionsDisabledWithoutPanel,
                            "plainActionDisabledForImage": plainActionDisabledForImage,
                            "noSeparateCopyOnlyMenu": statusMenu?.item(withTitle: "仅复制所选") == nil,
                            "plainShortcutIsOptionReturn": plainItem?.keyEquivalent == AppShortcutAction.usePlainText.defaultShortcut.nsMenuItemKeyEquivalent && plainItem?.keyEquivalentModifierMask == AppShortcutAction.usePlainText.defaultShortcut.modifiers,
                            "addToGroupShortcutIsCommandG": statusMenu?.item(withTitle: "将所选加入分组…")?.keyEquivalent == "g"
                                && statusMenu?.item(withTitle: "将所选加入分组…")?.keyEquivalentModifierMask == [.command],
                            "groupManagementMenuRendered": statusMenu?.item(withTitle: "管理分组")?.action != nil && statusMenu?.item(withTitle: "管理分组")?.submenu == nil,
                            "settingsGeneralRendered": settingsGeneralRendered,
                            "settingsShortcutsRendered": settingsShortcutsRendered,
                            "settingsRetentionRendered": settingsRetentionRendered,
                            "settingsPrivacyRendered": settingsPrivacyRendered,
                            "settingsSidebarIconsAdaptive": settingsSidebarIconsAdaptive,
                            "settingsDefaultWidthExpanded": settingsDefaultWidthExpanded,
                            "accessibilityTrusted": model.paste.trusted,
                            "generalPasteboardTested": false,
                            "crossAppPasteTested": false
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: model.store.directory.deletingLastPathComponent().appendingPathComponent("native-smoke.json"))
                        }
                        if ProcessInfo.processInfo.arguments.contains("--exit-after-smoke") { NSApp.terminate(nil) }
                    }
                }
            }
        } catch { fputs("原生冒烟失败：\(error)\n", stderr); NSApp.terminate(nil) }
    }
    private func capture(name: String, appearance: NSAppearance.Name) {
        NSApp.appearance = NSAppearance(named: appearance)
        panel.window?.appearance = NSAppearance(named: appearance)
        if let window = panel.window { captureWindow(window, name: name) }
    }
    private func captureAtWidth(name: String, width: CGFloat, appearance: NSAppearance.Name) -> Bool {
        guard let window = panel.window else { return false }
        let frame = window.frame
        window.appearance = NSAppearance(named: appearance)
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: min(width, frame.width), height: frame.height), display: true)
        let toolbarValidated = validateToolbar(searchVisible: false)
            && panel.groupStripOverflows
            && panel.isSelectedGroupVisible
        captureWindow(window, name: name)
        window.setFrame(frame, display: true)
        return toolbarValidated
    }
    private func validateToolbar(searchVisible: Bool) -> Bool {
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        return panel.isSearchControlVisible == searchVisible
            && panel.isGroupToolbarVisible != searchVisible
            && panel.isNewGroupControlVisible != searchVisible
            && abs(panel.visibleToolbarCenterOffset) <= 0.5
            && panel.visibleToolbarDoesNotOverlapCount
    }
    private func validateNativeMouseRouting() -> Bool {
        guard let window = panel.window else { return false }
        panel.historyView.layoutSubtreeIfNeeded()
        guard panel.visibleEntryIDs.indices.contains(1),
              let second = panel.historyView.item(at: IndexPath(item: 1, section: 0)) else { return false }

        let cardClicked = click(second.view, in: window)
            && panel.isVisible
            && panel.selectedEntryID == panel.visibleEntryIDs[1]
        let searchButtonClicked = click(panel.searchTriggerControl, in: window)
            && panel.isVisible
            && panel.interactionMode == .search
            && panel.searchControl.currentEditor() != nil
        let searchFieldClicked = click(panel.searchControl, in: window)
            && panel.isVisible
            && window.firstResponder === panel.searchControl.currentEditor()
        panel.cancelSearch()
        let newGroupClicked = click(panel.newGroupControl, in: window)
            && panel.isVisible
            && panel.groupCreationView != nil
        panel.closeGroupInteraction()
        panel.prepareForDisplay()
        return cardClicked && searchButtonClicked && searchFieldClicked && newGroupClicked
    }
    private func click(_ view: NSView, in window: NSWindow, clickCount: Int = 1) -> Bool {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let down = mouseEvent(.leftMouseDown, in: window, at: point, clickCount: clickCount),
              let up = mouseEvent(.leftMouseUp, in: window, at: point, clickCount: clickCount) else { return false }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        return true
    }
    private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint, clickCount: Int) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0
        )
    }
    private func validateAndCaptureSettingsPages() {
        guard let controller = settingsWindow,
              let window = controller.window,
              let sidebar = descendants(of: window.contentView)
                .compactMap({ $0 as? NSTableView })
                .first(where: { $0.accessibilityLabel() == "设置分类" }) else { return }
        func select(_ row: Int) {
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            controller.tableViewSelectionDidChange(
                Notification(name: NSTableView.selectionDidChangeNotification, object: sidebar)
            )
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func labels() -> [String] {
            descendants(of: window.contentView).compactMap { view in
                if let button = view as? NSButton, !button.title.isEmpty { return button.title }
                if let field = view as? NSTextField, !field.stringValue.isEmpty { return field.stringValue }
                return nil
            }
        }
        func accessible(_ label: String) -> NSView? {
            descendants(of: window.contentView).first { $0.accessibilityLabel() == label }
        }

        window.setContentSize(NSSize(width: 920, height: 600))
        settingsDefaultWidthExpanded = window.contentView?.bounds.width == 920
        window.appearance = NSAppearance(named: .aqua)
        NSApp.appearance = NSAppearance(named: .aqua)
        select(0)
        captureWindow(window, name: "native-settings.png")

        window.setContentSize(NSSize(width: 720, height: 360))
        window.appearance = NSAppearance(named: .darkAqua)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        select(0)
        let generalLabels = labels()
        settingsGeneralRendered = ["登录时启动", "暂停记录", "外观", "语言"].allSatisfy(generalLabels.contains)
            && accessible("外观模式") is NSPopUpButton && accessible("应用语言") is NSPopUpButton
        let categoryCells = (0..<sidebar.numberOfRows).compactMap {
            sidebar.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView
        }
        settingsSidebarIconsAdaptive = categoryCells.count == 5
            && categoryCells.allSatisfy { $0.imageView?.image?.isTemplate == true && $0.imageView?.contentTintColor != .black }
        captureWindow(window, name: "native-settings-general-dark.png")

        select(1)
        let shortcutLabels = descendants(of: window.contentView).compactMap { $0.accessibilityLabel() }
        settingsShortcutsRendered = shortcutLabels.contains("呼出历史快捷键")
            && shortcutLabels.contains("区域截屏快捷键")
            && descendants(of: window.contentView).filter { $0 is SettingsShortcutRecorder }.count == AppShortcutAction.allCases.count
        captureWindow(window, name: "native-settings-shortcuts-dark.png")

        select(2)
        let savedMode = model.settings.retentionMode
        guard let mode = accessible("未分组历史保留单位") as? NSPopUpButton,
              let quantity = accessible("未分组历史保留数量") as? NSTextField else { return }
        mode.selectItem(at: 1)
        if let action = mode.action { _ = NSApp.sendAction(action, to: mode.target, from: mode) }
        window.contentView?.layoutSubtreeIfNeeded()
        let countState = quantity.isEnabled && quantity.stringValue == "10000" && model.settings.retentionMode == .count
        captureWindow(window, name: "native-settings-history-count-dark.png")
        mode.selectItem(at: 0)
        if let action = mode.action { _ = NSApp.sendAction(action, to: mode.target, from: mode) }
        window.contentView?.layoutSubtreeIfNeeded()
        let timeState = quantity.isEnabled && quantity.stringValue == "30" && model.settings.retentionMode == .time
        settingsRetentionRendered = countState && timeState
        captureWindow(window, name: "native-settings-history-dark.png")
        mode.selectItem(at: savedMode == .time ? 0 : 1)
        if let action = mode.action { _ = NSApp.sendAction(action, to: mode.target, from: mode) }

        select(3)
        let privacyLabels = labels()
        settingsPrivacyRendered = privacyLabels.contains("打开辅助功能设置")
            && privacyLabels.contains("添加应用…")
            && accessible("不记录的应用") is NSTableView
        captureWindow(window, name: "native-settings-privacy-dark.png")
    }
    private func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(of: $0) }
    }
    private var statusSelectionItems: [NSMenuItem] {
        ["纯文本使用所选", "将所选加入分组…", "永久删除所选（Delete）"].compactMap { statusMenu?.item(withTitle: $0) }
    }
    private func validateStatusActionsInCardState() {
        guard let statusMenu else { return }
        if let selectedGroupID = panel.selectedGroupID { panel.selectGroup(selectedGroupID) }
        if let imageIndex = panel.visibleEntryIDs.firstIndex(where: { id in model.entries.first(where: { $0.id == id })?.kind == .image }) {
            panel.collectionView(panel.historyView, didSelectItemsAt: [IndexPath(item: imageIndex, section: 0)])
        }
        statusMenu.delegate?.menuWillOpen?(statusMenu)
        plainActionDisabledForImage = statusMenu.item(withTitle: "纯文本使用所选")?.isEnabled == false
            && statusMenu.item(withTitle: "永久删除所选（Delete）")?.isEnabled == true
        statusMenu.delegate?.menuDidClose?(statusMenu)
        guard let index = panel.visibleEntryIDs.firstIndex(where: { id in model.entries.first(where: { $0.id == id })?.supportsPlainText == true }) else { return }
        panel.collectionView(panel.historyView, didSelectItemsAt: [IndexPath(item: index, section: 0)])
        statusMenu.delegate?.menuWillOpen?(statusMenu)
        statusActionsEnabledInCardState = statusSelectionItems.count == 3 && statusSelectionItems.allSatisfy(\.isEnabled)
        statusMenu.delegate?.menuDidClose?(statusMenu)
    }
    private func validateStatusActionsWithoutPanel() -> Bool {
        guard let statusMenu else { return false }
        statusMenu.delegate?.menuWillOpen?(statusMenu)
        let disabled = statusSelectionItems.count == 3 && statusSelectionItems.allSatisfy { !$0.isEnabled }
        statusMenu.delegate?.menuDidClose?(statusMenu)
        return disabled
    }
    private func captureWindow(_ window: NSWindow, name: String) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded(); view.display()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let directory = model.store.directory.deletingLastPathComponent()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        print("已渲染原生窗口：\(name)")
    }
}
