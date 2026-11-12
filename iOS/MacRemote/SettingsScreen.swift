import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var remote: RemoteConnection
    @AppStorage("pointerSpeed") private var pointerSpeed = 1.5
    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @AppStorage("invertScroll") private var invertScroll = false
    @AppStorage("haptics") private var haptics = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Connected to") {
                    Label(remote.macName, systemImage: "laptopcomputer")
                    Button("Disconnect", role: .destructive) { remote.disconnect() }
                }

                Section("Trackpad") {
                    VStack(alignment: .leading) {
                        Text("Pointer speed")
                        Slider(value: $pointerSpeed, in: 0.5...4)
                    }
                    VStack(alignment: .leading) {
                        Text("Scroll speed")
                        Slider(value: $scrollSpeed, in: 0.2...3)
                    }
                    Toggle("Reverse scroll direction", isOn: $invertScroll)
                    Toggle("Haptic feedback", isOn: $haptics)
                }

                Section {
                    Button("Forget saved PINs", role: .destructive) { remote.forgetAllPins() }
                } footer: {
                    Text("The app remembers the PIN for each Mac and reconnects automatically when it opens.")
                }

                Section("Gestures") {
                    Text("• Move one finger to move the pointer\n• Tap to click, double-tap to double-click\n• Tap with two fingers to right-click\n• Move two fingers to scroll\n• Touch and hold, then move, to drag\n• Or hold the Left button and move with another finger")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
