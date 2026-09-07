import PastePalLocalization
import AppKit
import ApplicationServices

final class PasteCoordinator {
    struct Target {
        let generation: Int
        let app: NSRunningApplication
        let window: AXUIElement
        let element: AXUIElement
    }
    private(set) var target: Target?
    private var generation = 0
    private let permission: () -> Bool
    init(permission: @escaping () -> Bool = { AXIsProcessTrusted() }) { self.permission = permission }
    var trusted: Bool { permission() }
    func captureTarget() {
        generation += 1; target = nil
        guard trusted, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = attribute(axApp, kAXFocusedWindowAttribute), let element = attribute(axApp, kAXFocusedUIElementAttribute) else { return }
        target = Target(generation: generation, app: app, window: window, element: element)
    }
    func invalidate() { generation += 1; target = nil }
    func requestAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func paste(to saved: Target?, expectedChangeCount: Int, completion: @escaping (String?) -> Void) {
        guard trusted else { completion(L("已复制。直接粘贴需要辅助功能权限，请手动按 ⌘V。")) ; return }
        guard let saved, saved.generation == generation, !saved.app.isTerminated else { completion(L("已复制。无法确认原来的输入窗口，请手动按 ⌘V。")) ; return }
        let axApp = AXUIElementCreateApplication(saved.app.processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement], list.contains(where: { CFEqual($0, saved.window) }) else {
            completion(L("已复制。原窗口已关闭或不可访问，请手动按 ⌘V。")) ; return
        }
        guard AXUIElementPerformAction(saved.window, kAXRaiseAction as CFString) == .success else {
            completion(L("已复制。原窗口无法恢复，请手动按 ⌘V。")) ; return
        }
        saved.app.activate(options: [])
        checkAndPaste(saved, expectedChangeCount: expectedChangeCount, retries: 8, completion: completion)
    }
    private func checkAndPaste(_ saved: Target, expectedChangeCount: Int, retries: Int, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            guard saved.generation == self.generation, self.trusted, !saved.app.isTerminated, NSPasteboard.general.changeCount == expectedChangeCount else {
                completion(L("未发送粘贴：权限、原应用或当前剪贴板已变化。请检查后手动粘贴。")) ; return
            }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let ownPID = ProcessInfo.processInfo.processIdentifier
            guard front == saved.app.processIdentifier || front == ownPID else {
                completion(L("已复制。工作应用已切换，请手动按 ⌘V。")) ; return
            }
            if front == ownPID, retries > 0 {
                self.checkAndPaste(saved, expectedChangeCount: expectedChangeCount, retries: retries - 1, completion: completion); return
            }
            let axApp = AXUIElementCreateApplication(saved.app.processIdentifier)
            guard front == saved.app.processIdentifier,
                  let window = self.attribute(axApp, kAXFocusedWindowAttribute), CFEqual(window, saved.window),
                  let element = self.attribute(axApp, kAXFocusedUIElementAttribute), CFEqual(element, saved.element),
                  let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                completion(L("已复制。输入位置无法可靠恢复，请手动按 ⌘V。")) ; return
            }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.postToPid(saved.app.processIdentifier); up.postToPid(saved.app.processIdentifier)
            completion(nil)
        }
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
