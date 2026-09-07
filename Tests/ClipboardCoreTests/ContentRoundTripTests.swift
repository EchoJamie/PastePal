import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardCore

final class ContentRoundTripTests: HistoryTestSupport {
    func testPlainTextRoundTripDoesNotMutateOriginalOrCreateCopy() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let store = try HistoryStore(directory: directory)
        let original = text("  中文\nCode", extra: [Representation(type: "public.rtf", data: Data("{\\rtf1 Code}".utf8))])
        let entry = try store.record(original, limit: 10)
        var gate = RecordingGate(initialCount: board.changeCount)
        let plain = try store.content(id: entry.id).output(plainText: true)
        let count = try PasteboardIO.write(plain, to: board)
        gate.noteOwnWrite(count: count, representations: plain)
        XCTAssertFalse(gate.consume(count: count, representations: try PasteboardIO.snapshot(board), paused: false, excluded: false))
        try store.markUsed(id: entry.id)
        XCTAssertEqual(board.string(forType: .string), "  中文\nCode")
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(try store.content(id: entry.id).representations, original.representations)
        XCTAssertEqual(try store.entries().count, 1)
        try PasteboardIO.write(original.representations, to: board)
        XCTAssertEqual(board.data(forType: .rtf), original.representations[1].data)
    }

    func testFinderMultipleFilesRoundTripPreservesNativeItemsAndSearchableNames() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("项目说明.txt")
        let second = directory.appendingPathComponent("示意图.png")
        try Data("readme".utf8).write(to: first); try Data([1, 2, 3]).write(to: second)
        let source = NSPasteboard.withUniqueName(); defer { source.releaseGlobally() }
        XCTAssertTrue(source.writeObjects([first as NSURL, second as NSURL]))

        let snapshot = try PasteboardIO.snapshot(source)
        XCTAssertEqual(snapshot.map(\.itemIndex), [0, 1])
        let content = try ContentCodec.decode(snapshot)
        XCTAssertEqual(content.kind, .file)
        XCTAssertEqual(content.fileURLs, [first, second])
        XCTAssertEqual(content.text, "项目说明.txt\n示意图.png")

        let store = try HistoryStore(directory: directory)
        let entry = try store.record(content, limit: 10)
        XCTAssertTrue(entry.files.isEmpty, "文件记录只保存 URL 引用，不备份源文件")
        XCTAssertEqual(try store.entries(query: "示意图").map(\.id), [entry.id])
        let restored = try store.content(id: entry.id)
        let target = NSPasteboard.withUniqueName(); defer { target.releaseGlobally() }
        try PasteboardIO.write(try restored.output(plainText: false), to: target)
        XCTAssertEqual(target.pasteboardItems?.count, 2)
        XCTAssertEqual(try PasteboardIO.snapshot(target), snapshot)
    }

    func testMissingFileReferenceIsVisibleAndFailsBeforePasteboardWrite() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("稍后删除.txt")
        try Data("temporary".utf8).write(to: file)
        let content = try ContentCodec.decode([Representation(type: "public.file-url", data: Data(file.absoluteString.utf8))])
        let store = try HistoryStore(directory: directory)
        let entry = try store.record(content, limit: 10)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try XCTUnwrap(store.entries().first).hasMissingFiles)

        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try PasteboardIO.write(text("当前内容").representations, to: board)
        XCTAssertThrowsError(try store.content(id: entry.id).output(plainText: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("稍后删除.txt"))
        }
        XCTAssertEqual(board.string(forType: .string), "当前内容")
    }

    func testColorRecognitionIsStrictAndOriginalTextRoundTrips() throws {
        let valid: [(String, ClipboardColor)] = [
            ("#0af", ClipboardColor(red: 0, green: 170, blue: 255, alpha: 255)),
            ("#0af8", ClipboardColor(red: 0, green: 170, blue: 255, alpha: 136)),
            ("#112233", ClipboardColor(red: 17, green: 34, blue: 51, alpha: 255)),
            ("#11223380", ClipboardColor(red: 17, green: 34, blue: 51, alpha: 128)),
            ("rgb(12, 34, 255)", ClipboardColor(red: 12, green: 34, blue: 255, alpha: 255)),
            ("  rgba(1, 2, 3, 0.5)\n", ClipboardColor(red: 1, green: 2, blue: 3, alpha: 128))
        ]
        for (source, expected) in valid {
            XCTAssertEqual(ContentCodec.color(from: source), expected)
            let original = Representation(type: "public.utf8-plain-text", data: Data(source.utf8))
            let content = try ContentCodec.decode([original])
            XCTAssertEqual(content.kind, .color)
            XCTAssertEqual(try content.output(plainText: false), [original])
        }
        for source in ["颜色 #fff", "#12345", "#123456 text", "rgb(256, 0, 0)", "rgb(1, 2, 3, 0.5)", "rgba(1, 2, 3)", "rgba(1, 2, 3, 1.1)"] {
            XCTAssertNil(ContentCodec.color(from: source), source)
            XCTAssertEqual(try ContentCodec.decode([Representation(type: "public.utf8-plain-text", data: Data(source.utf8))]).kind, .text)
        }
    }

    func testHTMLOnlyAndRTFDPreserveBytesAndProvideSearchableText() throws {
        let html = Data("<style>.hidden{display:none}</style><p>你好 <strong>HTML</strong> &amp; 本地</p><script>不能搜索</script>".utf8)
        let htmlContent = try ContentCodec.decode([Representation(type: "public.html", data: html)])
        XCTAssertEqual(htmlContent.kind, .text)
        XCTAssertEqual(htmlContent.text, "你好 HTML & 本地")
        XCTAssertEqual(htmlContent.representations.first?.data, html)

        let attributed = NSAttributedString(string: "RTFD 可搜索内容")
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        XCTAssertEqual(try ContentCodec.decode([Representation(type: "public.rtf", data: rtf)]).text, "RTFD 可搜索内容")
        let rtfd = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let content = try ContentCodec.decode([Representation(type: "com.apple.flat-rtfd", data: rtfd)])
        XCTAssertEqual(content.text, "RTFD 可搜索内容")
        let store = try HistoryStore(directory: directory)
        let entry = try store.record(content, limit: 10)
        XCTAssertEqual(try store.entries(query: "可搜索").map(\.id), [entry.id])
        XCTAssertEqual(try store.content(id: entry.id).representations.first?.data, rtfd)
    }

    func testJPEGAndAnimatedGIFKeepSourceBytesAndUseFirstFrameThumbnail() throws {
        let jpeg = try imageData(type: UTType.jpeg.identifier)
        let jpegContent = try ContentCodec.decode([Representation(type: UTType.jpeg.identifier, data: jpeg)])
        XCTAssertEqual(jpegContent.kind, .image)
        XCTAssertEqual(jpegContent.width, 18); XCTAssertEqual(jpegContent.height, 12)
        XCTAssertEqual(jpegContent.representations.first?.data, jpeg)

        let gif = try imageData(type: UTType.gif.identifier, frames: 2)
        let gifContent = try ContentCodec.decode([Representation(type: UTType.gif.identifier, data: gif)])
        XCTAssertEqual(gifContent.frameCount, 2)
        XCTAssertNotNil(gifContent.thumbnail)
        XCTAssertEqual(gifContent.representations.first?.data, gif)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(gifContent.representations[0].data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)

        let store = try HistoryStore(directory: directory)
        let entry = try store.record(gifContent, limit: 10)
        XCTAssertEqual(try store.content(id: entry.id).representations.first?.data, gif)
        XCTAssertEqual(try store.content(id: entry.id).frameCount, 2)
    }

    func testCodecRejectsMixedInvalidImageAndHTMLWithoutText() throws {
        XCTAssertThrowsError(try ContentCodec.decode(text("A").representations + image().representations))
        XCTAssertThrowsError(try ContentCodec.decode([Representation(type: "public.png", data: Data([0]))]))
        XCTAssertThrowsError(try ContentCodec.decode([Representation(type: "public.html", data: Data("<img src='https://example.com'>".utf8))]))
        XCTAssertThrowsError(try ContentCodec.decode([Representation(type: "com.example.private-object", data: Data([1]))]))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("通用后备文字", forType: .string))
        XCTAssertTrue(item.setData(Data([1, 2, 3]), forType: .init("com.example.private-object")))
        board.clearContents(); XCTAssertTrue(board.writeObjects([item]))
        XCTAssertEqual(try PasteboardIO.snapshot(board).map(\.type), ["public.utf8-plain-text"])
    }
}
