import LocalAuthentication
import SwiftUI

/// Optional Face ID / Touch ID / passcode lock for the app (Settings → Require Face ID).
/// Someone who picks up your unlocked iPhone still can't control your Mac.
final class AppLock: ObservableObject {
    @Published private(set) var isLocked: Bool

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "requireFaceID") }

    init() {
        isLocked = AppLock.isEnabled
    }

    func lockIfEnabled() {
        if AppLock.isEnabled { isLocked = true }
    }

    func unlock() {
        guard isLocked else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on this iPhone, so there's nothing to check against.
            isLocked = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Unlock Couchpad to control your Mac") { [weak self] success, _ in
            DispatchQueue.main.async {
                if success { self?.isLocked = false }
            }
        }
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }
}

struct LockScreen: View {
    @ObservedObject var lock: AppLock

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Couchpad is locked")
                .font(.title2.weight(.semibold))
            Button {
                lock.unlock()
            } label: {
                Label("Unlock with \(AppLock.biometryName)", systemImage: "faceid")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { lock.unlock() }
    }
}
