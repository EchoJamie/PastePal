import PastePalLocalization
import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClipboardCore
@testable import PastePal

final class ClipboardSourceTests: AppTestSupport {
    @MainActor func testSourceResolverUsesDeclarationThenForegroundTimelineAndBoundsAmbiguity() throws {
        let editor = ClipboardApplicationDescriptor(bundleID: "com.example.editor", name: "编辑器")
        let browser = ClipboardApplicationDescriptor(bundleID: "com.example.browser", name: "浏览器")
        let panel = ClipboardApplicationDescriptor(bundleID: AppIdentity.bundleID, name: "贴伴")
        let declared = ClipboardApplicationDescriptor(bundleID: "com.example.declared", name: "声明应用")
        let resolver = ClipboardSourceResolver(
            pasteboard: board,
            initialApplication: editor,
            notificationCenter: nil,
            currentApplicationProvider: { nil },
            applicationLookup: { $0 == declared.bundleID ? declared : nil },
            maximumActivations: 2
        )

        let explicit = try XCTUnwrap(resolver.source(declaredBundleID: declared.bundleID, changeCount: 1))
        XCTAssertEqual(explicit.bundleID, declared.bundleID)
        XCTAssertEqual(explicit.attribution, .declared)

        resolver.noteActivation(browser, observedChangeCount: 2)
        resolver.noteActivation(panel, observedChangeCount: 2)
        let beforeActivation = try XCTUnwrap(resolver.source(declaredBundleID: "com.example.uninstalled", changeCount: 2))
        XCTAssertEqual(beforeActivation.bundleID, editor.bundleID, "复制后才发生的首次激活不能成为来源")
        XCTAssertEqual(beforeActivation.attribution, .foreground)

        resolver.didConsume(changeCount: 2)
        resolver.noteActivation(browser, observedChangeCount: 2)
        let afterActivation = try XCTUnwrap(resolver.source(declaredBundleID: nil, changeCount: 3))
        XCTAssertEqual(afterActivation.bundleID, browser.bundleID, "复制前已经激活的应用可以作为推定来源")

        let selfResolver = ClipboardSourceResolver(
            pasteboard: board,
            initialApplication: panel,
            notificationCenter: nil,
            currentApplicationProvider: { nil },
            applicationLookup: { _ in nil }
        )
        XCTAssertNil(selfResolver.source(declaredBundleID: nil, changeCount: 1))

        let overflow = ClipboardSourceResolver(
            pasteboard: board,
            initialApplication: editor,
            notificationCenter: nil,
            currentApplicationProvider: { nil },
            applicationLookup: { _ in nil },
            maximumActivations: 1
        )
        overflow.noteActivation(browser, observedChangeCount: 4)
        overflow.noteActivation(panel, observedChangeCount: 4)
        XCTAssertNil(overflow.source(declaredBundleID: nil, changeCount: 4), "激活序列溢出时不能武断归因")

        var currentAtStart = editor
        let firstMonitor = ClipboardSourceResolver(
            pasteboard: board,
            initialApplication: editor,
            notificationCenter: nil,
            currentApplicationProvider: { currentAtStart },
            applicationLookup: { _ in nil }
        )
        _ = try PasteboardIO.write(values("首次变化"), to: board)
        currentAtStart = browser
        firstMonitor.start()
        XCTAssertEqual(firstMonitor.source(declaredBundleID: nil, changeCount: board.changeCount)?.bundleID, editor.bundleID)
    }

    @MainActor func testSourceResolverObserverLifecycleIsIdempotent() {
        let center = NotificationCenter()
        let resolver = ClipboardSourceResolver(
            pasteboard: board,
            initialApplication: nil,
            notificationCenter: center,
            currentApplicationProvider: { nil },
            applicationLookup: { _ in nil }
        )
        resolver.start(); resolver.start()
        XCTAssertTrue(resolver.isObserving)
        resolver.stop(); resolver.stop()
        XCTAssertFalse(resolver.isObserving)
    }

    @MainActor func testDeclaredSourceWinsAndForegroundSourceCachesIcon() async throws {
        var iconLookups = 0
        let icon = try pngData()
        let editor = ClipboardApplicationDescriptor(bundleID: "com.example.editor", name: "编辑器")
        let safari = ClipboardApplicationDescriptor(bundleID: "com.apple.Safari", name: "Safari")
        let resolver = ClipboardSourceResolver(
            pasteboard: board,
            initialApplication: editor,
            notificationCenter: nil,
            currentApplicationProvider: { nil },
            applicationLookup: { $0 == safari.bundleID ? safari : nil }
        )
        let model = try AppModel(
            directory: directory,
            settings: SettingsStore(defaults: defaults),
            pasteboard: board,
            sourceResolver: resolver,
            sourceIconProvider: { _ in iconLookups += 1; return icon }
        )
        func write(_ text: String, source: String?) {
            let item = NSPasteboardItem(); item.setString(text, forType: .string)
            if let source { item.setString(source, forType: .init("org.nspasteboard.source")) }
            board.clearContents(); board.writeObjects([item]); model.monitor.poll()
        }
        write("来自 Safari", source: "com.apple.Safari")
        try await waitUntil { model.entries.first?.text == "来自 Safari" }
        let first = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(first.source?.bundleID, "com.apple.Safari")
        XCTAssertEqual(first.source?.name, "Safari")
        XCTAssertEqual(first.source?.attribution, .declared)
        XCTAssertNotNil(first.source?.iconFile)
        XCTAssertEqual(try model.store.entries(query: "Safari").map(\.id), [first.id])

        write("仍来自 Safari", source: "com.apple.Safari")
        try await waitUntil { model.entries.first?.text == "仍来自 Safari" }
        XCTAssertEqual(iconLookups, 1)
        XCTAssertEqual(model.entries.prefix(2).compactMap { $0.source?.iconFile }.count, 2)
        XCTAssertEqual(Set(model.entries.prefix(2).compactMap { $0.source?.iconFile }).count, 1)

        write("没有来源声明", source: nil)
        try await waitUntil { model.entries.first?.text == "没有来源声明" }
        let inferred = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(inferred.source?.bundleID, editor.bundleID)
        XCTAssertEqual(inferred.source?.attribution, .foreground)
        XCTAssertEqual(iconLookups, 2)

        let card = CardItem()
        card.loadView()
        card.configure(inferred, thumbnail: nil, sourceIcon: model.store.sourceIconURL(for: inferred), linkIcon: nil, linkPreview: nil, imageCache: CardImageCache(), number: 1)
        XCTAssertEqual(card.card.toolTip, L("推定来源：\("编辑器")"))
        XCTAssertNotNil(card.card.sourceIcon, "来源应用退出或无法再查询时仍使用已保存图标")
        XCTAssertTrue((card.card.accessibilityLabel() ?? "").contains(L("，推定来自\("编辑器")")))
    }

    @MainActor func testForegroundSourcePassesThroughTextLinkColorImageAndFileCaptures() throws {
        let app = ClipboardApplicationDescriptor(bundleID: "com.example.writer", name: "写作应用")
        let resolver = ClipboardSourceResolver(
            pasteboard: board,
            initialApplication: app,
            notificationCenter: nil,
            currentApplicationProvider: { nil },
            applicationLookup: { _ in nil }
        )
        let monitor = ClipboardMonitor(settings: SettingsStore(defaults: defaults), pasteboard: board, sourceResolver: resolver)
        var captured: [(ContentKind, SourceApplication?)] = []
        monitor.onCapture = { values, source in captured.append((try! ContentCodec.decode(values).kind, source)) }
        let file = directory.appendingPathComponent("隔离文件.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)
        let fixtures: [[Representation]] = [
            values("普通文字"),
            values("https://example.com/source-test"),
            values("#123ABC"),
            [Representation(type: UTType.png.identifier, data: try pngData())],
            [Representation(type: UTType.fileURL.identifier, data: Data(file.absoluteString.utf8))]
        ]
        for fixture in fixtures {
            _ = try PasteboardIO.write(fixture, to: board)
            monitor.poll()
        }
        XCTAssertEqual(captured.map(\.0), [.text, .text, .color, .image, .file])
        XCTAssertEqual(captured.compactMap { $0.1?.bundleID }, Array(repeating: app.bundleID, count: fixtures.count))
        XCTAssertTrue(captured.allSatisfy { $0.1?.attribution == .foreground })
    }
}

final class ClipboardSourceRegressionTests: XCTestCase {
    private let finder = ClipboardApplicationDescriptor(bundleID: "com.apple.finder", name: "Finder")
    private let editor = ClipboardApplicationDescriptor(bundleID: "com.example.editor", name: "编辑器")

    @MainActor func testUnknownWriterIsNotReplacedByFinderActivatedAfterCopy() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let resolver = makeResolver(board, initial: nil)
        resolver.noteActivation(finder, observedChangeCount: 12)
        XCTAssertNil(resolver.source(declaredBundleID: nil, changeCount: 12))
        resolver.didConsume(changeCount: 12)
        XCTAssertEqual(resolver.source(declaredBundleID: nil, changeCount: 13)?.bundleID, finder.bundleID)
        XCTAssertEqual(resolver.source(declaredBundleID: nil, changeCount: 13)?.attribution, .foreground)
    }

    @MainActor func testUnidentifiableActivationClearsStaleApplication() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let resolver = makeResolver(board, initial: editor)
        resolver.noteActivation(nil, observedChangeCount: 10)
        XCTAssertNil(resolver.currentBundleID)
        XCTAssertNil(resolver.source(declaredBundleID: nil, changeCount: 11))
        resolver.noteActivation(finder, observedChangeCount: 11)
        XCTAssertNil(resolver.source(declaredBundleID: nil, changeCount: 11))
    }

    @MainActor func testInvalidActivationCannotRetainStaleApplication() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let resolver = makeResolver(board, initial: editor)
        resolver.noteActivation(.init(bundleID: "", name: ""), observedChangeCount: 10)
        XCTAssertNil(resolver.source(declaredBundleID: nil, changeCount: 11))
    }

    @MainActor func testSelfDeclarationDoesNotFallBackToFinder() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let resolver = makeResolver(board, initial: finder)
        XCTAssertNil(resolver.source(declaredBundleID: AppIdentity.bundleID, changeCount: 10))
        XCTAssertEqual(resolver.source(declaredBundleID: "invalid", changeCount: 10)?.attribution, .foreground)
    }

    @MainActor func testIdlePollingDiscardsConsumedActivationHistoryBeforeNextCopy() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let suite = "ClipboardSourceRegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = makeResolver(board, initial: editor, maximumActivations: 1)
        let monitor = ClipboardMonitor(settings: SettingsStore(defaults: defaults), pasteboard: board, sourceResolver: resolver)
        resolver.noteActivation(finder, observedChangeCount: board.changeCount)
        monitor.poll()
        resolver.noteActivation(editor, observedChangeCount: board.changeCount)
        var captured: SourceApplication?
        monitor.onCapture = { _, source in captured = source }
        try PasteboardIO.write([Representation(type: "public.utf8-plain-text", data: Data("合成来源测试".utf8))], to: board)
        monitor.poll()
        XCTAssertEqual(captured?.bundleID, editor.bundleID)
        XCTAssertEqual(captured?.attribution, .foreground)
    }

    @MainActor func testKnownFinderSourceLoadsLocalIconWhenCachedFileIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = SourceApplication(bundleID: finder.bundleID, name: finder.name, attribution: .foreground)
        let applicationURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: finder.bundleID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: applicationURL.path))
        XCTAssertNotNil(AppModel.applicationIconPNG(source))
        let store = try HistoryStore(directory: directory)
        let content = try ContentCodec.decode([Representation(type: "public.utf8-plain-text", data: Data("合成图标测试".utf8))])
        let entry = try store.record(content, source: source, limit: 10)
        let card = CardItem()
        _ = card.view
        card.configure(entry, thumbnail: nil, sourceIcon: directory.appendingPathComponent("missing.png"), linkIcon: nil, linkPreview: nil, imageCache: CardImageCache(), number: 1)
        XCTAssertEqual(card.card.entry?.source?.bundleID, finder.bundleID)
        XCTAssertNotNil(card.card.sourceIcon)
    }

    private func makeResolver(_ board: NSPasteboard, initial: ClipboardApplicationDescriptor?, maximumActivations: Int = 16) -> ClipboardSourceResolver {
        ClipboardSourceResolver(
            pasteboard: board, initialApplication: initial, notificationCenter: nil,
            currentApplicationProvider: { nil }, applicationLookup: { _ in nil },
            maximumActivations: maximumActivations
        )
    }
}
