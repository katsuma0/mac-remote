import SwiftUI

struct ContentView: View {
    @EnvironmentObject var remote: RemoteConnection

    var body: some View {
        if remote.isSessionActive {
            ControlTabs()
        } else {
            ConnectView()
        }
    }
}

struct ControlTabs: View {
    @EnvironmentObject var remote: RemoteConnection

    var body: some View {
        TabView {
            TrackpadScreen()
                .tabItem { Label("Trackpad", systemImage: "hand.point.up.left") }
            KeysScreen()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            MediaScreen()
                .tabItem { Label("Media", systemImage: "speaker.wave.2") }
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .reconnecting(let name) = remote.state {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reconnecting to \(name)…")
                        .font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.yellow.opacity(0.3))
            }
        }
    }
}
