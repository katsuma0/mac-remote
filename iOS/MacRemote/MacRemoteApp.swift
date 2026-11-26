import SwiftUI

@main
struct CouchpadApp: App {
    @StateObject private var remote = RemoteConnection()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(remote)
                if lock.isLocked {
                    LockScreen(lock: lock)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
            // Scanning the Mac's pairing QR code with the Camera app opens couchpad://pair?…
            .onOpenURL { url in
                if let link = PairingLink(url: url) {
                    remote.pair(with: link)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                remote.resume()
            case .background:
                lock.lockIfEnabled()
            default:
                break
            }
        }
    }
}
