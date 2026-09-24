import SwiftData
import SwiftUI

/// One document: the file itself above the facts read from it. Tap a fact to see where on the page it was
/// read. Facts Dossier wasn't sure about are marked, counted at the top, and can be shown on their own.
struct DocumentDetailView: View {
    let document: SourceDocument

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(ImportCoordinator.self) private var importer
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var reveal = RevealState()
    @State private var copied = false
    @State private var selected: Fact?
    @State private var onlyUncertain = false
    @State private var previewExpanded = false
    @State private var editing: Fact?
    @State private var draft = ""

    private var facts: [Fact] {
        document.facts.filter { $0.status != .superseded }.sorted { $0.key.sortOrder < $1.key.sortOrder }
    }

    private var uncertain: [Fact] { facts.filter { $0.status == .needsReview } }

    private var highlight: (page: Int, rect: CGRect)? {
        guard let selected, let rect = selected.cropRect, let page = selected.cropPage else { return nil }
        return (page, rect)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if document.bookmark != nil {
                    PreviewPane(document: document, highlight: highlight, isExpanded: $previewExpanded)
                        .frame(height: geometry.size.height * (previewExpanded ? 0.72 : 0.42))
                    Divider()
                }
                factList
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { reveal.hide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            reveal.hide()
        }
        .alert("Couldn’t reveal", isPresented: Binding(get: { reveal.error != nil }, set: { if !$0 { reveal.error = nil } })) {
            Button("OK") { reveal.error = nil }
        } message: {
            Text(reveal.error ?? "")
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
        .sensoryFeedback(.success, trigger: copied)
    }

    private var factList: some View {
        List {
            if document.state != .ready {
                Section {
                    DocumentRow(document: document)
                    if document.state == .failed {
                        Button("Try again", systemImage: "arrow.clockwise") {
                            importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                        }
                    }
                }
            }

            Section {
                ForEach(onlyUncertain ? uncertain : facts) { fact in
                    FactRow(fact: fact, reveal: reveal, isSelected: selected == fact) {
                        reveal.reveal(facts, reason: "Reveal \(fact.key.label.lowercased())")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { selected = fact } }
                    .accessibilityAddTraits(.isButton)
                    .listRowBackground(selected == fact ? Color.dsTintSoft : nil)
                    .swipeActions(edge: .leading) {
                        if fact.status == .needsReview {
                            Button("Looks right", systemImage: "checkmark") { FactEditor.confirm(fact, value: nil, context: modelContext) }
                                .tint(Color.dsTintFill)
                        }
                    }
                    .contextMenu { menu(for: fact) }
                }
            } header: {
                StatusLine(document: document, uncertainCount: uncertain.count, onlyUncertain: $onlyUncertain)
                    .textCase(nil)
            } footer: {
                if !facts.isEmpty {
                    Text("Tap a fact to see where it was read. Touch and hold to copy or edit it.")
                }
            }

            Section("Source") {
                LabeledContent("File", value: document.fileName)
                LabeledContent("Pages read", value: "\(document.pageCount)")
                LabeledContent("Read by", value: document.engine.displayName)
                Button("Read again", systemImage: "arrow.clockwise") {
                    importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for fact: Fact) -> some View {
        let value = fact.isSensitive ? reveal.value(for: fact) : VaultReader.value(of: fact)
        if fact.status == .needsReview {
            Button("Looks right", systemImage: "checkmark") { FactEditor.confirm(fact, value: nil, context: modelContext) }
        }
        if !fact.isSensitive || value != nil {
            Button("Edit", systemImage: "pencil") {
                draft = value ?? ""
                editing = fact
            }
        }
        if let value {
            Button("Copy for 60 seconds", systemImage: "doc.on.doc") {
                VaultReader.copy(value)
                copied = true
            }
        }
    }
}

/// "Verified · checked against the MRZ", or how many fields need a look with a filter.
private struct StatusLine: View {
    let document: SourceDocument
    let uncertainCount: Int
    @Binding var onlyUncertain: Bool

    var body: some View {
        HStack(spacing: 6) {
            if uncertainCount > 0 {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(Color.dsBadgeNeutral)
                Text(uncertainCount == 1 ? "1 field needs a look" : "\(uncertainCount) fields need a look")
                Spacer()
                Button(onlyUncertain ? "Show all" : "Show only these") { withAnimation { onlyUncertain.toggle() } }
                    .font(.footnote.weight(.semibold))
            } else if document.isReady {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.dsTint)
                Text("Verified · \(strongestCheck.summary)")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var strongestCheck: FactCheck {
        let checks = Set(document.facts.map(\.check))
        for check in [FactCheck.mrz, .barcode, .userConfirmed, .pageText, .model] where checks.contains(check) { return check }
        return .model
    }
}

struct FactRow: View {
    let fact: Fact
    let reveal: RevealState
    var isSelected = false
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(fact.key.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if fact.isSensitive {
                    MaskedValueView(masked: VaultReader.masked(fact), revealed: reveal.value(for: fact), onReveal: onReveal)
                } else {
                    let value = VaultReader.value(of: fact).map { VaultReader.display($0, for: fact.key) } ?? "—"
                    Text(value)
                        .font(fact.key.isMonospaced ? .dsFieldValue : .body)
                }
                if fact.status == .needsReview {
                    Label(fact.check == .conflict ? "Two readings differ" : "Not sure · compare with the document", systemImage: "questionmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.dsBadgeNeutral)
                }
            }
            Spacer(minLength: 0)
            if fact.cropRect != nil {
                Image(systemName: isSelected ? "viewfinder.circle.fill" : "viewfinder")
                    .foregroundStyle(Color.dsTint)
                    .accessibilityLabel("Show where this was read")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Confirming or correcting a fact from a document.
enum FactEditor {
    static func confirm(_ fact: Fact, value: String?, context: ModelContext) {
        if let value, !value.isEmpty {
            let normalized = Verifier.normalizedValue(value, for: fact.key)
            if let sealed = try? Sealer.shared.seal(normalized, sensitive: fact.isSensitive) { fact.sealedValue = sealed }
            if fact.isSensitive { fact.sealedHint = try? Sealer.shared.seal(String(normalized.suffix(4)), sensitive: false) }
            if let profileKey = ProfileKey.allCases.first(where: { $0.factKey == fact.key }), profileKey.isSensitive {
                fact.fingerprint = try? Sealer.shared.fingerprint(Reconciler.normalize(normalized, for: profileKey))
            }
            if fact.key.isDate, fact.key != .dateOfBirth { fact.plainDate = SimpleDate(iso: normalized)?.date }
        }
        fact.sealedAlternate = nil
        fact.status = .verified
        fact.check = .userConfirmed
        try? context.save()
    }
}
