import AppIntents
import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Environment(AppLock.self) private var appLock
    @State private var lockEnabled = true
    @State private var lockTimeout = AppLockPolicy.defaultTimeout
    @State private var privateCloudStatus: String?
    @AppStorage(ScanFolders.autoCaptureKey) private var autoCapture = true
    @AppStorage(DetailRequest.findsUsefulDetailsKey) private var findsUsefulDetails = true
    @AppStorage(KnowledgeIndexer.settingKey) private var indexKnowledge = false
    @State private var requestedSummary = ""
    @State private var autoFillEnabled = false
    @State private var scanFolder: URL?
    @State private var lastScanFolder: URL?
    @State private var isChoosingScanFolder = false
    @State private var scanFolderError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $usePrivateCloud) {
                        TileRow(symbol: "cloud", badge: nil, title: "Private Cloud Compute", subtitle: "More accurate. Pages aren’t kept.")
                    }
                    Toggle(isOn: $findsUsefulDetails) {
                        TileRow(symbol: "person.2", badge: nil, title: "Family and other details", subtitle: "Parents, spouse, children, height, employer…")
                    }
                    NavigationLink {
                        RequestedDetailsView()
                    } label: {
                        LabeledContent("Also look for", value: requestedSummary)
                    }
                    .onAppear { requestedSummary = Self.summary(DetailRequest.current.requested) }
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
                    Toggle(isOn: $autoCapture) {
                        TileRow(symbol: "camera.viewfinder", badge: nil, title: "Capture automatically", subtitle: "Takes the photo once the page is steady")
                    }
                    Menu {
                        Button("Choose Folder…", systemImage: "folder") { isChoosingScanFolder = true }
                        if scanFolder != nil {
                            Button("Use Last Folder", systemImage: "clock.arrow.circlepath") {
                                try? ScanFolders.setDefaultFolder(nil)
                                scanFolder = nil
                            }
                        }
                    } label: {
                        LabeledContent("Save scans to") {
                            Text(scanFolder.map { FolderAccess.displayPath(for: $0) } ?? "Last folder used")
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Scanning")
                } footer: {
                    if scanFolder == nil {
                        Text(lastScanFolder.map { "Scans go to the folder you saved to last (\(FolderAccess.displayPath(for: $0))). You can change the folder for each scan." }
                            ?? "Scans go to the folder you saved to last. You can change the folder for each scan; it must be in iCloud Drive.")
                    } else {
                        Text("You can still change the folder for each scan. Scan folders must be in iCloud Drive.")
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
                    TileRow(symbol: "questionmark.bubble", badge: nil, title: "Ask Dossier", subtitle: "“Ask Dossier when my lease ends”")
                    Toggle(isOn: $indexKnowledge) {
                        TileRow(symbol: "magnifyingglass", badge: nil, title: "Let Siri find facts", subtitle: "Without saying “Dossier”")
                    }
                    ShortcutsLink()
                        .shortcutsLinkStyle(.automaticOutline)
                    NavigationLink {
                        AskDossierTryView()
                    } label: {
                        TileRow(symbol: "text.bubble", badge: nil, title: "Try a question", subtitle: "See what Siri gets from Dossier")
                    }
                } header: {
                    Text("Siri")
                } footer: {
                    Text(indexKnowledge
                        ? "Dates, addresses and results are in Spotlight on this iPhone, so Siri can find them and they show in search while your iPhone is unlocked. Numbers never are."
                        : "Siri answers questions about your documents when you start with “Ask Dossier”. Numbers are only ever said as their last four characters.")
                }

                Section {
                    LabeledContent {
                        Text(autoFillEnabled ? "On" : "Off")
                    } label: {
                        TileRow(symbol: "character.cursor.ibeam", badge: nil, title: "AutoFill in other apps", subtitle: "Touch and hold a field › AutoFill › Dossier")
                    }
                    if !autoFillEnabled {
                        Button("Turn On in Settings", systemImage: "gear") { ASSettingsHelper.openCredentialProviderAppSettings() }
                    }
                } header: {
                    Text("AutoFill")
                } footer: {
                    Text("Fill a field in Safari, Chrome or any app with one of your values, after Face ID. Turn on Dossier in Settings › General › AutoFill & Passwords.")
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
            .fileImporter(isPresented: $isChoosingScanFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do {
                        try ScanFolders.setDefaultFolder(url)
                        scanFolder = url
                    } catch {
                        scanFolderError = error.localizedDescription
                    }
                case .failure(let error):
                    scanFolderError = error.localizedDescription
                }
            }
            .alert("Couldn’t use that folder", isPresented: Binding(get: { scanFolderError != nil }, set: { if !$0 { scanFolderError = nil } })) {
                Button("OK") { scanFolderError = nil }
            } message: {
                Text(scanFolderError ?? "")
            }
            .onAppear {
                ASCredentialIdentityStore.shared.getState { state in
                    Task { @MainActor in autoFillEnabled = state.isEnabled }
                }
            }
            .task {
                scanFolder = ScanFolders.defaultFolder
                lastScanFolder = ScanFolders.lastFolder
                privateCloudStatus = DocumentExtractor.privateCloudStatus()
                lockEnabled = appLock.isEnabled
                lockTimeout = appLock.timeout
            }
        }
    }

    static func summary(_ requested: [String]) -> String {
        switch requested.count {
        case 0: return "None"
        case 1, 2: return requested.joined(separator: ", ")
        default: return "\(requested.count) details"
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
