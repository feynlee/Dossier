import SwiftData
import SwiftUI

/// The review queue: extracted values become trusted facts only after you confirm them here.
struct ReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Fact> { $0.statusRaw == "needsReview" }) private var pending: [Fact]
    @State private var reveal = RevealState()
    @State private var editing: Fact?
    @State private var draft = ""

    private var grouped: [(SourceDocument?, [Fact])] {
        Dictionary(grouping: pending, by: { $0.document?.persistentModelID })
            .map { ($0.value.first?.document, $0.value.sorted { $0.key.sortOrder < $1.key.sortOrder }) }
            .sorted { ($0.0?.title ?? "") < ($1.0?.title ?? "") }
    }

    var body: some View {
        List {
            if pending.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal", description: Text("Every fact has been confirmed."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    Text("Confirm each fact before Dossier uses it.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if pending.contains(where: \.isSensitive), reveal.values.isEmpty {
                    Section {
                        Button("Reveal numbers with Face ID", systemImage: "faceid") {
                            reveal.reveal(pending, reason: "Reveal numbers to review them")
                        }
                    }
                }
            }
            ForEach(grouped, id: \.0?.persistentModelID) { document, facts in
                Section(document?.title ?? "Document") {
                    ForEach(facts) { fact in
                        ReviewCard(fact: fact, reveal: reveal, onConfirm: { confirm(fact, value: $0) }, onEdit: {
                            draft = currentValue(fact) ?? ""
                            editing = fact
                        })
                    }
                }
            }
        }
        .navigationTitle("Review")
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { reveal.hide() }
        }
        .alert("Edit \(editing?.key.label.lowercased() ?? "value")", isPresented: .constant(editing != nil)) {
            TextField("Value", text: $draft)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                if let editing { confirm(editing, value: draft) }
                editing = nil
            }
        } message: {
            if editing?.key.isDate == true { Text("Use the format YYYY-MM-DD.") }
        }
    }

    private func currentValue(_ fact: Fact) -> String? {
        fact.isSensitive ? reveal.value(for: fact) : VaultReader.value(of: fact)
    }

    /// Confirms a fact, optionally replacing its value with the user's choice or edit.
    private func confirm(_ fact: Fact, value: String?) {
        do {
            if let value, value != currentValue(fact) {
                let normalized = Verifier.normalizedValue(value, for: fact.key)
                fact.sealedValue = try Sealer.shared.seal(normalized, sensitive: fact.isSensitive)
                if fact.isSensitive { fact.sealedHint = try Sealer.shared.seal(String(normalized.suffix(4)), sensitive: false) }
                if fact.key.isDate, fact.key != .dateOfBirth { fact.plainDate = SimpleDate(iso: normalized)?.date }
            }
            fact.sealedAlternate = nil
            fact.status = .verified
            fact.check = .userConfirmed
            try modelContext.save()
        } catch {
            reveal.error = error.localizedDescription
        }
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

            if fact.check == .conflict, let alternate {
                Text("The two readings differ. Pick the right one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Reading", selection: $choice) {
                    Text(display(value)).tag(0)
                    Text(VaultReader.display(alternate, for: fact.key)).tag(1)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .font(.dsFieldValue)
                HStack {
                    Text(choice == 0 ? "Private Cloud Compute" : (fact.document?.kind == .driversLicense ? "Licence barcode" : "Machine-readable zone"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button("Use \(choice == 0 ? display(value) : VaultReader.display(alternate, for: fact.key))") {
                    onConfirm(choice == 0 ? value : alternate)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(value == nil)
            } else {
                Text(display(value))
                    .font(fact.key.isMonospaced ? .dsFieldValue : .body)
                if let context = VaultReader.context(of: fact) {
                    Text(context)
                        .font(.system(.footnote, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                Text(fact.check == .pageText ? "Found in the page text." : "Not found in the page text. Check it against the document.")
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

    private func display(_ value: String?) -> String {
        guard let value else { return VaultReader.masked(fact) }
        return VaultReader.display(value, for: fact.key)
    }
}
