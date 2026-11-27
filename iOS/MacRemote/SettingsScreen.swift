import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var remote: RemoteConnection
    @AppStorage("pointerSpeed") private var pointerSpeed = 1.5
    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @AppStorage("invertScroll") private var invertScroll = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("deviceName") private var deviceName = ""
    @AppStorage("requireFaceID") private var requireFaceID = false
    @State private var pairedMacs = PhonePairings.all
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connected to") {
                    Label(remote.macName, systemImage: "laptopcomputer")
                    Button("Disconnect", role: .destructive) {
                        dismiss()
                        remote.disconnect()
                    }
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
                    ForEach(pairedMacs) { mac in
                        Label(mac.name, systemImage: "laptopcomputer")
                    }
                    .onDelete { offsets in
                        for index in offsets { remote.forget(pairedMacs[index]) }
                        pairedMacs = PhonePairings.all
                    }
                    if pairedMacs.isEmpty {
                        Text("No paired Macs.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Paired Macs")
                } footer: {
                    Text("Swipe left to forget a Mac. You'll need to pair again to use it.")
                }

                Section {
                    TextField(UIDevice.current.name, text: $deviceName)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("This iPhone's name")
                } footer: {
                    Text("Shown on your Mac under Paired iPhones.")
                }

                Section("Security") {
                    Toggle("Require \(AppLock.biometryName) to open", isOn: $requireFaceID)
                    Label("Only iPhones you pair on the Mac can control it.", systemImage: "lock.shield")
                    Label("Everything you send is end-to-end encrypted.", systemImage: "lock")
                    Label("No accounts, no tracking. Nothing leaves your network.", systemImage: "hand.raised")
                }
                .font(.footnote)

                Section("Gestures") {
                    Text("• Move one finger to move the pointer\n• Tap to click, double-tap to double-click\n• Tap with two fingers to right-click\n• Move two fingers to scroll\n• Touch and hold, then move, to drag\n• Or hold the Left button and move with another finger\n• Double: double-clicks where the pointer is")
                        .font(.footnote)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
