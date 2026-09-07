import PastePalLocalization
import AppKit

private final class GroupConfirmationButton: NSButton {
    var isKeyboardTarget = false { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let bezelColor {
            let fill = isHighlighted ? bezelColor.blended(withFraction: 0.15, of: .black)! : bezelColor
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 5, yRadius: 5).fill()
            let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        } else {
            super.draw(dirtyRect)
        }
        guard isKeyboardTarget else { return }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        outline.lineWidth = 2; outline.stroke()
    }
}

final class GroupEditorController: NSViewController, NSTextFieldDelegate {
    private let actionTitle: String
    private let validateAndSubmit: (String) -> String?
    private let error = NSTextField(labelWithString: "")
    private let guidance = NSTextField(wrappingLabelWithString: L("名称为 1–40 个字符，不能与现有分组重复。"))
    private let heading = NSTextField(labelWithString: L("分组"))
    private let controls = NSStackView()
    private let confirmation = NSStackView()
    private let stack = NSStackView()
    private var confirmationButtons: [GroupConfirmationButton] = []
    private var confirmationSelection = 0
    private var finished = false
    var onClose: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onDelete: (() -> Void)?
    var closeAfterCancelDelete = false
    let nameControl = NSTextField()
    private(set) var isConfirmingDelete = false
    var errorText: String { error.stringValue }
    var headingText: String { heading.stringValue }

    init(title: String, actionTitle: String, value: String = "", validateAndSubmit: @escaping (String) -> String?) {
        self.actionTitle = actionTitle
        self.validateAndSubmit = validateAndSubmit
        super.init(nibName: nil, bundle: nil)
        self.title = title
        view = NSView()
        buildUI(value: value)
    }
    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        view.window?.makeFirstResponder(nameControl)
        (nameControl.currentEditor() as? NSTextView)?.selectAll(nil)
    }
    @objc func submit() {
        guard !isConfirmingDelete else { return }
        let name = nameControl.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = validateAndSubmit(name) {
            error.stringValue = message
            view.window?.makeFirstResponder(nameControl)
            return
        }
        close()
    }
    @objc func close() {
        guard !finished else { return }
        finished = true
        let callback = onClose
        onClose = nil
        callback?()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
    func configureManagement(canMoveUp: Bool, canMoveDown: Bool) {
        let up = button(L("前移"), #selector(moveEarlier)); up.isEnabled = canMoveUp
        let down = button(L("后移"), #selector(moveLater)); down.isEnabled = canMoveDown
        controls.addArrangedSubview(up); controls.addArrangedSubview(down)
        let delete = button(L("删除分组"), #selector(requestDelete)); delete.contentTintColor = .systemRed
        controls.addArrangedSubview(delete)
    }
    func move(offset: Int) { onMove?(offset); close() }
    @objc private func moveEarlier() { move(offset: -1) }
    @objc private func moveLater() { move(offset: 1) }
    @objc func requestDelete() {
        isConfirmingDelete = true
        heading.stringValue = L("删除分组")
        stack.alignment = .centerX; guidance.alignment = .center
        controls.isHidden = true; nameControl.isHidden = true; error.isHidden = true
        guidance.stringValue = L("删除“\(nameControl.stringValue)”及其分组归属？其他分组中的内容会保留。失去最后归属的内容恢复历史保留规则，超限时可能被清理。")
        confirmation.isHidden = false
        focusConfirmation(at: 0)
    }
    @objc func cancelDelete() {
        if closeAfterCancelDelete { close(); return }
        isConfirmingDelete = false
        heading.stringValue = title ?? L("分组")
        stack.alignment = .leading; guidance.alignment = .left
        controls.isHidden = false; nameControl.isHidden = false; error.isHidden = false
        guidance.stringValue = L("名称为 1–40 个字符，不能与现有分组重复。")
        confirmation.isHidden = true
        focus()
    }
    @objc func confirmDelete() { guard isConfirmingDelete else { return }; onDelete?(); close() }
    func handleDeleteConfirmationKey(_ event: NSEvent) -> Bool {
        guard isConfirmingDelete else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty || (event.keyCode == 48 && modifiers == .shift) else { return false }
        switch event.keyCode {
        case 48: focusConfirmation(at: (confirmationSelection + 1) % confirmationButtons.count)
        case 36, 76, 49: confirmationButtons[confirmationSelection].performClick(nil)
        case 53: cancelDelete()
        default: return false
        }
        return true
    }
    private func focusConfirmation(at index: Int) {
        confirmationSelection = index
        for (position, button) in confirmationButtons.enumerated() { button.isKeyboardTarget = position == index }
        view.window?.makeFirstResponder(confirmationButtons[index])
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }
    private func buildUI(value: String) {
        heading.stringValue = title ?? L("分组")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        guidance.font = .systemFont(ofSize: 12); guidance.textColor = .secondaryLabelColor
        nameControl.stringValue = value; nameControl.placeholderString = L("分组名称")
        nameControl.font = .systemFont(ofSize: 15); nameControl.delegate = self
        nameControl.setAccessibilityLabel(L("分组名称"))
        error.font = .systemFont(ofSize: 12); error.textColor = .systemRed
        controls.orientation = .horizontal; controls.spacing = 10
        controls.addArrangedSubview(button(actionTitle, #selector(submit)))
        controls.addArrangedSubview(button(L("返回历史"), #selector(close)))
        confirmation.orientation = .horizontal; confirmation.spacing = 10
        for (title, action) in [(L("取消"), #selector(cancelDelete)), (L("确认删除"), #selector(confirmDelete))] {
            let button = GroupConfirmationButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded; button.focusRingType = .none
            if title == L("确认删除") {
                button.bezelColor = NSColor(srgbRed: 0.72, green: 0.10, blue: 0.13, alpha: 1)
                button.contentTintColor = .white
            }
            confirmationButtons.append(button); confirmation.addArrangedSubview(button)
        }
        confirmation.isHidden = true
        [heading, guidance, nameControl, error, controls, confirmation].forEach(stack.addArrangedSubview)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        view.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            nameControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            guidance.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameControl.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
}
