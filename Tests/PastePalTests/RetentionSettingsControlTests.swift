import PastePalLocalization
import XCTest
import AppKit
import ClipboardCore
@testable import PastePal

final class RetentionSettingsControlTests: XCTestCase {
    @MainActor func testEditingCommitsOnlyOnCompletionAndRetainsBothUnitValues() {
        var stored = HistoryRetentionPolicy(mode: .time, count: 1000, days: 30)
        var submissions = 0
        let control = RetentionSettingsControl(readPolicy: { stored }, savePolicy: { policy, completion in
            submissions += 1; stored = policy; completion(true)
        })
        XCTAssertEqual(control.quantity.stringValue, "30")
        XCTAssertEqual(control.unit.itemTitles, [L("天"), L("条")])
        control.quantity.stringValue = "45"
        XCTAssertEqual(submissions, 0)
        control.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        XCTAssertEqual(stored.days, 45)
        control.commitQuantity()
        XCTAssertEqual(submissions, 1)
        control.unit.selectItem(at: 1); control.changeUnit()
        XCTAssertEqual(stored.mode, .count)
        XCTAssertEqual(control.quantity.stringValue, "1000")
        control.quantity.stringValue = "250"; control.commitQuantity()
        control.unit.selectItem(at: 0); control.changeUnit()
        XCTAssertEqual(control.quantity.stringValue, "45")
        XCTAssertEqual(stored.count, 250)
        XCTAssertEqual(submissions, 4)
    }
    @MainActor func testInvalidAndFailedSavesRestoreSavedPolicyAndIgnoreOldCallbacks() {
        var stored = HistoryRetentionPolicy(mode: .time, count: 1000, days: 30)
        var pending: [(HistoryRetentionPolicy, (Bool) -> Void)] = []
        let control = RetentionSettingsControl(readPolicy: { stored }, savePolicy: { pending.append(($0, $1)) })
        for invalid in ["", "0", "-1", "1.5", "abc"] {
            control.quantity.stringValue = invalid; control.commitQuantity()
            XCTAssertEqual(control.quantity.stringValue, "30")
            XCTAssertFalse(control.feedback.stringValue.isEmpty)
        }
        XCTAssertTrue(pending.isEmpty)
        control.quantity.stringValue = "7"; control.commitQuantity()
        XCTAssertTrue(control.quantity.isEnabled)
        XCTAssertTrue(control.unit.isEnabled)
        XCTAssertEqual(pending.count, 1)
        pending[0].1(false)
        XCTAssertEqual(control.quantity.stringValue, "30")
        XCTAssertTrue(control.unit.isEnabled)
        XCTAssertTrue(control.feedback.stringValue.contains(L("保存失败，已恢复原设置。请检查记录状态后重试。")))
        control.unit.selectItem(at: 1); control.changeUnit()
        XCTAssertEqual(pending.count, 2)
        pending[0].1(true)
        XCTAssertTrue(control.unit.isEnabled)
        stored = pending[1].0; pending[1].1(true)
        XCTAssertEqual(control.quantity.stringValue, "1000")
        XCTAssertEqual(control.unit.indexOfSelectedItem, 1)
        XCTAssertTrue(control.feedback.stringValue.isEmpty)
    }
}
