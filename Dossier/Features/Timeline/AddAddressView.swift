import SwiftData
import SwiftUI

/// Fills a gap in your address history by hand. Immigration forms ask for continuous history, and not every
/// home has a lease on file.
struct AddAddressView: View {
    let gap: LifeTimeline.Gap
    let onSave: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Street, unit, city, state and ZIP code", text: $address, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                }
                Section {
                    DatePicker("Moved in", selection: $start, displayedComponents: .date)
                    DatePicker("Moved out", selection: $end, in: start..., displayedComponents: .date)
                } footer: {
                    Text("Marked as added by you. It isn’t checked against a document.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Color.dsWarning)
                }
            }
            .navigationTitle("Add address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                start = gap.start.date
                end = gap.end.date
            }
        }
    }

    private func save() {
        do {
            let line = address.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: ", ")
            let document = SourceDocument(
                contentHash: "added-\(UUID().uuidString)", fileName: "Added by you", relativePath: "",
                kind: .addedByYou, title: "Home at \(line.components(separatedBy: ",").first ?? line)",
                engine: .onDevice, pageCount: 0
            )
            modelContext.insert(document)
            let values: [(FactKey, String)] = [
                (.address, line),
                (.validFrom, SimpleDate(start).iso),
                (.validUntil, SimpleDate(end).iso),
            ]
            for (key, value) in values {
                let fact = Fact(key: key, sealedValue: try Sealer.shared.seal(value, sensitive: false), sealedHint: nil, status: .verified, check: .userConfirmed, page: 0)
                if key.isDate { fact.plainDate = SimpleDate(iso: value)?.date }
                fact.document = document
                modelContext.insert(fact)
            }
            try modelContext.save()
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
