import LocalAuthentication
import SwiftData
import SwiftUI

/// Your personal information, compiled from all your documents. Tap a value to copy it; the document button
/// beside it opens the document it comes from (or, when several show it, lets you choose one). Press and hold a
/// value, or swipe it, to edit it.
struct ProfileView: View {
    /// Opens a document, on the given field when there is one.
    var open: (SourceDocument, Fact?) -> Void = { _, _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var documents: [SourceDocument]
    @Query private var overrides: [ProfileOverride]
    @State private var profile = Profile(entries: [])
    @State private var editing: ProfileKey?
    @State private var unlocked = UnlockState()
    @State private var details = ProfileDetails(you: [], family: [])
    @State private var editingDetail: (detail: ProfileDetails.Detail, value: String)?
    @State private var deletingDetail: ProfileDetails.Detail?
    /// The row just copied: its source line reads "Copied" for a moment, under the value.
    @State private var copiedRow: String?
    /// What was copied, shown at the bottom of the screen for a moment.
    @State private var copyNote: CopyNote?
    @State private var copyCount = 0

    struct CopyNote: Equatable {
        var title: String
        /// Numbers are cleared from the clipboard after a minute.
        var clears: Bool
    }

    private let groups: [(String, [ProfileKey])] = [
        ("Identity", [.surname, .givenNames, .dateOfBirth, .sex, .placeOfBirth, .nationality]),
        ("Numbers", [.alienNumber, .passportNumber, .licenceNumber]),
        ("Address", [.currentAddress]),
    ]

    private func isShown(_ key: ProfileKey) -> Bool {
        guard let entry = profile.entry(key) else { return false }
        return entry.status != .missing || entry.override != nil
    }

    private var firstGroup: String? { groups.first { !$0.1.filter(isShown).isEmpty }?.0 }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { title, keys in
                let shown = keys.filter(isShown)
                // A group with nothing in it isn't shown, so no heading stands alone.
                if !shown.isEmpty {
                    Section {
                        ForEach(shown, id: \.self) { key in
                            if let entry = profile.entry(key) { entryRow(entry) }
                        }
                    } header: {
                        Text(title)
                    } footer: {
                        if title == firstGroup {
                            Text("Tap a value to copy it. The document button shows where it comes from.")
                        }
                    }
                }
            }
            if !details.you.isEmpty {
                Section {
                    ForEach(details.you) { detailRow($0) }
                } header: {
                    Text("More about you")
                } footer: {
                    Text("Other details your documents show, kept for filling in forms.")
                }
            }
            ForEach(Array(details.family.enumerated()), id: \.element.id) { index, person in
                Section {
                    ForEach(person.details) { detailRow($0) }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        if index == 0 {
                            Text("Family").font(.headline).foregroundStyle(.primary).textCase(nil).padding(.top, 8)
                        }
                        Text(person.title)
                    }
                }
            }
            if hasNumbers, unlocked.context == nil {
                Section {
                    Button("Reveal numbers with Face ID", systemImage: "faceid") { unlocked.unlock() }
                }
            }
        }
        .navigationTitle("Personal information")
        .task(id: documents.map { "\($0.persistentModelID.hashValue)\($0.stateRaw)" } + overrides.map { "\($0.keyRaw)\($0.editedAt)" }) {
            profile = Profile.build(documents: documents, overrides: overrides)
            details = ProfileDetails.build(documents: documents)
        }
        // Numbers stay shown until you leave this screen or the app.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { unlocked.lock() }
        }
        .onDisappear { unlocked.lock() }
        .sensoryFeedback(.success, trigger: copyCount)
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.snappy) { copiedRow = nil }
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.snappy) { copyNote = nil }
        }
        .overlay(alignment: .bottom) {
            if let copyNote {
                CopyToast(note: copyNote)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: Binding(get: { editingDetail != nil }, set: { if !$0 { editingDetail = nil } })) {
            if let editingDetail {
                FactEditSheet(fact: editingDetail.detail.fact, value: editingDetail.value) { value in
                    // The value you set applies to every document that shows this detail.
                    for fact in editingDetail.detail.facts { FactEditor.confirm(fact, value: value, context: modelContext) }
                    details = ProfileDetails.build(documents: documents)
                }
            }
        }
        .confirmationDialog(
            "Delete \(deletingDetail?.label.lowercased() ?? "this detail")?",
            isPresented: Binding(get: { deletingDetail != nil }, set: { if !$0 { deletingDetail = nil } }),
            titleVisibility: .visible,
            presenting: deletingDetail
        ) { detail in
            Button("Delete", role: .destructive) { delete(detail) }
        } message: { detail in
            Text(detail.facts.count == 1
                ? "It’s removed from \(detail.sources.first ?? "its document") and won’t be read again."
                : "It’s removed from the \(detail.facts.count) documents that show it and won’t be read again.")
        }
        .sheet(item: $editing) { key in
            if let entry = profile.entry(key) {
                ProfileEditSheet(entry: entry, profile: profile, unlocked: unlocked)
            }
        }
    }

    private var hasNumbers: Bool {
        profile.entries.contains { $0.key.isSensitive && ($0.fact != nil || $0.override != nil) }
            || details.you.contains(where: \.isSensitive)
            || details.family.contains { $0.details.contains(where: \.isSensitive) }
    }

    // MARK: Rows

    private func entryRow(_ entry: Profile.Entry) -> some View {
        let row = entry.key.rawValue
        return HStack(spacing: 4) {
            Button { tap(entry) } label: {
                ProfileRow(entry: entry, profile: profile, unlocked: unlocked, copied: copiedRow == row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .accessibilityHint(entry.needsAttention ? "Choose the right value" : "Copies the value")
            SourceButton(references: entry.references, open: open)
        }
        .listRowBackground(copiedRow == row ? Color.dsTintSoft : nil)
        .swipeActions {
            Button("Edit", systemImage: "pencil") { editing = entry.key }
                .tint(Color.dsTintFill)
        }
        .contextMenu {
            if !entry.needsAttention, entry.key.isSensitive || entry.value != nil {
                Button("Copy", systemImage: "doc.on.doc") { tap(entry) }
            }
            if entry.key.isDate, let us = entry.value.flatMap(SimpleDate.init(iso:))?.usDisplay {
                Button("Copy as \(us)", systemImage: "calendar") {
                    copy(us, row: row, label: entry.key.label, sensitive: false)
                }
            }
            SourceMenu(references: entry.references, open: open)
            Button("Edit", systemImage: "pencil") { editing = entry.key }
        }
    }

    private func detailRow(_ detail: ProfileDetails.Detail) -> some View {
        let row = "detail|\(detail.id)|\(detail.fact.persistentModelID.hashValue)"
        let references = detail.references
        return HStack(spacing: 4) {
            Button { copy(detail, row: row) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.label).font(.footnote).foregroundStyle(.secondary)
                    if detail.isSensitive {
                        Text(unlocked.context.flatMap { try? VaultReader.reveal(detail.fact, context: $0) } ?? VaultReader.masked(detail.fact))
                            .font(.dsFieldValue)
                    } else {
                        Text(detail.value.map { VaultReader.display($0, for: .detail) } ?? "—")
                    }
                    // "Copied" takes the source line's place for a moment, so the value stays in view.
                    if copiedRow == row {
                        CopiedLabel()
                    } else {
                        HStack(spacing: 4) {
                            if detail.needsReview || detail.differs {
                                Image(systemName: "questionmark.circle.fill").foregroundStyle(Color.dsBadgeNeutral)
                            }
                            Text(detail.differs ? "Documents differ · showing \(detail.fact.document?.title ?? "the newest")" : "From \(detail.sources.joined(separator: ", "))")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .accessibilityHint("Copies the value")
            SourceButton(references: references, open: open)
        }
        .listRowBackground(copiedRow == row ? Color.dsTintSoft : nil)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { deletingDetail = detail }
            Button("Edit", systemImage: "pencil") { edit(detail) }
                .tint(Color.dsTintFill)
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copy(detail, row: row) }
            if !detail.isSensitive, let us = detail.value.flatMap(SimpleDate.init(iso:))?.usDisplay {
                Button("Copy as \(us)", systemImage: "calendar") { copy(us, row: row, label: detail.label, sensitive: false) }
            }
            SourceMenu(references: references, open: open)
            Button("Edit", systemImage: "pencil") { edit(detail) }
            Button("Delete", systemImage: "trash", role: .destructive) { deletingDetail = detail }
        }
    }

    // MARK: Copying

    /// Copies the value, after Face ID for a number. A value the documents disagree on, or one Dossier
    /// doesn't have yet, opens the editor instead: there's nothing to copy.
    private func tap(_ entry: Profile.Entry) {
        let row = entry.key.rawValue
        if entry.needsAttention {
            editing = entry.key
        } else if entry.key.isSensitive {
            guard entry.fact != nil || entry.override != nil else { editing = entry.key; return }
            unlocked.unlock { context in
                if let value = profile.value(entry.key, context: context) {
                    copy(value, row: row, label: entry.key.label, sensitive: true)
                }
            }
        } else if let value = profile.value(entry.key, context: nil) {
            let shown = entry.key.isDate ? (SimpleDate(iso: value)?.display ?? value) : value
            copy(shown, row: row, label: entry.key.label, sensitive: false)
        } else {
            editing = entry.key
        }
    }

    private func copy(_ detail: ProfileDetails.Detail, row: String) {
        if detail.isSensitive {
            unlocked.unlock { context in
                if let value = try? VaultReader.reveal(detail.fact, context: context) {
                    copy(value, row: row, label: detail.label, sensitive: true)
                }
            }
        } else if let value = detail.value {
            copy(VaultReader.display(value, for: .detail), row: row, label: detail.label, sensitive: false)
        }
    }

    private func copy(_ value: String, row: String, label: String, sensitive: Bool) {
        VaultReader.copy(value, sensitive: sensitive)
        withAnimation(.snappy) {
            copiedRow = row
            copyNote = CopyNote(title: "\(label) copied", clears: sensitive)
        }
        copyCount += 1
    }

    // MARK: Editing

    private func edit(_ detail: ProfileDetails.Detail) {
        if detail.isSensitive {
            unlocked.unlock { context in
                if let value = try? VaultReader.reveal(detail.fact, context: context) { editingDetail = (detail, value) }
            }
        } else {
            editingDetail = (detail, detail.value ?? "")
        }
    }

    /// Deletes the detail from every document that shows it, so reading them again doesn't bring it back.
    private func delete(_ detail: ProfileDetails.Detail) {
        for fact in detail.facts {
            if let document = fact.document, !document.dismissedFields.contains(fact.fieldID) {
                document.dismissedFields.append(fact.fieldID)
            }
            modelContext.delete(fact)
        }
        try? modelContext.save()
        details = ProfileDetails.build(documents: documents)
    }
}

extension ProfileDetails.Detail {
    /// The documents that show this detail, one row each; those that say something else last.
    var references: [Profile.Reference] {
        var seen = Set<PersistentIdentifier>()
        let first = fact
        let firstValue = VaultReader.value(of: first).map(ProfileDetails.normalize)
        let references = facts.compactMap { fact -> Profile.Reference? in
            guard let document = fact.document, seen.insert(document.persistentModelID).inserted else { return nil }
            let agrees = fact.isSensitive
                ? (fact.fingerprint == nil || fact.fingerprint == first.fingerprint)
                : VaultReader.value(of: fact).map(ProfileDetails.normalize) == firstValue
            return Profile.Reference(document: document, fact: fact, agrees: agrees)
        }
        return references.filter(\.agrees) + references.filter { !$0.agrees }
    }
}

extension SimpleDate {
    /// "03/14/1988", the way US forms ask for a date.
    var usDisplay: String { String(format: "%02d/%02d/%04d", month, day, year) }
}

/// The document button at the end of a row: one document opens straight away; several open a menu to choose.
private struct SourceButton: View {
    let references: [Profile.Reference]
    let open: (SourceDocument, Fact?) -> Void

    var body: some View {
        if references.count == 1, let reference = references.first {
            Button { open(reference.document, reference.fact) } label: {
                chip(symbol: reference.document.kind.symbol, count: nil)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open \(reference.document.title)")
        } else if references.count > 1 {
            Menu {
                SourceMenuItems(references: references, open: open)
            } label: {
                chip(symbol: "doc.on.doc", count: references.count)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Sources: \(references.count) documents")
        }
    }

    private func chip(symbol: String, count: Int?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let count { Text("\(count)").monospacedDigit() }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Color.dsTint)
        .padding(.horizontal, 7)
        .frame(minWidth: 32, minHeight: 28)
        .background(Color.dsTintSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}

/// "Open Source" in a row's press-and-hold menu.
private struct SourceMenu: View {
    let references: [Profile.Reference]
    let open: (SourceDocument, Fact?) -> Void

    var body: some View {
        if references.count == 1, let reference = references.first {
            Button("Open \(reference.document.title)", systemImage: reference.document.kind.symbol) {
                open(reference.document, reference.fact)
            }
        } else if references.count > 1 {
            Menu("Open Source", systemImage: "doc.on.doc") {
                SourceMenuItems(references: references, open: open)
            }
        }
    }
}

/// Each document with what it says, so you can tell them apart before opening one.
private struct SourceMenuItems: View {
    let references: [Profile.Reference]
    let open: (SourceDocument, Fact?) -> Void

    var body: some View {
        let agreeing = references.filter(\.agrees), other = references.filter { !$0.agrees }
        Section(other.isEmpty ? "Open the document that shows it" : "Show this value") {
            ForEach(agreeing) { item($0) }
        }
        if !other.isEmpty {
            Section("Show something else") {
                ForEach(other) { item($0) }
            }
        }
    }

    private func item(_ reference: Profile.Reference) -> some View {
        Button { open(reference.document, reference.fact) } label: {
            Text(reference.document.title)
            if let subtitle = subtitle(reference) { Text(subtitle) }
            Image(systemName: reference.document.kind.symbol)
        }
    }

    private func subtitle(_ reference: Profile.Reference) -> String? {
        var parts: [String] = []
        if let fact = reference.fact {
            if fact.isSensitive {
                parts.append(VaultReader.masked(fact))
            } else if let value = VaultReader.value(of: fact) {
                parts.append(VaultReader.display(value, for: fact.key))
            }
        }
        if let issued = reference.document.fact(.issueDate).flatMap({ VaultReader.value(of: $0) }).flatMap(SimpleDate.init(iso:)) {
            parts.append("Issued \(issued.display)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct CopiedLabel: View {
    var body: some View {
        Label("Copied", systemImage: "checkmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.dsTint)
            .transition(.opacity)
    }
}

/// "Given names copied", for a moment at the bottom of the screen.
private struct CopyToast: View {
    let note: ProfileView.CopyNote

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.dsTint)
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title).font(.subheadline.weight(.semibold))
                if note.clears {
                    Text("Clears from the clipboard in 1 min").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

extension ProfileKey: Identifiable {
    var id: String { rawValue }
}

/// A Face ID context kept while you're on the screen, so every number can be shown after one look.
@Observable
final class UnlockState {
    private(set) var context: LAContext?
    var error: String?

    func unlock(then action: @escaping (LAContext) -> Void = { _ in }) {
        if let context {
            action(context)
            return
        }
        Task {
            do {
                let context = try await Authenticator.authenticate(reason: "Reveal your document numbers")
                self.context = context
                action(context)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func lock() {
        context = nil
    }
}

private struct ProfileRow: View {
    let entry: Profile.Entry
    let profile: Profile
    let unlocked: UnlockState
    var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.key.label).font(.footnote).foregroundStyle(.secondary)
            if entry.status == .conflict, entry.override == nil {
                Text("Choose the right value").foregroundStyle(Color.dsTint)
            } else if entry.key.isSensitive {
                Text(unlocked.context.flatMap { profile.value(entry.key, context: $0) } ?? profile.masked(entry.key) ?? "—")
                    .font(.dsFieldValue)
            } else {
                Text(display(entry.value))
                    .font(entry.key.isDate ? .dsFieldValue : .body)
            }
            // "Copied" takes the source line's place for a moment, so the value stays in view.
            if copied {
                CopiedLabel()
            } else {
                HStack(spacing: 4) {
                    if entry.needsAttention || entry.status == .uncertain {
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(Color.dsBadgeNeutral)
                    } else if entry.override == nil, case .agreed = entry.status {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.dsTint)
                    }
                    Text(entry.status.summary(sources: entry.sources, edited: entry.override != nil))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func display(_ value: String?) -> String {
        guard let value else { return "—" }
        return entry.key.isDate ? (SimpleDate(iso: value)?.display ?? value) : value
    }
}

/// Edit a value, or choose between documents that disagree.
struct ProfileEditSheet: View {
    let entry: Profile.Entry
    let profile: Profile
    let unlocked: UnlockState

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Date.now
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if !entry.options.isEmpty, entry.override == nil {
                    Section {
                        ForEach(entry.options) { option in
                            Button {
                                choose(option)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(optionValue(option)).font(entry.key.isSensitive || entry.key.isDate ? .dsFieldValue : .body)
                                    Text(option.sources.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        Text("Your documents disagree")
                    } footer: {
                        Text("Choose the value that’s right. Dossier uses it everywhere, including forms and Siri.")
                    }
                }

                Section {
                    if entry.key.isDate {
                        DatePicker(entry.key.label, selection: $date, displayedComponents: .date)
                    } else {
                        TextField(entry.key.label, text: $text, axis: .vertical)
                            .font(entry.key.isSensitive ? .dsFieldValue : .body)
                            .textInputAutocapitalization(entry.key == .currentAddress ? .words : .characters)
                    }
                } header: {
                    Text(entry.options.isEmpty ? "Value" : "Or enter it yourself")
                } footer: {
                    Text(entry.status.summary(sources: entry.sources, edited: entry.override != nil))
                }

                if entry.override != nil {
                    Section {
                        Button("Use the value from your documents", role: .destructive) {
                            try? Profile.removeOverride(for: entry.key, in: modelContext)
                            dismiss()
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Color.dsWarning)
                }
            }
            .navigationTitle(entry.key.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        if entry.key.isSensitive {
            unlocked.unlock { context in text = profile.value(entry.key, context: context) ?? "" }
        } else if entry.key.isDate {
            date = entry.value.flatMap(SimpleDate.init(iso:))?.date ?? .now
        } else {
            text = entry.value ?? ""
        }
    }

    private func optionValue(_ option: Profile.Option) -> String {
        if entry.key.isSensitive {
            return unlocked.context.flatMap { try? VaultReader.reveal(option.fact, context: $0) } ?? VaultReader.masked(option.fact)
        }
        guard let value = option.value else { return "—" }
        return entry.key.isDate ? (SimpleDate(iso: value)?.display ?? value) : value
    }

    private func choose(_ option: Profile.Option) {
        if entry.key.isSensitive {
            unlocked.unlock { context in
                guard let value = try? VaultReader.reveal(option.fact, context: context) else { return }
                save(value)
            }
        } else if let value = option.value {
            save(value)
        }
    }

    private func save() {
        let value = entry.key.isDate ? SimpleDate(date).iso : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        save(value)
    }

    private func save(_ value: String) {
        do {
            try Profile.setOverride(value, for: entry.key, in: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
