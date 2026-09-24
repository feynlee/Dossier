import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// When Dossier asks for Face ID before showing anything.
///
/// - Always on a fresh launch.
/// - Always when the iPhone locks.
/// - After the app has been in the background for longer than the chosen time (1 minute by default), so a
///   quick trip to Safari to paste a number doesn't ask again.
///
/// Face ID falls back to the device passcode, so you can't be locked out of your own vault.
nonisolated enum AppLockPolicy {
    static let enabledKey = "appLockEnabled"
    static let timeoutKey = "appLockTimeoutSeconds"
    static let defaultTimeout = 60
    static let timeoutChoices = [0, 60, 300, 900]

    static func shouldLock(afterBackground elapsed: Duration, timeout: Int) -> Bool {
        elapsed >= .seconds(timeout)
    }

    static func label(for timeout: Int) -> String {
        switch timeout {
        case 0: "Immediately"
        case 60: "After 1 minute"
        default: "After \(timeout / 60) minutes"
        }
    }
}

@Observable
final class AppLock {
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    var errorMessage: String?

    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    /// Set when you cancel the prompt, so it isn't shown again until you tap Unlock.
    @ObservationIgnored private var declined = false
    @ObservationIgnored private var lockWatch: UIBackgroundTaskIdentifier = .invalid

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: AppLockPolicy.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: AppLockPolicy.enabledKey) }
    }

    var timeout: Int {
        get { UserDefaults.standard.object(forKey: AppLockPolicy.timeoutKey) as? Int ?? AppLockPolicy.defaultTimeout }
        set { UserDefaults.standard.set(newValue, forKey: AppLockPolicy.timeoutKey) }
    }

    init() {
        // A fresh launch is always locked (when there's anything to protect; see `RootView`).
        isLocked = UserDefaults.standard.object(forKey: AppLockPolicy.enabledKey) as? Bool ?? true
    }

    // MARK: Events

    func didEnterBackground() {
        backgroundedAt = .now
        watchForDeviceLock()
    }

    /// iOS reports that the iPhone locked about 10 seconds after it does, when file protection closes. Stay
    /// awake a little longer than that, so pressing the side button with Dossier open still locks it.
    private func watchForDeviceLock() {
        guard isEnabled, lockWatch == .invalid else { return }
        lockWatch = UIApplication.shared.beginBackgroundTask(withName: "Watch for iPhone lock") { [weak self] in
            self?.endLockWatch()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.endLockWatch()
        }
    }

    private func endLockWatch() {
        guard lockWatch != .invalid else { return }
        UIApplication.shared.endBackgroundTask(lockWatch)
        lockWatch = .invalid
    }

    func didBecomeActive() {
        if isEnabled, let backgroundedAt, AppLockPolicy.shouldLock(afterBackground: .now - backgroundedAt, timeout: timeout) {
            isLocked = true
            declined = false
        }
        backgroundedAt = nil
        endLockWatch()
        if isLocked, !declined, !isAuthenticating {
            Task { await unlock() }
        }
    }

    /// The iPhone locked: always lock.
    func deviceDidLock() {
        guard isEnabled else { return }
        isLocked = true
        declined = false
    }

    /// Nothing to protect yet (no documents): don't ask.
    func release() {
        isLocked = false
    }

    // MARK: Unlocking

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No Face ID and no passcode: the lock can't be enforced, so don't trap you outside the app.
            isLocked = false
            errorMessage = "Set a passcode on this iPhone to lock Dossier."
            return
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Dossier")
            isLocked = false
            errorMessage = nil
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            declined = true
        } catch {
            declined = true
            errorMessage = error.localizedDescription
        }
    }

    /// Changing lock settings needs Face ID, so someone holding your unlocked phone can't turn the lock off.
    func confirmChange(reason: String) async -> Bool {
        (try? await Authenticator.authenticate(reason: reason)) != nil
    }

    /// "Face ID", "Touch ID" or "Passcode", for button titles.
    static var methodName: String {
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

// MARK: Covering the screen

/// A window above everything else, including sheets and alerts, for the lock screen and the app-switcher
/// cover. An overlay on the root view can't cover a sheet that's open.
@MainActor
final class CoverWindow {
    static let shared = CoverWindow()
    private var window: UIWindow?

    func show(_ view: some View) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let host = UIHostingController(rootView: AnyView(view))
        host.view.backgroundColor = .clear
        if window == nil {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            self.window = window
        }
        window?.rootViewController = host
        window?.isHidden = false
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// Shown while the app is locked.
struct LockedView: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                BadgedTile(symbol: "lock.shield", badge: nil, size: 72)
                Text("Dossier is locked")
                    .font(.title2.bold())
                Text("Your documents are protected.")
                    .foregroundStyle(.secondary)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock with \(AppLock.methodName)", systemImage: AppLock.methodName == "Touch ID" ? "touchid" : "faceid")
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(lock.isAuthenticating)
                if let message = lock.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(32)
        }
        .tint(.dsTint)
    }
}

/// Shown in the app switcher, over everything.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            BadgedTile(symbol: "checkmark.shield", badge: nil, size: 64)
        }
    }
}
