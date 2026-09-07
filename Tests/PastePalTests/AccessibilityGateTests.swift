import XCTest
@testable import PastePal

final class AccessibilityGateTests: XCTestCase {
    func testDeniedLaunchAndExplicitRetryGuideWithoutRepeatedPollingPrompts() {
        var granted = false
        let gate = AccessibilityGate(permission: { granted })
        var changes: [Bool] = []
        var guidance = 0
        gate.onChange = { changes.append($0) }
        gate.onGuidance = { guidance += 1 }
        XCTAssertFalse(gate.check(presentIfDenied: true))
        XCTAssertFalse(gate.check())
        XCTAssertFalse(gate.check())
        XCTAssertEqual(guidance, 1)
        XCTAssertEqual(changes, [false])
        XCTAssertFalse(gate.check(presentIfDenied: true))
        XCTAssertEqual(guidance, 2)
        granted = true
        XCTAssertTrue(gate.check())
        XCTAssertEqual(changes, [false, true])
        XCTAssertEqual(guidance, 2)
        granted = false
        XCTAssertFalse(gate.check())
        XCTAssertEqual(changes, [false, true, false])
        XCTAssertEqual(guidance, 3)
        XCTAssertFalse(gate.check())
        XCTAssertEqual(guidance, 3)
    }
}
