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
                MainTabView()
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
    enum TabID { case vault, timeline, forms, settings }

    @State private var tab = TabID.vault
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true

    var body: some View {
        TabView(selection: $tab) {
            Tab("Vault", systemImage: "person.text.rectangle", value: .vault) {
                VaultView()
            }
            Tab("Timeline", systemImage: "clock", value: .timeline) {
                TimelineView()
            }
            Tab("Forms", systemImage: "doc.text", value: .forms) {
                FormsView()
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                // After removing everything, the empty vault is where you add files again.
                SettingsView { tab = .vault }
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
