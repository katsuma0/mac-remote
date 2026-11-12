import SwiftUI

@main
struct MacRemoteApp: App {
    @StateObject private var remote = RemoteConnection()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(remote)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { remote.resume() }
        }
    }
}
