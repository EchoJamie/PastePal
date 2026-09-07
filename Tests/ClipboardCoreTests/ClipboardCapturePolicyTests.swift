import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardCore

final class ClipboardCapturePolicyTests: HistoryTestSupport {
    func testPausedExcludedAndResumeBaseline() throws {
        var gate = RecordingGate(initialCount: 10)
        let values = text("A").representations
        XCTAssertFalse(gate.consume(count: 11, representations: values, paused: true, excluded: false))
        XCTAssertFalse(gate.consume(count: 12, representations: values, paused: false, excluded: true))
        gate.resetBaseline(13)
        XCTAssertFalse(gate.consume(count: 13, representations: values, paused: false, excluded: false))
        XCTAssertTrue(gate.consume(count: 14, representations: values, paused: false, excluded: false))
    }

    func testOwnWriteSkipsOnlyExactCountAndContent() {
        let a = text("A").representations, b = text("B").representations
        var gate = RecordingGate(initialCount: 1)
        gate.noteOwnWrite(count: 2, representations: a)
        XCTAssertTrue(gate.consume(count: 3, representations: b, paused: false, excluded: false))
        gate.noteOwnWrite(count: 4, representations: a)
        XCTAssertTrue(gate.consume(count: 4, representations: b, paused: false, excluded: false))
    }
}
