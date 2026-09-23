import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasFolder = FolderAccess.hasFolder

    var body: some View {
        Group {
            if hasFolder {
                MainTabView(hasFolder: $hasFolder)
            } else {
                OnboardingView { hasFolder = true }
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
    @Binding var hasFolder: Bool
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
                SettingsView(hasFolder: $hasFolder)
            }
        }
        .task {
            importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud)
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
