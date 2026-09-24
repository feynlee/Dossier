import SwiftData
import SwiftUI

/// One document: the file itself above the facts read from it. Tap a fact to see where on the page it was
/// read. Facts Dossier wasn't sure about are marked, counted at the top, and can be confirmed or corrected right
/// in their row; confirming a name or birth date here confirms the same reading on your other documents.
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
    /// The fact being edited and its current value.
    @State private var editing: (fact: Fact, value: String)?
    /// "Also confirmed on …", shown for a moment after a confirmation reaches other documents.
    @State private var sharedNote: String?
    @State private var showingMissing = false
    @State private var showingDecision = false
    @State private var removing: [SourceDocument] = []

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
                    PreviewPane(document: document, highlight: highlight, isExpanded: $previewExpanded, reveal: reveal) {
                        reveal.reveal(facts, reason: "Show this document")
                    }
                        .frame(height: geometry.size.height * (previewExpanded ? 0.72 : 0.42))
                    Divider()
                }
                factList
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        // One Face ID shows the file and every number on this screen. They're hidden again when you leave
        // the screen or the app, not while you're here (the Face ID prompt itself doesn't count as leaving).
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { reveal.hide() }
        }
        .onDisappear { reveal.hide() }
        .alert("Couldn’t reveal", isPresented: Binding(get: { reveal.error != nil }, set: { if !$0 { reveal.error = nil } })) {
            Button("OK") { reveal.error = nil }
        } message: {
            Text(reveal.error ?? "")
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing {
                FactEditSheet(fact: editing.fact, value: editing.value, showsCrop: !editing.fact.cropNeedsFaceID || reveal.value(for: editing.fact) != nil) {
                    confirm(editing.fact, value: $0)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let sharedNote {
                Label(sharedNote, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { self.sharedNote = nil }
                    }
            }
        }
        .sensoryFeedback(.success, trigger: copied)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Read Again", systemImage: "arrow.clockwise") {
                        importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                    }
                    Divider()
                    Button("Remove from Vault", systemImage: "trash", role: .destructive) { removing = [document] }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .removeDocuments($removing, leavingScreen: true)
        .sheet(isPresented: $showingMissing) { MissingSourceSheet(document: document) }
        .sheet(isPresented: $showingDecision) { DocumentDecisionSheet(document: document) }
    }

    private var factList: some View {
        List {
            if document.state != .ready || document.sourceMissing {
                Section {
                    DocumentRow(document: document)
                    if document.state == .failed {
                        Button("Try again", systemImage: "arrow.clockwise") {
                            importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                        }
                    }
                    if document.state == .awaitingDecision {
                        Button(document.decision == .duplicate ? "Choose which file to keep" : "Review the update", systemImage: "arrow.left.arrow.right") {
                            showingDecision = true
                        }
                    } else if document.sourceMissing {
                        Button("Attach a new file", systemImage: "paperclip") { showingMissing = true }
                    }
                }
            }

            Section {
                ForEach(onlyUncertain ? uncertain : facts) { fact in
                    FactRow(
                        fact: fact, reveal: reveal, isSelected: selected == fact,
                        onReveal: { reveal.reveal(facts, reason: "Reveal \(fact.key.label.lowercased())") },
                        onConfirm: { confirm(fact, value: $0) },
                        onEdit: { edit(fact) },
                        onCopy: { copy(fact) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { selected = fact } }
                    .accessibilityAddTraits(.isButton)
                    .listRowBackground(selected == fact ? Color.dsTintSoft : nil)
                    .swipeActions(edge: .leading) {
                        if fact.status == .needsReview, fact.check != .conflict {
                            Button("Looks Right", systemImage: "checkmark") { confirm(fact, value: nil) }
                                .tint(Color.dsTintFill)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Edit", systemImage: "pencil") { edit(fact) }
                    }
                    .contextMenu { menu(for: fact) }
                }
            } header: {
                StatusLine(document: document, uncertainCount: uncertain.count, onlyUncertain: $onlyUncertain)
                    .textCase(nil)
            } footer: {
                if !facts.isEmpty {
                    Text("Tap a field to see where it was read. Confirming a name, birth date or place of birth also confirms it on your other documents.")
                }
            }

            Section("Source") {
                LabeledContent("File", value: document.fileName)
                LabeledContent("Location", value: document.sourceMissing ? "Removed" : (document.locationDescription ?? "Unknown"))
                LabeledContent("Pages read", value: "\(document.pageCount)")
                LabeledContent("Read by", value: document.engine.displayName)
                Button("Read again", systemImage: "arrow.clockwise") {
                    importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                }
            }

            Section {
                Button("Remove from Vault", role: .destructive) { removing = [document] }
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("Dossier forgets what it read from this file. The file itself isn’t deleted.")
            }
        }
    }

    @ViewBuilder
    private func menu(for fact: Fact) -> some View {
        if fact.status == .needsReview, fact.check != .conflict {
            Button("Looks Right", systemImage: "checkmark") { confirm(fact, value: nil) }
        }
        Button("Edit", systemImage: "pencil") { edit(fact) }
        if !fact.isSensitive || reveal.value(for: fact) != nil {
            Button("Copy for 60 Seconds", systemImage: "doc.on.doc") { copy(fact) }
        }
    }

    // MARK: Actions

    private func confirm(_ fact: Fact, value: String?) {
        let others = FactEditor.confirm(fact, value: value, context: modelContext)
        guard !others.isEmpty else { return }
        withAnimation {
            sharedNote = others.count == 1 ? "Also confirmed on \(others[0])" : "Also confirmed on \(others.count) other documents"
        }
    }

    /// Numbers are revealed with Face ID before they can be edited.
    private func edit(_ fact: Fact) {
        if !fact.isSensitive {
            editing = (fact, VaultReader.value(of: fact) ?? "")
        } else if let value = reveal.value(for: fact) {
            editing = (fact, value)
        } else {
            reveal.reveal(facts, reason: "Edit \(fact.key.label.lowercased())") {
                if let value = reveal.value(for: fact) { editing = (fact, value) }
            }
        }
    }

    private func copy(_ fact: Fact) {
        guard let value = fact.isSensitive ? reveal.value(for: fact) : VaultReader.value(of: fact) else { return }
        VaultReader.copy(value)
        copied = true
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
    var onConfirm: ((String?) -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?

    private var value: String? { fact.isSensitive ? reveal.value(for: fact) : VaultReader.value(of: fact) }
    private var alternate: String? { fact.isSensitive ? reveal.alternate(for: fact) : VaultReader.alternate(of: fact, context: nil) }
    private var isConflict: Bool { fact.status == .needsReview && fact.check == .conflict }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.key.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if fact.isSensitive {
                        MaskedValueView(masked: VaultReader.masked(fact), revealed: reveal.value(for: fact), onReveal: onReveal)
                    } else if !isConflict {
                        Text(value.map { VaultReader.display($0, for: fact.key) } ?? "—")
                            .font(fact.key.isMonospaced ? .dsFieldValue : .body)
                    }
                    status
                }
                Spacer(minLength: 0)
                if fact.cropRect != nil {
                    Image(systemName: isSelected ? "viewfinder.circle.fill" : "viewfinder")
                        .foregroundStyle(Color.dsTint)
                        .accessibilityLabel("Show where this was read")
                }
            }
            actions
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var status: some View {
        if isConflict {
            Label("Two readings differ. Which is right?", systemImage: "questionmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.dsBadgeNeutral)
        } else if fact.status == .needsReview {
            Label("Not sure · compare with the document", systemImage: "questionmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.dsBadgeNeutral)
        } else if fact.check == .userConfirmed {
            Label("Confirmed", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Buttons in the row: always for a field that needs a look, and for the selected field.
    @ViewBuilder
    private var actions: some View {
        if isConflict, let onConfirm {
            if let value, let alternate {
                VStack(spacing: 8) {
                    choice(value, source: "Read from the page", onConfirm: onConfirm)
                    choice(alternate, source: fact.document?.kind == .driversLicense ? "From the licence barcode" : "From the machine-readable zone", onConfirm: onConfirm)
                }
            } else {
                Button("Reveal Both Readings", systemImage: "faceid", action: onReveal)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        } else if fact.status == .needsReview, let onConfirm, let onEdit {
            HStack(spacing: 8) {
                Button("Edit", systemImage: "pencil", action: onEdit)
                    .buttonStyle(.bordered)
                Button("Looks Right", systemImage: "checkmark") { onConfirm(nil) }
                    .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        } else if isSelected, let onEdit {
            HStack(spacing: 8) {
                Button("Edit", systemImage: "pencil", action: onEdit)
                if let onCopy, value != nil {
                    Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
    }

    private func choice(_ reading: String, source: String, onConfirm: @escaping (String?) -> Void) -> some View {
        Button {
            onConfirm(reading)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(VaultReader.display(reading, for: fact.key))
                    .font(fact.key.isMonospaced ? .dsFieldValue : .body)
                    .foregroundStyle(.primary)
                Text(source).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
    }
}

/// Correcting a value. Dates get a date picker; the line it was read from is shown for comparison.
struct FactEditSheet: View {
    let fact: Fact
    let value: String
    var showsCrop = true
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Date.now

    private var usesDatePicker: Bool { fact.key.isDate && (value.isEmpty || SimpleDate(iso: value) != nil) }

    var body: some View {
        NavigationStack {
            Form {
                if showsCrop, let rect = fact.cropRect, let page = fact.cropPage, let document = fact.document, document.bookmark != nil {
                    Section("On the document") {
                        SourceCropView(bookmark: document.bookmark, fileName: document.fileName, page: page, rect: rect)
                    }
                }
                Section {
                    if usesDatePicker {
                        DatePicker(fact.key.label, selection: $date, displayedComponents: .date)
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            // Dates are stored as calendar days at midnight UTC.
                            .environment(\.timeZone, .gmt)
                            .frame(maxWidth: .infinity)
                    } else {
                        TextField(fact.key.label, text: $text, axis: .vertical)
                            .font(fact.key.isMonospaced ? .dsFieldValue : .body)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text(fact.key.label)
                } footer: {
                    if SharedConfirmation.sharedKey(for: fact.key) != nil {
                        Text("Saving confirms it. The same value on your other documents is confirmed too.")
                    } else {
                        Text("Saving confirms it.")
                    }
                }
            }
            .navigationTitle("Edit \(fact.key.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(usesDatePicker ? SimpleDate(utc: date).iso : text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(!usesDatePicker && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                text = value
                if let parsed = SimpleDate(iso: value) { date = parsed.date }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Confirming or correcting a fact from a document.
enum FactEditor {
    /// Confirms a fact, correcting it to `value` when given, then confirms the same reading on your other
    /// documents. Returns the titles of the documents that were also confirmed.
    @discardableResult
    static func confirm(_ fact: Fact, value: String?, context: ModelContext) -> [String] {
        if let value, !value.isEmpty {
            let normalized = Verifier.normalizedValue(value, for: fact.key)
            if let sealed = try? Sealer.shared.seal(normalized, sensitive: fact.isSensitive) { fact.sealedValue = sealed }
            if fact.isSensitive { fact.sealedHint = try? Sealer.shared.seal(String(normalized.suffix(4)), sensitive: false) }
            if let profileKey = ProfileKey.allCases.first(where: { $0.factKey == fact.key }), profileKey.isSensitive {
                fact.fingerprint = try? Sealer.shared.fingerprint(Reconciler.normalize(normalized, for: profileKey))
            }
            if fact.key.isDate, fact.key != .dateOfBirth { fact.plainDate = SimpleDate(iso: normalized)?.date }
        }
        markConfirmed(fact)
        try? context.save()
        return SharedConfirmation.share(from: fact, context: context)
    }

    static func markConfirmed(_ fact: Fact) {
        fact.sealedAlternate = nil
        fact.status = .verified
        fact.check = .userConfirmed
    }
}
