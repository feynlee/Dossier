import SwiftData
import SwiftUI

@main
struct DossierApp: App {
    private let container = VaultStore.container
    @State private var importer = ImportCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(importer)
                .tint(.dsTint)
        }
        .modelContainer(container)
    }
}

/// The one vault store, shared by the app and its App Intents.
enum VaultStore {
    static let container = makeContainer()

    /// The vault store lives in Application Support with complete file protection (unreadable while the
    /// phone is locked) and is excluded from iCloud and device backups.
    private static func makeContainer() -> ModelContainer {
        var directory = URL.applicationSupportDirectory.appending(path: "Vault", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        let configuration = ModelConfiguration(url: directory.appending(path: "vault.store"))
        do {
            return try ModelContainer(for: SourceDocument.self, Fact.self, TravelEvent.self, configurations: configuration)
        } catch {
            fatalError("The vault couldn’t be opened: \(error)")
        }
    }
}
