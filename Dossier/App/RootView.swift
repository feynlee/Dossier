import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppLock.self) private var lock
    /// Set once you've added your first documents. Only "Delete all extracted data" returns to onboarding.
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @Query private var documents: [SourceDocument]
    @State private var incoming = IncomingFiles()

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
        // Files sent from other apps are handled once Dossier is unlocked.
        .modifier(IncomingFilesModifier(incoming: incoming, isLocked: lock.isLocked && isSetUp))
        .environment(incoming)
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
        } else if scenePhase == .background || (scenePhase == .inactive && !Authenticator.isPrompting && !lock.isAuthenticating) {
            CoverWindow.shared.show(PrivacyCover())
        } else {
            CoverWindow.shared.hide()
        }
    }
}

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query private var documents: [SourceDocument]
    @Query private var overrides: [ProfileOverride]

    /// Changes whenever something AutoFill offers could have changed.
    private var autoFillSignature: [String] {
        documents.map { "\($0.contentHash)\($0.stateRaw)\($0.facts.count)\($0.facts.filter { $0.status == .verified }.count)\($0.dismissedFields.count)" }
            + overrides.map { "\($0.keyRaw)\($0.editedAt.timeIntervalSince1970)" }
    }

    /// Changes whenever what the Dossier location in Files shows could have changed.
    private var librarySignature: [String] {
        documents.map { document in
            let place = document.placement.map { "\($0.person)/\($0.category)/\($0.folder)/\($0.name)" } ?? ""
            return "\(document.contentHash)\(document.stateRaw)\(place)\(document.fileName)\(document.fileModifiedAt?.timeIntervalSince1970 ?? 0)"
        }
    }

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
                SettingsView()
            }
        }
        // Each time the app opens, read files that finished downloading from iCloud or changed since.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud) }
        }
        // Keep AutoFill's sealed copy of your values up to date for other apps.
        .task(id: autoFillSignature) {
            try? await Task.sleep(for: .seconds(1))
            AutoFillStore.save(FormCatalog.build(documents: documents, overrides: overrides).entries)
        }
        // Keep the Dossier location in Files showing the library as it is now.
        .task(id: librarySignature) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await LibraryPublisher.publish(LibraryPublisher.sources(documents))
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
