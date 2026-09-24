import SwiftData
import SwiftUI

/// The review queue: only what Dossier couldn't settle on its own. Readings the model wasn't sure about, and
/// personal information your documents disagree on. Everything else was compiled automatically.
struct ReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Fact> { $0.statusRaw == "needsReview" }) private var pending: [Fact]
    @Query private var documents: [SourceDocument]
    @Query private var overrides: [ProfileOverride]
    @State private var reveal = RevealState()
    @State private var unlocked = UnlockState()
    @State private var profile = Profile(entries: [])
    @State private var choosing: ProfileKey?
    @State private var editing: Fact?
    @State private var draft = ""

    private var grouped: [(SourceDocument?, [Fact])] {
        Dictionary(grouping: pending.filter { $0.document?.isReady == true }, by: { $0.document?.persistentModelID })
            .map { ($0.value.first?.document, $0.value.sorted { $0.key.sortOrder < $1.key.sortOrder }) }
            .sorted { ($0.0?.title ?? "") < ($1.0?.title ?? "") }
    }

    var body: some View {
        List {
            if grouped.isEmpty, profile.conflicts.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal", description: Text("Everything was compiled from your documents."))
                    .listRowBackground(Color.clear)
            }

            if !profile.conflicts.isEmpty {
                Section {
                    ForEach(profile.conflicts) { entry in
                        Button { choosing = entry.key } label: {
                            TileRow(
                                symbol: "person.crop.circle", badge: .review, title: entry.key.label,
                                subtitle: "Documents disagree: \(entry.options.flatMap(\.sources).joined(separator: ", "))"
                            )
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Personal information")
                } footer: {
                    Text("Choose the right value once, and Dossier uses it everywhere.")
                }
            }

            if !grouped.isEmpty {
                Section {
                    if pending.contains(where: \.isSensitive), reveal.values.isEmpty {
                        Button("Reveal numbers with Face ID", systemImage: "faceid") {
                            reveal.reveal(pending, reason: "Reveal numbers to review them")
                        }
                    }
                } header: {
                    Text("Dossier wasn’t sure about these readings. Compare each with its document.")
                        .font(.body)
                        .textCase(nil)
                }
            }
            ForEach(grouped, id: \.0?.persistentModelID) { document, facts in
                Section(document?.title ?? "Document") {
                    ForEach(facts) { fact in
                        ReviewCard(fact: fact, reveal: reveal, onConfirm: { FactEditor.confirm(fact, value: $0, context: modelContext) }, onEdit: {
                            draft = currentValue(fact) ?? ""
                            editing = fact
                        })
                    }
                }
            }
        }
        .navigationTitle("Review")
        .task(id: documents.map { "\($0.persistentModelID.hashValue)\($0.stateRaw)" } + overrides.map { "\($0.keyRaw)\($0.editedAt)" } + pending.map { "\($0.persistentModelID.hashValue)" }) {
            profile = Profile.build(documents: documents, overrides: overrides)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                reveal.hide()
                unlocked.lock()
            }
        }
        .sheet(item: $choosing) { key in
            if let entry = profile.entry(key) {
                ProfileEditSheet(entry: entry, profile: profile, unlocked: unlocked)
            }
        }
        .alert("Edit \(editing?.key.label.lowercased() ?? "value")", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Value", text: $draft)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                if let editing { FactEditor.confirm(editing, value: draft, context: modelContext) }
                editing = nil
            }
        } message: {
            if editing?.key.isDate == true { Text("Use the format YYYY-MM-DD.") }
        }
    }

    private func currentValue(_ fact: Fact) -> String? {
        fact.isSensitive ? reveal.value(for: fact) : VaultReader.value(of: fact)
    }
}

private struct ReviewCard: View {
    let fact: Fact
    let reveal: RevealState
    let onConfirm: (String?) -> Void
    let onEdit: () -> Void

    @State private var choice = 0

    var body: some View {
        let value = fact.isSensitive ? reveal.value(for: fact) : VaultReader.value(of: fact)
        let alternate = fact.isSensitive ? reveal.alternate(for: fact) : VaultReader.alternate(of: fact, context: nil)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BadgedTile(symbol: fact.document?.kind.symbol ?? "doc.text", badge: .review)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fact.document?.fileName ?? "") · page \(fact.page)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(fact.key.label)
                }
            }

            if fact.check == .conflict, fact.isSensitive, value == nil {
                Text("Two readings of this number differ. Reveal numbers with Face ID to compare them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if fact.check == .conflict, let alternate {
                Text("The two readings differ. Pick the right one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                source
                Picker("Reading", selection: $choice) {
                    Text(display(value)).tag(0)
                    Text(VaultReader.display(alternate, for: fact.key)).tag(1)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .font(.dsFieldValue)
                Text(choice == 0 ? "Read by \(fact.document?.engine.displayName ?? "the model")" : (fact.document?.kind == .driversLicense ? "Licence barcode" : "Machine-readable zone"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Use \(choice == 0 ? display(value) : VaultReader.display(alternate, for: fact.key))") {
                    onConfirm(choice == 0 ? value : alternate)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(value == nil)
            } else {
                Text(display(value))
                    .font(fact.key.isMonospaced ? .dsFieldValue : .body)
                source
                Text(fact.check == .pageText ? "Found in the page text, but the model wasn’t sure of it." : "The model wasn’t sure, and it isn’t in the page text. Check it against the document.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Edit", action: onEdit)
                        .buttonStyle(.bordered)
                    Button("Confirm") { onConfirm(nil) }
                        .buttonStyle(.borderedProminent)
                        .disabled(value == nil)
                }
                .buttonBorderShape(.capsule)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    /// The strip of the page the value came from. For a sensitive value it appears only once revealed.
    @ViewBuilder
    private var source: some View {
        if let rect = fact.cropRect, let page = fact.cropPage, let document = fact.document, document.bookmark != nil,
           !fact.cropNeedsFaceID || !reveal.values.isEmpty {
            SourceCropView(bookmark: document.bookmark, fileName: document.fileName, page: page, rect: rect)
        } else if let context = VaultReader.context(of: fact) {
            Text(context)
                .font(.system(.footnote, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func display(_ value: String?) -> String {
        guard let value else { return VaultReader.masked(fact) }
        return VaultReader.display(value, for: fact.key)
    }
}
