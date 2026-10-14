import PastePalLocalization
import AppKit
import ApplicationServices

final class PasteCoordinator {
    struct Target {
        let generation: Int
        let app: NSRunningApplication
    }
    private(set) var target: Target?
    private var generation = 0
    private let permission: () -> Bool
    init(permission: @escaping () -> Bool = { AXIsProcessTrusted() }) { self.permission = permission }
    var trusted: Bool { permission() }
    func captureTarget() {
        generation += 1; target = nil
        guard trusted, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        target = Target(generation: generation, app: app)
    }
    func invalidate() { generation += 1; target = nil }
    func requestAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func paste(to saved: Target?, expectedChangeCount: Int, completion: @escaping (String?) -> Void) {
        guard trusted else { completion(L("已复制。直接粘贴需要辅助功能权限，请手动按 ⌘V。")) ; return }
        guard let saved, saved.generation == generation, !saved.app.isTerminated else { completion(L("已复制。无法确认原来的输入窗口，请手动按 ⌘V。")) ; return }
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
            guard front == saved.app.processIdentifier else {
                if retries > 0 {
                    self.checkAndPaste(saved, expectedChangeCount: expectedChangeCount, retries: retries - 1, completion: completion)
                } else {
                    completion(L("已复制。原应用未回到前台，请手动按 ⌘V。"))
                }
                return
            }
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                completion(L("已复制。无法发送粘贴快捷键，请手动按 ⌘V。")) ; return
            }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.postToPid(saved.app.processIdentifier); up.postToPid(saved.app.processIdentifier)
            completion(nil)
        }
    }
}
