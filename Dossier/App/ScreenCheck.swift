import LocalAuthentication
import SwiftUI

/// "Face ID for each screen" in Settings. Off (the default): numbers show everywhere once Dossier is unlocked.
/// On: Dossier also asks for Face ID each time you open the Personal tab, bring a Key document forward, or open
/// a document. Numbers always show in full; this only adds a check before those screens.
enum ScreenCheck {
    static let settingKey = "faceIDEachScreen"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// True when the screen can open: the setting is off, or a new Face ID check passed. A check that passed
    /// also opens numbers until Dossier locks.
    static func pass(reason: String) async -> Bool {
        guard isOn else { return true }
        guard let context = try? await Authenticator.authenticate(reason: reason, fresh: true) else { return false }
        VaultSession.shared.begin(context)
        return true
    }
}

/// Hides a screen behind a Face ID check each time it appears, when "Face ID for each screen" is on.
private struct ScreenCheckGate: ViewModifier {
    let reason: String

    @AppStorage(ScreenCheck.settingKey) private var isOn = false
    @State private var passed = false
    @State private var isChecking = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isOn, !passed {
                    ZStack {
                        Color(.systemGroupedBackground).ignoresSafeArea()
                        ContentUnavailableView {
                            Label("Locked", systemImage: "faceid")
                        } description: {
                            Text("Use \(AppLock.methodName) to see this screen.")
                        } actions: {
                            Button("Unlock") { Task { await check() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(isChecking)
                        }
                    }
                    .accessibilityIdentifier("screen locked")
                }
            }
            .onAppear { Task { await check() } }
            .onDisappear { passed = false }
    }

    private func check() async {
        guard isOn else { passed = true; return }
        guard !passed, !isChecking else { return }
        isChecking = true
        passed = await ScreenCheck.pass(reason: reason)
        isChecking = false
    }
}

extension View {
    /// Asks for Face ID before this screen shows, each time it appears, when "Face ID for each screen" is on.
    func screenCheck(reason: String) -> some View {
        modifier(ScreenCheckGate(reason: reason))
    }
}
