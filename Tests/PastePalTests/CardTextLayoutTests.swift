import PastePalLocalization
import XCTest
import AppKit
import ClipboardCore
@testable import PastePal

final class CardTextLayoutTests: XCTestCase {
    private let bodySize = NSSize(width: 208, height: 160)
    private let font = NSFont.systemFont(ofSize: 12.5)

    @MainActor func testLongSingleLineUsesAvailableCardHeightAndTruncatesLastLine() {
        let text = String(repeating: "这是一段中英文MixedContent用于验证单行内容自动折行", count: 30)

        let metrics = CardTextLayout.metrics(text, size: bodySize, font: font)

        XCTAssertGreaterThan(metrics.lineCount, 4)
        XCTAssertTrue(metrics.isTruncated)
        XCTAssertLessThanOrEqual(metrics.usedRect.width, bodySize.width + 0.5)
        XCTAssertLessThanOrEqual(metrics.usedRect.height, bodySize.height + 0.5)
    }

    @MainActor func testExplicitNewlinesRemainSeparateLines() {
        let metrics = CardTextLayout.metrics("第一行\nSecond line\n第三行", size: bodySize, font: font)

        XCTAssertEqual(metrics.lineCount, 3)
        XCTAssertFalse(metrics.isTruncated)
    }

    @MainActor func testLongURLFallsBackToCharacterWrappingWithoutHorizontalOverflow() {
        let url = "https://example.com/" + String(repeating: "veryLongPath没有空格", count: 12)

        let metrics = CardTextLayout.metrics(url, size: NSSize(width: 120, height: 120), font: font)

        XCTAssertGreaterThan(metrics.lineCount, 3)
        XCTAssertLessThanOrEqual(metrics.usedRect.width, 120.5)
    }

    func testSourcePresentationDistinguishesDeclaredInferredAndUnknown() {
        let declared = SourceApplication(bundleID: "com.example.editor", name: "编辑器")
        let inferred = SourceApplication(
            bundleID: "com.example.browser",
            name: "浏览器",
            attribution: .foreground
        )

        XCTAssertEqual(CardSourcePresentation.detail(declared), L("复制来源：\(declared.name)"))
        XCTAssertEqual(CardSourcePresentation.detail(inferred), L("推定来源：\(inferred.name)"))
        XCTAssertEqual(CardSourcePresentation.accessibilitySuffix(inferred), L("，推定来自\(inferred.name)"))
        XCTAssertEqual(CardSourcePresentation.detail(nil), L("来源未知"))
        XCTAssertEqual(CardSourcePresentation.accessibilitySuffix(nil), L("，来源未知"))
        XCTAssertEqual(CardSourcePresentation.fallbackIconName(declared), "app.dashed")
        XCTAssertEqual(CardSourcePresentation.fallbackIconName(nil), "questionmark.app.dashed")
    }
}
