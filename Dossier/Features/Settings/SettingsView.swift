import SwiftUI

struct SettingsView: View {
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Environment(AppLock.self) private var appLock
    @State private var lockEnabled = true
    @State private var lockTimeout = AppLockPolicy.defaultTimeout
    @State private var privateCloudStatus: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $usePrivateCloud) {
                        TileRow(symbol: "cloud", badge: nil, title: "Private Cloud Compute", subtitle: "More accurate. Pages aren’t kept.")
                    }
                } header: {
                    Text("Reading")
                } footer: {
                    if usePrivateCloud, let privateCloudStatus {
                        Text("\(privateCloudStatus) Dossier reads on this iPhone until it’s available.")
                    } else if !usePrivateCloud {
                        Text("Reading on this iPhone is slower, and more facts will need review.")
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { lockEnabled }, set: { setLockEnabled($0) })) {
                        TileRow(symbol: "lock.shield", badge: nil, title: "Lock with \(AppLock.methodName)", subtitle: "Ask before showing anything")
                    }
                    if lockEnabled {
                        Picker("Require \(AppLock.methodName)", selection: Binding(get: { lockTimeout }, set: { setLockTimeout($0) })) {
                            ForEach(AppLockPolicy.timeoutChoices, id: \.self) { Text(AppLockPolicy.label(for: $0)).tag($0) }
                        }
                    }
                } header: {
                    Text("App lock")
                } footer: {
                    Text(lockEnabled
                        ? "Dossier always locks when it starts and when your iPhone locks. The time above is how long you can switch to another app and come back without unlocking."
                        : "Anyone who can open your unlocked iPhone can open Dossier. Numbers still need \(AppLock.methodName) to reveal.")
                }

                Section {
                    TileRow(symbol: "faceid", badge: nil, title: "Face ID for numbers", subtitle: "Document numbers are encrypted to a key that only Face ID unlocks.")
                    TileRow(symbol: "lock", badge: nil, title: "Stays on this iPhone", subtitle: "Not included in iCloud or device backups.")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Dossier has no analytics and doesn’t collect data. Your original files are never changed.")
                }
            }
            .navigationTitle("Settings")
            .task {
                privateCloudStatus = DocumentExtractor.privateCloudStatus()
                lockEnabled = appLock.isEnabled
                lockTimeout = appLock.timeout
            }
        }
    }

    /// Turning the lock off needs Face ID; turning it on doesn't.
    private func setLockEnabled(_ enabled: Bool) {
        guard !enabled else {
            appLock.isEnabled = true
            lockEnabled = true
            return
        }
        Task {
            if await appLock.confirmChange(reason: "Turn off the app lock") {
                appLock.isEnabled = false
                lockEnabled = false
            }
        }
    }

    /// A longer time is less strict, so it needs Face ID; a shorter one doesn't.
    private func setLockTimeout(_ timeout: Int) {
        guard timeout > lockTimeout else {
            appLock.timeout = timeout
            lockTimeout = timeout
            return
        }
        Task {
            if await appLock.confirmChange(reason: "Change when Dossier locks") {
                appLock.timeout = timeout
                lockTimeout = timeout
            }
        }
    }
}
