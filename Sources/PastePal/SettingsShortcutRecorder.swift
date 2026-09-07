import PastePalLocalization
import AppKit
import KeyboardShortcuts

final class SettingsShortcutRecorder: NSButton {
    private var shortcut: KeyboardShortcuts.Shortcut
    private let save: (KeyboardShortcuts.Shortcut) -> String?
    private let feedback: (String) -> Void
    private var recording = false
    private let globalShortcuts: [KeyboardShortcuts.Name]
    private var enabledBeforeRecording: [KeyboardShortcuts.Name] = []

    init(label: String, shortcut: KeyboardShortcuts.Shortcut,
         globalShortcuts: [KeyboardShortcuts.Name] = [.showHistory, .captureRegion],
         save: @escaping (KeyboardShortcuts.Shortcut) -> String?, feedback: @escaping (String) -> Void) {
        self.shortcut = shortcut; self.save = save; self.feedback = feedback
        self.globalShortcuts = globalShortcuts
        super.init(frame: .zero)
        title = shortcut.description; bezelStyle = .rounded
        target = self; action = #selector(beginRecording)
        setAccessibilityLabel(label)
        toolTip = L("点击后按新快捷键；按 Esc 取消。")
        widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    @objc private func beginRecording() {
        guard !recording, window?.makeFirstResponder(self) == true else { return }
        recording = true
        enabledBeforeRecording = globalShortcuts.filter { KeyboardShortcuts.isEnabled(for: $0) }
        KeyboardShortcuts.disable(globalShortcuts)
        title = L("请按快捷键…")
        feedback(L("按新快捷键，或按 Esc 取消。"))
    }
    func reloadShortcut(_ value: KeyboardShortcuts.Shortcut) {
        guard !recording else { return }
        shortcut = value; title = value.description
    }
    func cancelRecording() {
        guard recording else { return }
        recording = false
        KeyboardShortcuts.enable(enabledBeforeRecording)
        enabledBeforeRecording.removeAll()
        title = shortcut.description
    }
    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { cancelRecording(); feedback(""); return }
        guard let candidate = KeyboardShortcuts.Shortcut(event: event) else { return }
        if let error = save(candidate) { feedback(error) }
        else { shortcut = candidate; feedback(L("快捷键已保存。")) }
        cancelRecording()
    }
}

final class SettingsShortcutResetButton: NSButton {
    private let reset: () -> Void
    init(label: String, reset: @escaping () -> Void) {
        self.reset = reset
        super.init(frame: .zero)
        title = L("恢复默认"); bezelStyle = .rounded; target = self; action = #selector(restore)
        setAccessibilityLabel(L("恢复\(label)默认快捷键"))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func restore() { reset() }
}
