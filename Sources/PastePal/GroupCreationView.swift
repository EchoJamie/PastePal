import PastePalLocalization
import AppKit

final class GroupCreationView: ToolbarInputSurface, NSTextFieldDelegate {
    let nameControl = NSTextField()
    private let message = NSTextField(labelWithString: "")
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var isSubmitting = false {
        didSet { nameControl.isEditable = !isSubmitting }
    }
    var errorText: String { message.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal; alignment = .centerY; spacing = 8
        edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        nameControl.isBordered = false; nameControl.drawsBackground = false
        nameControl.focusRingType = .none; nameControl.font = .systemFont(ofSize: 13)
        nameControl.textColor = PanelPalette.primaryText
        nameControl.placeholderAttributedString = NSAttributedString(string: L("输入分组名称"), attributes: [
            .foregroundColor: PanelPalette.secondaryText, .font: NSFont.systemFont(ofSize: 13)
        ])
        nameControl.delegate = self; nameControl.setAccessibilityLabel(L("新建分组名称"))
        nameControl.setAccessibilityHelp(L("输入名称后按 Return 创建，按 Esc 取消。"))
        nameControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.font = .systemFont(ofSize: 11); message.textColor = .systemRed
        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.required, for: .horizontal)
        message.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        addArrangedSubview(nameControl); addArrangedSubview(message)
        widthAnchor.constraint(equalToConstant: 430).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func focus() {
        window?.makeFirstResponder(nameControl)
        (nameControl.currentEditor() as? NSTextView)?.insertionPointColor = PanelPalette.primaryText
    }
    func showError(_ value: String) {
        message.stringValue = value; message.toolTip = value
        message.setAccessibilityLabel(value)
    }
    @objc func submit() {
        guard !isSubmitting else { return }
        onSubmit?(nameControl.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @objc func cancel() { onCancel?() }
    func controlTextDidBeginEditing(_ notification: Notification) {
        (nameControl.currentEditor() as? NSTextView)?.insertionPointColor = PanelPalette.primaryText
    }
    func controlTextDidChange(_ notification: Notification) { showError("") }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }
}
