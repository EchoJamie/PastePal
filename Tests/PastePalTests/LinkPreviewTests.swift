import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClipboardCore
@testable import PastePal

private final class ControlledLinkMetadataLoader: LinkMetadataLoading {
    private let lock = NSLock()
    private var callbacks: [(URL, (LinkMetadataPayload) -> Void)] = []
    private(set) var cancelled = false
    var requestCount: Int { lock.withLock { callbacks.count } }
    func fetch(_ url: URL, completion: @escaping (LinkMetadataPayload) -> Void) {
        lock.withLock { callbacks.append((url, completion)) }
    }
    func cancelAll() { lock.withLock { cancelled = true; callbacks.removeAll() } }
    func complete(_ payload: LinkMetadataPayload) {
        let callback = lock.withLock { callbacks.isEmpty ? nil : callbacks.removeFirst().1 }
        callback?(payload)
    }
    func takeCompletion() -> ((LinkMetadataPayload) -> Void)? {
        lock.withLock { callbacks.isEmpty ? nil : callbacks.removeFirst().1 }
    }
}

private final class StubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else { return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LinkPreviewTests: AppTestSupport {
    @MainActor func testLinkMetadataUpdatesSearchWithoutChangingClipboardOrderOrSearchState() async throws {
        let loader = ControlledLinkMetadataLoader()
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, linkMetadataLoader: loader)
        let original = "https://example.test/original"
        try PasteboardIO.write(values(original), to: board); model.monitor.poll()
        try await waitUntil { model.entries.first?.text == original && loader.requestCount == 1 }
        let firstCopy = try XCTUnwrap(model.entries.first)

        try PasteboardIO.write(values(original), to: board); model.monitor.poll()
        try await waitUntil { model.entries.first?.copiedAt != firstCopy.copiedAt }
        XCTAssertEqual(loader.requestCount, 1, "同一记录等待元数据时不能并发重复抓取")
        let beforeMetadata = try XCTUnwrap(model.entries.first)
        let panel = PanelController(model: model); panel.prepareForDisplay()
        panel.beginSearch(selectAll: false)
        panel.searchControl.stringValue = "异步网页标题"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        try await waitUntil { panel.visibleEntryIDs.isEmpty }

        loader.complete(LinkMetadataPayload(status: .ready, title: "异步网页标题", siteName: "Example Site", iconPNG: try pngData(), previewPNG: try pngData()))
        try await waitUntil { model.entries.first?.linkMetadata?.title == "异步网页标题" && panel.visibleEntryIDs.count == 1 }
        let afterMetadata = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(panel.interactionMode, .search)
        XCTAssertEqual(panel.visibleQuery, "异步网页标题")
        XCTAssertTrue(panel.isSearchControlVisible)
        XCTAssertFalse(panel.isGroupToolbarVisible)
        XCTAssertNotNil(panel.searchControl.currentEditor(), "元数据刷新不能抢走搜索编辑焦点")
        XCTAssertEqual(afterMetadata.id, beforeMetadata.id)
        XCTAssertEqual(afterMetadata.activity, beforeMetadata.activity)
        XCTAssertEqual(afterMetadata.copiedAt, beforeMetadata.copiedAt)
        XCTAssertEqual(board.string(forType: .string), original)
        XCTAssertEqual(try model.store.content(id: afterMetadata.id).representations, values(original))
        XCTAssertEqual(try model.store.entries(query: original).map(\.id), [afterMetadata.id])
        XCTAssertNil(model.status)
    }

    @MainActor func testDelayedLinkMetadataCannotRestoreDeletedEntryAndOfflineFailureStaysQuiet() async throws {
        let loader = ControlledLinkMetadataLoader()
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, linkMetadataLoader: loader)
        try PasteboardIO.write(values("https://deleted.example/item"), to: board); model.monitor.poll()
        try await waitUntil { model.entries.count == 1 && loader.requestCount == 1 }
        let id = try XCTUnwrap(model.entries.first?.id)
        model.delete(id: id)
        try await waitUntil { model.entries.isEmpty }
        loader.complete(LinkMetadataPayload(status: .ready, title: "迟到标题", iconPNG: try pngData(), previewPNG: try pngData()))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(try model.store.entries().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: model.store.imageDirectory.path).isEmpty)

        try PasteboardIO.write(values("https://offline.example/item"), to: board); model.monitor.poll()
        try await waitUntil { model.entries.count == 1 && loader.requestCount == 1 }
        loader.complete(LinkMetadataPayload(status: .failed))
        try await waitUntil { model.entries.first?.linkMetadata?.status == .failed }
        XCTAssertEqual(model.entries.first?.text, "https://offline.example/item")
        XCTAssertNil(model.status)
    }

    @MainActor func testPreparingToQuitCancelsMetadataAndRejectsLateCallback() async throws {
        let loader = ControlledLinkMetadataLoader()
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, linkMetadataLoader: loader)
        try PasteboardIO.write(values("https://shutdown.example/item"), to: board); model.monitor.poll()
        try await waitUntil { model.entries.count == 1 && loader.requestCount == 1 }
        let callback = try XCTUnwrap(loader.takeCompletion())
        let quit = expectation(description: "退出准备完成")
        model.prepareToQuit { quit.fulfill() }
        await fulfillment(of: [quit], timeout: 2)
        XCTAssertTrue(loader.cancelled)

        callback(LinkMetadataPayload(status: .ready, title: "不应写入", iconPNG: try pngData(), previewPNG: try pngData()))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(try model.store.entries().first?.linkMetadata)
    }

    func testControlledURLSessionFetchesTitleAndImagesWithoutCookies() async throws {
        let image = try pngData()
        let lock = NSLock(); var requests: [URLRequest] = []
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                lock.withLock { requests.append(request) }
                let requested = request.url!
                if requested.host == "origin.test" {
                    Thread.sleep(forTimeInterval: 0.05)
                    let html = #"<html><head><meta content="OpenAI" property="og:site_name"><meta content="受控标题 &#38; 元数据" property="og:title"><meta content="cover.png" property="og:image"><link href="icon.png" rel="icon"></head></html>"#
                    let responseURL = URL(string: "https://assets.test/page/final")!
                    return (HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!, Data(html.utf8))
                }
                return (HTTPURLResponse(url: requested, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, image)
            }
        }
        defer { StubURLProtocol.lock.withLock { StubURLProtocol.handler = nil } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let loader = LinkMetadataFetcher(configuration: configuration)
        let expectation = expectation(description: "元数据完成")
        expectation.expectedFulfillmentCount = 2
        var payloads: [LinkMetadataPayload] = []
        let url = URL(string: "https://origin.test/original")!
        loader.fetch(url) { payload in lock.withLock { payloads.append(payload) }; expectation.fulfill() }
        loader.fetch(url) { payload in lock.withLock { payloads.append(payload) }; expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 2)

        let payload = try XCTUnwrap(lock.withLock { payloads.first })
        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payload.status, .ready)
        XCTAssertEqual(payload.title, "受控标题 & 元数据")
        XCTAssertEqual(payload.siteName, "OpenAI")
        XCTAssertNotNil(payload.iconPNG); XCTAssertNotNil(payload.previewPNG)
        let captured = lock.withLock { requests }
        XCTAssertEqual(captured.first?.url?.absoluteString, "https://origin.test/original")
        XCTAssertEqual(captured.filter { $0.url?.host == "origin.test" }.count, 1, "相同 URL 的并发请求应合并")
        XCTAssertTrue(captured.dropFirst().allSatisfy { $0.url?.host == "assets.test" })
        XCTAssertTrue(captured.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Range") != nil })
        loader.cancelAll()
    }

    func testLinkMetadataKeepsOversizedHTMLPrefixAndUsesFaviconFallback() async throws {
        let lock = NSLock(); var requests: [URLRequest] = []
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                lock.withLock { requests.append(request) }
                let data = Data(repeating: 65, count: 1_000_001)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html", "Content-Length": "1000001"])!, data)
            }
        }
        defer { StubURLProtocol.lock.withLock { StubURLProtocol.handler = nil } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let loader = LinkMetadataFetcher(configuration: configuration)
        let expectation = expectation(description: "超限请求完成")
        var payload: LinkMetadataPayload?
        loader.fetch(URL(string: "https://oversized.test/page")!) { payload = $0; expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 2)

        XCTAssertEqual(payload?.status, .ready)
        XCTAssertEqual(lock.withLock { requests.count }, 2)
        XCTAssertEqual(lock.withLock { requests.last?.url?.path }, "/favicon.ico")
        loader.cancelAll()
    }

    func testLinkMetadataOutstandingWorkIsBounded() async throws {
        let lock = NSLock()
        var pageRequests = 0
        var failures = 0
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                if request.url?.path != "/favicon.ico" { lock.withLock { pageRequests += 1 } }
                Thread.sleep(forTimeInterval: 0.05)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
                return (response, Data("<title>受控页面</title>".utf8))
            }
        }
        defer { StubURLProtocol.lock.withLock { StubURLProtocol.handler = nil } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let loader = LinkMetadataFetcher(configuration: configuration, maximumOutstandingPages: 3)
        let completed = expectation(description: "所有请求均有界完成")
        completed.expectedFulfillmentCount = 10
        for index in 0..<10 {
            loader.fetch(URL(string: "https://bounded.test/\(index)")!) { payload in
                if payload.status == .failed { lock.withLock { failures += 1 } }
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(lock.withLock { pageRequests }, 3)
        XCTAssertEqual(lock.withLock { failures }, 7)
        loader.cancelAll()
    }
}
