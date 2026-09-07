import AppKit
import ClipboardCore

// 仅供官网素材导出，不启动监听或读取用户历史。
enum WebsitePreviewRenderer {
    static func render(output: URL, imageURL: URL) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PastePalWebsite-\(UUID().uuidString)")
        let suite = "local.pastepal.website.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        defer {
            defaults.removePersistentDomain(forName: suite)
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: temporary)
        }
        let model = try AppModel(directory: temporary, settings: SettingsStore(defaults: defaults), pasteboard: board)
        let image = try Data(contentsOf: imageURL)
        func record(_ values: [Representation], source: SourceApplication) throws -> HistoryEntry {
            try model.store.record(ContentCodec.decode(values), source: source,
                                   sourceIcon: AppModel.applicationIconPNG(source), limit: 1000)
        }
        func text(_ value: String, source: SourceApplication) throws -> HistoryEntry {
            try record([Representation(type: "public.utf8-plain-text", data: Data(value.utf8))], source: source)
        }
        let notes = SourceApplication(bundleID: "com.apple.Notes", name: "备忘录")
        let finder = SourceApplication(bundleID: "com.apple.finder", name: "访达")
        let preview = SourceApplication(bundleID: "com.apple.Preview", name: "预览")
        let safari = SourceApplication(bundleID: "com.apple.Safari", name: "Safari")
        let files = temporary.appendingPathComponent("展示文件")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let brief = files.appendingPathComponent("周末灵感.txt")
        let artwork = files.appendingPathComponent("图标参考.png")
        try Data("把喜欢的片刻，留在手边。".utf8).write(to: brief)
        try image.write(to: artwork)
        let documents = try record([brief, artwork].enumerated().map {
            Representation(type: "public.file-url", data: Data($0.element.absoluteString.utf8), itemIndex: $0.offset)
        }, source: finder)
        _ = try text("#E7826B", source: notes)
        let link = try text("https://example.com/ideas", source: safari)
        try model.store.updateLinkMetadata(id: link.id, expectedFingerprint: link.fingerprint,
            payload: LinkMetadataPayload(status: .ready, title: "给灵感，留一点空间", siteName: "设计手记", iconPNG: image))
        let picture = try record([Representation(type: "public.png", data: image)], source: preview)
        let note = try text("周末的小计划\n\n逛一家没去过的书店\n给阳台的植物浇水\n留一个下午，慢慢散步。", source: notes)
        for (name, entry) in [("日常", note), ("灵感收藏", picture), ("工作资料", documents)] {
            let group = try model.store.createGroup(name: name)
            try model.store.add(entryID: entry.id, toGroup: group.id)
        }
        model.refresh()
        let deadline = Date().addingTimeInterval(5)
        while model.entries.count != 5 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard model.entries.count == 5 else { throw CocoaError(.coderInvalidValue) }
        let panel = PanelController(model: model)
        guard let window = panel.window, let view = window.contentView else { throw CocoaError(.coderInvalidValue) }
        window.setContentSize(NSSize(width: 1440, height: PanelLayout.height))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearanceName) in [("panel-light.png", NSAppearance.Name.aqua), ("panel-dark.png", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            app.appearance = appearance
            window.appearance = appearance
            panel.prepareForDisplay()
            view.layoutSubtreeIfNeeded()
            view.display()
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.coderInvalidValue) }
            bitmap.size = view.bounds.size
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
            try data.write(to: output.appendingPathComponent(name), options: .atomic)
        }
        panel.dismiss()
        window.close()
    }
}
