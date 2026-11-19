import SwiftUI

struct ContentView: View {
    @EnvironmentObject var remote: RemoteConnection

    var body: some View {
        if remote.isSessionActive {
            MainView()
        } else {
            ConnectView()
        }
    }
}

/// The remote, with a banner while it reconnects.
struct MainView: View {
    @EnvironmentObject var remote: RemoteConnection

    var body: some View {
        RemoteScreen()
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
