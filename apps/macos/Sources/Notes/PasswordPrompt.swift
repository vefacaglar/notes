import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// `.mdenc` files. Declared (not as text) by `scripts/bundle.sh`; outside the bundle this is a dynamic type that
    /// still carries the extension.
    static let encryptedNote = UTType(filenameExtension: "mdenc", conformingTo: .data) ?? .data
}

/// Modal password dialogs. Secure fields in an alert's accessory view; the password never leaves the call.
@MainActor
enum PasswordPrompt {
    private static let fieldWidth: CGFloat = 260

    /// A new password, typed twice. Asks again, with a neutral note, while the two differ or are empty; `nil` when
    /// cancelled.
    static func askNew(title: String, message: String, button: String) -> String? {
        var problem: String?
        while true {
            let first = field(placeholder: L("Password"))
            let second = field(placeholder: L("Verify"))
            let alert = alert(title: title, message: [problem, message].compactMap { $0 }.joined(separator: "\n"),
                              fields: [first, second], button: button)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if first.stringValue.isEmpty {
                problem = L("The password can't be empty.")
            } else if first.stringValue != second.stringValue {
                problem = L("The passwords don't match.")
            } else {
                return first.stringValue
            }
        }
    }

    private static func field(placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: 22))
        field.placeholderString = placeholder
        return field
    }

    private static func alert(title: String, message: String, fields: [NSSecureTextField], button: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let spacing: CGFloat = 6
        let height = CGFloat(fields.count) * 22 + CGFloat(fields.count - 1) * spacing
        let box = NSView(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: height))
        for (index, field) in fields.enumerated() {
            field.frame.origin.y = height - CGFloat(index + 1) * 22 - CGFloat(index) * spacing
            box.addSubview(field)
        }
        alert.accessoryView = box
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: L("Cancel"))
        alert.layout()
        alert.window.initialFirstResponder = fields.first
        return alert
    }
}
