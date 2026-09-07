import Foundation

final class AccessibilityGate {
    private let permission: () -> Bool
    private var previous: Bool?
    var onChange: ((Bool) -> Void)?
    var onGuidance: (() -> Void)?

    init(permission: @escaping () -> Bool) { self.permission = permission }
    @discardableResult func check(presentIfDenied: Bool = false) -> Bool {
        let granted = permission()
        let revoked = previous == true && !granted
        if previous != granted { previous = granted; onChange?(granted) }
        if !granted && (presentIfDenied || revoked) { onGuidance?() }
        return granted
    }
}
