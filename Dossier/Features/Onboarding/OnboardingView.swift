import SwiftUI
import UniformTypeIdentifiers

/// First run: explain the three promises, then add the documents to read.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var isPicking = false
    @State private var folder: URL?
    @State private var isScanning = false

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
                        Text("Add your passport, cards, leases and notices from iCloud Drive or this iPhone. Dossier reads only the files you add, and keeps what it finds on this iPhone.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 12)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        isScanning = true
                    } label: {
                        Label("Scan Documents", systemImage: "doc.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    Button("Choose Files") { isPicking = true }
                        .font(.headline)
                        .padding(.vertical, 4)
                }
                .padding()
            }
            .chooseFromFolder(isPresented: $isPicking, folder: $folder, onAdded: onFinish)
            .fullScreenCover(isPresented: $isScanning) { DocumentScanner(onSaved: onFinish) }
        }
    }
}

#Preview {
    OnboardingView {}
}
