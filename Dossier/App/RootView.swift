import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppLock.self) private var lock
    /// Set once you've added your first documents. Only "Delete all extracted data" returns to onboarding.
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @Query private var documents: [SourceDocument]

    /// There's something to protect once you've added documents.
    private var isSetUp: Bool { hasOnboarded || !documents.isEmpty || FolderAccess.hasLegacyFolders }

    var body: some View {
        Group {
            // A vault with documents (or folders from an earlier version) never shows onboarding again.
            if isSetUp {
                MainTabView(hasOnboarded: $hasOnboarded)
            } else {
                OnboardingView { hasOnboarded = true }
            }
        }
        .onAppear {
            if !hasOnboarded, !documents.isEmpty || FolderAccess.hasLegacyFolders { hasOnboarded = true }
            if !isSetUp { lock.release() }
            updateCover()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: lock.didEnterBackground()
            case .active: if isSetUp { lock.didBecomeActive() }
            default: break
            }
            updateCover()
        }
        .onChange(of: lock.isLocked) { updateCover() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            // The iPhone is locking.
            if isSetUp { lock.deviceDidLock() }
        }
    }

    /// The lock screen, or in the app switcher a plain cover, in a window above everything including sheets.
    private func updateCover() {
        if lock.isLocked, isSetUp {
            CoverWindow.shared.show(LockedView(lock: lock))
        } else if scenePhase != .active {
            CoverWindow.shared.show(PrivacyCover())
        } else {
            CoverWindow.shared.hide()
        }
    }
}

struct MainTabView: View {
    @Binding var hasOnboarded: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true

    var body: some View {
        TabView {
            Tab("Vault", systemImage: "person.text.rectangle") {
                VaultView()
            }
            Tab("Timeline", systemImage: "clock") {
                TimelineView()
            }
            Tab("Forms", systemImage: "doc.text") {
                FormsView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView(hasOnboarded: $hasOnboarded)
            }
        }
        // Each time the app opens, read files that finished downloading from iCloud or changed since.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud) }
        }
    }
}

struct ComingSoonView: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Coming soon", systemImage: symbol)
            } description: {
                Text(message)
            }
            .navigationTitle(title)
        }
    }
}

enum Settings {
    static let usePrivateCloudKey = "usePrivateCloudCompute"
}
