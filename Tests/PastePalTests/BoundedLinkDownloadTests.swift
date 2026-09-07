import XCTest
import ClipboardCore
@testable import PastePal

private final class StreamingLinkProtocol: URLProtocol {
    struct Fixture {
        var headers = ["Content-Type": "text/html"]
        var chunks = [Data("small".utf8)]
        var error: URLError?
        var hangs = false
        var redirect: URL?
    }
    static let lock = NSLock()
    static var fixtures: [String: Fixture] = [:]
    static var delivered: [String: Int] = [:]
    static var stopped: Set<String> = []
    static var requested: Set<String> = []
    static var requests: [String: URLRequest] = [:]
    private let stateLock = NSLock()
    private var cancelled = false
    private let stream = DispatchQueue(label: "test.link-stream")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let fixture = Self.lock.withLock { () -> Fixture in
            Self.requested.insert(path)
            Self.requests[path] = request
            return Self.fixtures[path] ?? Fixture(headers: ["Content-Type": "image/png"], chunks: [])
        }
        if let target = fixture.redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        send(fixture, index: 0, path: path)
    }
    private func send(_ fixture: Fixture, index: Int, path: String) {
        stream.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                guard !self.cancelled else { return }
                guard index < fixture.chunks.count else {
                    if let error = fixture.error { self.client?.urlProtocol(self, didFailWithError: error) }
                    else if !fixture.hangs { self.client?.urlProtocolDidFinishLoading(self) }
                    return
                }
                let data = fixture.chunks[index]
                Self.lock.withLock { Self.delivered[path, default: 0] += data.count }
                self.client?.urlProtocol(self, didLoad: data)
                self.send(fixture, index: index + 1, path: path)
            }
        }
    }
    override func stopLoading() {
        stateLock.withLock { cancelled = true }
        _ = Self.lock.withLock { Self.stopped.insert(request.url!.path) }
    }
}

final class BoundedLinkDownloadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StreamingLinkProtocol.lock.withLock {
            StreamingLinkProtocol.fixtures = [:]
            StreamingLinkProtocol.delivered = [:]
            StreamingLinkProtocol.stopped = []
            StreamingLinkProtocol.requested = []
            StreamingLinkProtocol.requests = [:]
        }
    }
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingLinkProtocol.self]
        configuration.urlCache = nil
        return configuration
    }
    private func fixture(_ path: String, _ fixture: StreamingLinkProtocol.Fixture) {
        StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.fixtures[path] = fixture }
    }
    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://synthetic.invalid\(path)")!)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        return request
    }

    func testUnknownChunkedAndUnderreportedLengthStopDuringReception() async {
        let downloader = BoundedLinkDownloader(configuration: configuration())
        defer { downloader.cancelAll() }
        for (path, extra) in [("/unknown", [:]), ("/chunked", ["Transfer-Encoding": "chunked"]), ("/underreported", ["Content-Length": "100"])] {
            var headers = ["Content-Type": "text/html"]
            headers.merge(extra) { _, value in value }
            fixture(path, .init(headers: headers, chunks: Array(repeating: Data(repeating: 65, count: 256), count: 32)))
            let completed = expectation(description: path)
            completed.assertForOverFulfill = true
            downloader.load(request(path), maximumBytes: 1024, expectedPrefixes: ["text/"]) { result in
                XCTAssertNil(result)
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 2)
            try? await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.delivered[path] }, 1280)
            XCTAssertTrue(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.stopped.contains(path) })
        }
    }

    func testOversizedDeclaredLengthIsRejectedBeforeBody() async {
        fixture("/declared", .init(headers: ["Content-Type": "text/html", "Content-Length": "8388608"], chunks: [Data(repeating: 65, count: 256)]))
        let downloader = BoundedLinkDownloader(configuration: configuration())
        defer { downloader.cancelAll() }
        let completed = expectation(description: "响应头早拒")
        downloader.load(request("/declared"), maximumBytes: 1024, expectedPrefixes: ["text/"]) { result in
            XCTAssertNil(result); completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.delivered["/declared", default: 0] }, 0)
    }

    func testExactLimitAndConcurrentSmallResponsesSucceed() async {
        let downloader = BoundedLinkDownloader(configuration: configuration())
        defer { downloader.cancelAll() }
        let completed = expectation(description: "独立并发响应")
        completed.expectedFulfillmentCount = 3
        for index in 0..<3 {
            let path = "/small-\(index)"
            fixture(path, .init(chunks: Array(repeating: Data(repeating: UInt8(index), count: 256), count: 4)))
            downloader.load(request(path), maximumBytes: 1024, expectedPrefixes: ["text/"]) { result in
                XCTAssertEqual(result?.data, Data(repeating: UInt8(index), count: 1024))
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 2)
    }

    func testTimeoutAndCancellationNeverReturnPartialDataOrCompleteTwice() async {
        let downloader = BoundedLinkDownloader(configuration: configuration())
        defer { downloader.cancelAll() }
        fixture("/timeout", .init(error: URLError(.timedOut)))
        let timeout = expectation(description: "超时不返回部分正文")
        timeout.assertForOverFulfill = true
        downloader.load(request("/timeout"), maximumBytes: 1024, expectedPrefixes: ["text/"], overflowPolicy: .keepPrefix) { result in
            XCTAssertNil(result); timeout.fulfill()
        }
        await fulfillment(of: [timeout], timeout: 2)
        fixture("/cancel", .init(hangs: true))
        let cancelled = expectation(description: "取消只回调一次")
        cancelled.assertForOverFulfill = true
        downloader.load(request("/cancel"), maximumBytes: 1024, expectedPrefixes: ["text/"], overflowPolicy: .keepPrefix) { result in
            XCTAssertNil(result); cancelled.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(40))
        downloader.cancelAll()
        downloader.cancelAll()
        await fulfillment(of: [cancelled], timeout: 2)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.stopped.contains("/cancel") })
    }

    func testRedirectRetainsLimitAndRejectsUnsupportedScheme() async {
        let downloader = BoundedLinkDownloader(configuration: configuration())
        defer { downloader.cancelAll() }
        fixture("/redirect", .init(redirect: request("/target").url))
        fixture("/target", .init(chunks: Array(repeating: Data(repeating: 65, count: 256), count: 32)))
        let oversized = expectation(description: "重定向保留大小上限")
        downloader.load(request("/redirect"), maximumBytes: 1024, expectedPrefixes: ["text/"]) { result in
            XCTAssertNil(result); oversized.fulfill()
        }
        await fulfillment(of: [oversized], timeout: 2)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.delivered["/target"] }, 1280)
        let redirected = StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.requests["/target"] }
        XCTAssertEqual(redirected?.value(forHTTPHeaderField: "Range"), "bytes=0-1023")
        XCTAssertEqual(redirected?.httpShouldHandleCookies, false)
        fixture("/unsafe", .init(redirect: URL(string: "file:///not-read")))
        let rejected = expectation(description: "不跟随不支持的协议")
        downloader.load(request("/unsafe"), maximumBytes: 1024, expectedPrefixes: ["text/"]) { result in
            XCTAssertNil(result); rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertFalse(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.requested.contains("/not-read") })
    }

    func testPrefixPolicyHandlesDeclaredUnknownChunkedAndSingleOversizedBlock() async {
        let downloader = BoundedLinkDownloader(configuration: configuration())
        defer { downloader.cancelAll() }
        let scenarios: [(String, [String: String], [Data], Int)] = [
            ("/prefix-declared", ["Content-Length": "8388608"], Array(repeating: Data(repeating: 65, count: 256), count: 32), 1024),
            ("/prefix-unknown", [:], Array(repeating: Data(repeating: 65, count: 300), count: 32), 1200),
            ("/prefix-chunked", ["Transfer-Encoding": "chunked"], Array(repeating: Data(repeating: 65, count: 256), count: 32), 1024),
            ("/prefix-low-header", ["Content-Length": "10"], Array(repeating: Data(repeating: 65, count: 256), count: 32), 1024),
            ("/prefix-first-block", [:], [Data(repeating: 65, count: 8192), Data(repeating: 66, count: 8192)], 8192)
        ]
        for (path, extra, chunks, sent) in scenarios {
            var headers = ["Content-Type": "text/html"]
            headers.merge(extra) { _, value in value }
            fixture(path, .init(headers: headers, chunks: chunks))
            let completed = expectation(description: path)
            completed.assertForOverFulfill = true
            downloader.load(request(path), maximumBytes: 1024, expectedPrefixes: ["text/"], overflowPolicy: .keepPrefix) { result in
                XCTAssertEqual(result?.data, Data(repeating: 65, count: 1024))
                XCTAssertEqual(result?.isTruncated, true)
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 2)
            try? await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.delivered[path] }, sent)
            XCTAssertTrue(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.stopped.contains(path) })
        }
    }

    func testHTMLPrefixRecoversUTF8TailAndUnclosedTitleButIgnoresIncompleteMeta() async {
        let loader = LinkMetadataFetcher(configuration: configuration())
        defer { loader.cancelAll() }
        for (path, tail, expectedTitle) in [
            ("/utf8-tail", "<title>保留标题</title>中", "保留标题"),
            ("/unclosed-title", "<title>已有标题中", "已有标题"),
            ("/incomplete-meta", "<title>完整标题</title><meta property='og:image' content='/must-not-load中", "完整标题")
        ] {
            let suffix = Data(tail.utf8)
            var body = Data(repeating: 32, count: 1_000_000 - suffix.count + 1)
            body.append(suffix)
            body.append(Data(repeating: 65, count: 1024))
            fixture(path, .init(headers: ["Content-Type": "text/html; charset=utf-8", "Content-Length": "8388608"], chunks: [body, Data(repeating: 66, count: 1024)]))
            let completed = expectation(description: path)
            completed.assertForOverFulfill = true
            loader.fetch(request(path).url!) { payload in
                XCTAssertEqual(payload.status, .ready)
                XCTAssertEqual(payload.title, expectedTitle)
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertTrue(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.stopped.contains(path) })
            XCTAssertEqual(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.delivered[path] }, body.count)
        }
        XCTAssertFalse(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.requested.contains(where: { $0.hasPrefix("/must-not-load") }) })
    }

    func testOversizedHTMLKeepsMetadataAndImagesUseTheirOwnLimits() async {
        let oversized = Array(repeating: Data(repeating: 65, count: 250_000), count: 34)
        fixture("/large-page", .init(chunks: [Data("<title>前缀标题</title><meta property='og:image' content='/prefix-preview'>".utf8)] + oversized))
        let loader = LinkMetadataFetcher(configuration: configuration())
        defer { loader.cancelAll() }
        let failed = expectation(description: "超限HTML保留前缀元数据")
        loader.fetch(request("/large-page").url!) { payload in
            XCTAssertEqual(payload.status, .ready)
            XCTAssertEqual(payload.title, "前缀标题")
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.requested.contains("/prefix-preview") })
        XCTAssertLessThan(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.delivered["/large-page", default: 0] }, 2_000_000)

        fixture("/page", .init(chunks: [Data("<title>小页面</title><meta property='og:image' content='/cover'><link rel='icon' href='/icon'>".utf8)]))
        fixture("/cover", .init(headers: ["Content-Type": "image/png"], chunks: oversized))
        fixture("/icon", .init(headers: ["Content-Type": "image/png"], chunks: oversized))
        let ready = expectation(description: "超限图片保留页面标题")
        loader.fetch(request("/page").url!) { payload in
            XCTAssertEqual(payload.status, .ready)
            XCTAssertEqual(payload.title, "小页面")
            XCTAssertNil(payload.previewPNG)
            XCTAssertNil(payload.iconPNG)
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertEqual(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.delivered["/cover"] }, 2_250_000)
        XCTAssertEqual(StreamingLinkProtocol.lock.withLock { StreamingLinkProtocol.delivered["/icon"] }, 1_000_000)
    }
}
