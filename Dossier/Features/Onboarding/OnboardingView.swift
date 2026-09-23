import SwiftUI
import UniformTypeIdentifiers

/// First run: explain the three promises, then pick the documents folder.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var isPickingFolder = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TileRow(symbol: "folder", badge: nil, title: "Files stay where they are", subtitle: "Read in place, never copied.")
                    TileRow(symbol: "cloud", badge: nil, title: "Private Cloud Compute", subtitle: "Pages are read by Apple’s Private Cloud Compute for accuracy. Nothing is kept.")
                    TileRow(symbol: "faceid", badge: nil, title: "Locked with Face ID", subtitle: "Numbers stay masked until you look.")
                } header: {
                    VStack(alignment: .leading, spacing: 12) {
                        BadgedTile(symbol: "checkmark.shield", badge: nil, size: 64)
                        Text("Welcome to Dossier")
                            .font(.largeTitle.bold())
                        Text("Choose the iCloud Drive folders that hold your documents. Dossier reads them and keeps what it finds on this iPhone.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 12)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.dsWarning)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        isPickingFolder = true
                    } label: {
                        Text("Choose folders")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    Text("You can add or remove folders later in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    do {
                        for url in urls { try FolderAccess.add(url) }
                        if !urls.isEmpty { onFinish() }
                    } catch {
                        errorMessage = "That folder couldn’t be opened: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    OnboardingView {}
}
