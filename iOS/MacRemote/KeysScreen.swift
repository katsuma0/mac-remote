import SwiftUI

struct KeysScreen: View {
    @EnvironmentObject var remote: RemoteConnection
    @State private var text = ""
    @State private var pressReturn = false
    @State private var liveTyping = false
    @State private var modifiers: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private struct Key: Identifiable {
        let label: String
        let key: String
        var mods: [String] = []
        var id: String { label }
    }

    private let keys: [Key] = [
        Key(label: "esc", key: "escape"), Key(label: "tab", key: "tab"),
        Key(label: "return", key: "return"), Key(label: "space", key: "space"),
        Key(label: "⌫", key: "delete"), Key(label: "⌦", key: "forwarddelete"),
        Key(label: "home", key: "home"), Key(label: "end", key: "end"),
        Key(label: "pg up", key: "pageup"), Key(label: "pg dn", key: "pagedown"),
        Key(label: "←", key: "left"), Key(label: "↑", key: "up"),
        Key(label: "↓", key: "down"), Key(label: "→", key: "right"),
    ]

    private let shortcuts: [Key] = [
        Key(label: "Copy", key: "c", mods: ["cmd"]),
        Key(label: "Paste", key: "v", mods: ["cmd"]),
        Key(label: "Cut", key: "x", mods: ["cmd"]),
        Key(label: "Undo", key: "z", mods: ["cmd"]),
        Key(label: "Redo", key: "z", mods: ["cmd", "shift"]),
        Key(label: "Select All", key: "a", mods: ["cmd"]),
        Key(label: "Find", key: "f", mods: ["cmd"]),
        Key(label: "Spotlight", key: "space", mods: ["cmd"]),
        Key(label: "Switch App", key: "tab", mods: ["cmd"]),
        Key(label: "Mission Control", key: "up", mods: ["ctrl"]),
        Key(label: "New Tab", key: "t", mods: ["cmd"]),
        Key(label: "Close Tab", key: "w", mods: ["cmd"]),
        Key(label: "Reopen Tab", key: "t", mods: ["cmd", "shift"]),
        Key(label: "Reload", key: "r", mods: ["cmd"]),
        Key(label: "Zoom In", key: "=", mods: ["cmd"]),
        Key(label: "Zoom Out", key: "-", mods: ["cmd"]),
        Key(label: "Full Screen", key: "f", mods: ["cmd", "ctrl"]),
        Key(label: "Quit App", key: "q", mods: ["cmd"]),
        Key(label: "Lock Screen", key: "q", mods: ["cmd", "ctrl"]),
    ]

    private struct Modifier: Identifiable {
        let symbol: String
        let name: String
        var id: String { name }
    }

    private let modifierChoices: [Modifier] = [
        Modifier(symbol: "⌘", name: "cmd"), Modifier(symbol: "⌥", name: "alt"),
        Modifier(symbol: "⌃", name: "ctrl"), Modifier(symbol: "⇧", name: "shift"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Button {
                        liveTyping.toggle()
                    } label: {
                        Label(liveTyping ? "Hide keyboard" : "Type live on Mac",
                              systemImage: liveTyping ? "keyboard.chevron.compact.down" : "keyboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    GroupBox("Send text") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Type or paste text…", text: $text, axis: .vertical)
                                .lineLimit(1...6)
                                .textFieldStyle(.roundedBorder)
                            Toggle("Press Return after sending", isOn: $pressReturn)
                            Button {
                                remote.type(text)
                                if pressReturn { remote.key("return") }
                                text = ""
                            } label: {
                                Label("Send to Mac", systemImage: "paperplane.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(text.isEmpty)
                        }
                    }

                    GroupBox("Modifiers – held for the next key") {
                        HStack {
                            ForEach(modifierChoices) { mod in
                                let on = modifiers.contains(mod.name)
                                Button {
                                    if on { modifiers.remove(mod.name) } else { modifiers.insert(mod.name) }
                                } label: {
                                    Text(mod.symbol)
                                        .font(.title2)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(on ? Color.accentColor : Color.secondary)
                            }
                        }
                    }

                    GroupBox("Keys") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                            ForEach(keys) { k in
                                Button {
                                    press(k.key, k.mods)
                                } label: {
                                    Text(k.label)
                                        .font(.callout.monospaced())
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    GroupBox("Shortcuts") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
                            ForEach(shortcuts) { s in
                                Button {
                                    remote.key(s.key, s.mods)
                                } label: {
                                    Text(s.label)
                                        .font(.callout)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.never)
            .navigationTitle("Keyboard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .background(
                KeyCaptureField(isActive: $liveTyping,
                                onText: liveText,
                                onBackspace: { press("delete", []) })
                    .frame(width: 0, height: 0)
            )
        }
    }

    /// Presses a key together with any selected modifiers, then releases the modifiers.
    private func press(_ key: String, _ extra: [String]) {
        let mods = Array(modifiers.union(extra))
        remote.key(key, mods)
        modifiers.removeAll()
    }

    private func liveText(_ typed: String) {
        // With a modifier selected, a single letter becomes a shortcut (e.g. ⌘ + s).
        if !modifiers.isEmpty, typed.count == 1 {
            let lower = typed.lowercased()
            press(lower == " " ? "space" : lower, [])
        } else {
            remote.type(typed)
        }
    }
}
