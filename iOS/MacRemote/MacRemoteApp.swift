import SwiftUI

@main
struct CouchpadApp: App {
    @StateObject private var remote = RemoteConnection()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(remote)
                // Scanning the Mac's pairing QR code with the Camera app opens couchpad://pair?…
                .onOpenURL { url in
                    if let link = PairingLink(url: url) {
                        remote.pair(with: link)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { remote.resume() }
        }
    }
}
