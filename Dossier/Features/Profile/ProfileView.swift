import LocalAuthentication
import SwiftData
import SwiftUI

/// Your personal information, compiled from all your documents. Values the documents agree on are filled in
/// automatically; you can edit any of them, and choose when documents disagree.
struct ProfileView: View {
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

    private let groups: [(String, [ProfileKey])] = [
        ("Identity", [.surname, .givenNames, .dateOfBirth, .sex, .placeOfBirth, .nationality]),
        ("Numbers", [.alienNumber, .passportNumber, .licenceNumber]),
        ("Address", [.currentAddress]),
    ]

    private func isShown(_ key: ProfileKey) -> Bool {
        guard let entry = profile.entry(key) else { return false }
        return entry.status != .missing || entry.override != nil
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { title, keys in
                let shown = keys.filter(isShown)
                // A group with nothing in it isn't shown, so no heading stands alone.
                if !shown.isEmpty {
                    Section(title) {
                        ForEach(shown, id: \.self) { key in
                            if let entry = profile.entry(key) {
                                Button { editing = key } label: {
                                    ProfileRow(entry: entry, profile: profile, unlocked: unlocked)
                                }
                                .foregroundStyle(.primary)
                            }
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

    private func detailRow(_ detail: ProfileDetails.Detail) -> some View {
        Button { edit(detail) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.label).font(.footnote).foregroundStyle(.secondary)
                    if detail.isSensitive {
                        Text(unlocked.context.flatMap { try? VaultReader.reveal(detail.fact, context: $0) } ?? VaultReader.masked(detail.fact))
                            .font(.dsFieldValue)
                    } else {
                        Text(detail.value.map { VaultReader.display($0, for: .detail) } ?? "—")
                    }
                    HStack(spacing: 4) {
                        if detail.needsReview || detail.differs {
                            Image(systemName: "questionmark.circle.fill").foregroundStyle(Color.dsBadgeNeutral)
                        }
                        Text(detail.differs ? "Documents differ · showing \(detail.fact.document?.title ?? "the newest")" : "From \(detail.sources.joined(separator: ", "))")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .foregroundStyle(.primary)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { deletingDetail = detail }
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { edit(detail) }
            Button("Delete", systemImage: "trash", role: .destructive) { deletingDetail = detail }
        }
    }

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

    var body: some View {
        HStack(spacing: 12) {
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
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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
