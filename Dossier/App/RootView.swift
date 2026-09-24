import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// Set once you've added a first folder. Removing folders later keeps you in the app, so you can add
    /// others; only "Delete all extracted data" returns to onboarding.
    @AppStorage("hasOnboarded") private var hasOnboarded = FolderAccess.hasFolder

    var body: some View {
        Group {
            if hasOnboarded {
                MainTabView(hasOnboarded: $hasOnboarded)
            } else {
                OnboardingView { hasOnboarded = true }
            }
        }
        // Hide everything in the app switcher.
        .overlay {
            if scenePhase != .active {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    BadgedTile(symbol: "checkmark.shield", badge: nil, size: 64)
                }
                .ignoresSafeArea()
            }
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
        // Check the folders each time the app opens, so iCloud files that finished downloading while it was
        // in the background are read.
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
