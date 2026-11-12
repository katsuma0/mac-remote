import SwiftUI
import UIKit

/// An invisible view that brings up the iPhone keyboard and forwards every keystroke
/// straight to the Mac (no text box – what you type appears on the Mac immediately).
final class KeyCaptureView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onResign: (() -> Void)?

    // UITextInputTraits – turn off everything that would rewrite what was typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { true }   // so backspace always works

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onBackspace?()
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }
}

struct KeyCaptureField: UIViewRepresentable {
    @Binding var isActive: Bool
    var onText: (String) -> Void
    var onBackspace: () -> Void

    func makeUIView(context: Context) -> KeyCaptureView {
        KeyCaptureView()
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        let binding = $isActive
        view.onText = onText
        view.onBackspace = onBackspace
        view.onResign = {
            DispatchQueue.main.async {
                if binding.wrappedValue { binding.wrappedValue = false }
            }
        }
        let shouldBeActive = isActive
        DispatchQueue.main.async {
            if shouldBeActive && !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if !shouldBeActive && view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }
}

/// A row of keys the iPhone keyboard doesn't have.
struct SpecialKeysBar: View {
    @EnvironmentObject var remote: RemoteConnection

    private struct BarKey: Identifiable {
        let label: String
        let key: String
        var mods: [String] = []
        var id: String { label }
    }

    private let keys: [BarKey] = [
        BarKey(label: "esc", key: "escape"),
        BarKey(label: "tab", key: "tab"),
        BarKey(label: "←", key: "left"),
        BarKey(label: "↑", key: "up"),
        BarKey(label: "↓", key: "down"),
        BarKey(label: "→", key: "right"),
        BarKey(label: "⌘C", key: "c", mods: ["cmd"]),
        BarKey(label: "⌘V", key: "v", mods: ["cmd"]),
        BarKey(label: "⌘Z", key: "z", mods: ["cmd"]),
        BarKey(label: "⌘A", key: "a", mods: ["cmd"]),
        BarKey(label: "⌘⌫", key: "delete", mods: ["cmd"]),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keys) { k in
                    Button(k.label) { remote.key(k.key, k.mods) }
                        .buttonStyle(.bordered)
                        .font(.callout.monospaced())
                }
            }
        }
    }
}
