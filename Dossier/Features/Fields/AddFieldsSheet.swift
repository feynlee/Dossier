import SwiftData
import SwiftUI

/// Opens right after you pick files, before anything is read. By default there's nothing to fill in: tap
/// Read. To ask for specific fields, select files and add fields for them; repeat for other files with other
/// fields, then read them all. While it's open, each file is identified on this iPhone, so it can say what it
/// is and which rule it will use.
struct AddFieldsSheet: View {
    let urls: [URL]
    /// Reads the files with what you chose. Called once, from Read or when the sheet is swiped away.
    let onRead: (_ options: [URL: ImportCoordinator.AddOptions], _ waitForCloud: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query private var documents: [SourceDocument]
    @State private var fields: [URL: ReadingFields] = [:]
    @State private var guesses: [URL: FileGuess] = [:]
    @State private var identified: Set<URL> = []
    @State private var selected: Set<URL> = []
    @State private var isEditing = false
    @State private var cloudStatus: String?
    @State private var waitForCloud = true
    @State private var didRead = false

    private var showsReadBy: Bool { usePrivateCloud && cloudStatus != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Need specific fields?").font(.title2.bold())
                        Text("By default, Dossier reads what it thinks is important in each file. To ask for specific fields, select files and add them.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }

                Section {
                    ForEach(urls, id: \.self) { url in
                        Button { toggle(url) } label: { row(url) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    Text("Fields")
                } footer: {
                    Text("Dossier identifies each file on this iPhone while you look. **Default:** what Dossier thinks is important: each kind’s standard facts, plus anything else it finds useful.")
                }

                if showsReadBy, let cloudStatus {
                    Section {
                        Label(cloudStatus, systemImage: "icloud.slash")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Read by", selection: $waitForCloud) {
                            VStack(alignment: .leading) {
                                Text("Private Cloud Compute, when it’s back")
                                Text("More accurate.").font(.footnote).foregroundStyle(.secondary)
                            }
                            .tag(true)
                            VStack(alignment: .leading) {
                                Text("This iPhone, now")
                                Text("Misses more on long files. Read again with the cloud later.").font(.footnote).foregroundStyle(.secondary)
                            }
                            .tag(false)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Read by")
                    }
                }
            }
            .navigationTitle(urls.count == 1 ? "1 File Added" : "\(urls.count) Files Added")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { buttons }
            .sheet(isPresented: $isEditing) { editor }
            .task { cloudStatus = usePrivateCloud ? DocumentExtractor.privateCloudStatus() : nil }
            .task { await identifyAll() }
            .onDisappear {
                // Swiped away: read with what's set so far, like tapping Read. The files were already chosen.
                if !didRead { read() }
            }
        }
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected.contains(url) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected.contains(url) ? Color.dsTint : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).lineLimit(1)
                HStack(spacing: 6) {
                    if let guess = guesses[url] {
                        Text(guess.label).font(.footnote).foregroundStyle(.secondary)
                    } else if !identified.contains(url) {
                        Text("Identifying…").font(.footnote).foregroundStyle(.secondary)
                    }
                    tag(for: url)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected.contains(url) ? .isSelected : [])
    }

    @ViewBuilder
    private func tag(for url: URL) -> some View {
        if let own = fields[url] {
            FieldTag(FieldRules.source(own: own, category: nil))
        } else if let guess = guesses[url] {
            FieldTag(FieldRules.source(own: nil, category: guess.category))
        } else {
            FieldTag("Category rule or default", filled: false)
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                isEditing = true
            } label: {
                Text(selected.isEmpty ? "Select Files to Add Fields" : (selected.count == 1 ? "Add Fields for 1 File" : "Add Fields for \(selected.count) Files"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(selected.isEmpty)

            Button {
                read()
            } label: {
                Text(urls.count == 1 ? "Read 1 File" : "Read \(urls.count) Files").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Checked files are waiting for their fields.
            .disabled(!selected.isEmpty)
        }
        .tint(Color.dsTint)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var editor: some View {
        let chosen = urls.filter { selected.contains($0) }
        let kinds = chosen.compactMap { guesses[$0]?.kind }
        let categories = Set(chosen.compactMap { guesses[$0]?.category })
        let existing = chosen.compactMap { fields[$0] }.first ?? ReadingFields()
        return FieldEditor(
            subtitle: chosen.count == 1 ? "Fields for 1 File" : "Fields for \(chosen.count) Files",
            kinds: kinds.count == chosen.count ? kinds : [],
            category: categories.count == 1 ? categories.first : nil,
            fields: existing,
            usedBefore: FieldRules.usedBefore(in: documents)
        ) { newFields, ruleCategory in
            for url in chosen { fields[url] = newFields }
            if let ruleCategory { FieldRules.set(newFields, for: ruleCategory) }
            selected = []
        }
    }

    private func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }

    private func identifyAll() async {
        for url in urls {
            guard !Task.isCancelled else { return }
            let guess = await FileIdentifier.identify(url: url)
            guesses[url] = guess
            identified.insert(url)
        }
    }

    private func read() {
        guard !didRead else { return }
        didRead = true
        var options: [URL: ImportCoordinator.AddOptions] = [:]
        for url in urls {
            options[url] = ImportCoordinator.AddOptions(fields: fields[url], guess: guesses[url])
        }
        onRead(options, showsReadBy && waitForCloud)
        dismiss()
    }
}
