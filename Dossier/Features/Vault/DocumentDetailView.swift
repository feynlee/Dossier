import SwiftData
import SwiftUI

/// One document: the file itself above the facts read from it. Tap a fact to see where on the page it was
/// read. Facts Dossier wasn't sure about are marked, counted at the top, and can be confirmed or corrected right
/// in their row; confirming a name or birth date here confirms the same reading on your other documents.
struct DocumentDetailView: View {
    let document: SourceDocument

    @Environment(\.modelContext) private var modelContext
    @Environment(ImportCoordinator.self) private var importer
    @Environment(AppLock.self) private var appLock
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var reveal = RevealState()
    @State private var copied = false
    @State private var selected: Fact?
    @State private var onlyUncertain = false
    /// How much of the screen the file takes: you choose with the handle, and it's remembered.
    @AppStorage("documentPreviewSize") private var previewSize = PreviewSize.medium
    /// How far the handle is being dragged, while it is.
    @State private var dragTranslation: CGFloat?
    /// The fact being edited and its current value.
    @State private var editing: (fact: Fact, value: String)?
    /// "Also confirmed on …", shown for a moment after a confirmation reaches other documents.
    @State private var sharedNote: String?
    @State private var showingMissing = false
    @State private var showingDecision = false
    @State private var removing: [SourceDocument] = []
    @State private var isPlacing = false
    @State private var isEditingPages = false
    @State private var isScanningReplacement = false
    @State private var isChoosingReplacement = false
    /// A scan waiting for you to confirm it replaces the file, or (for a photo) to choose where it's saved.
    @State private var replacementScan: [ScannedPage]?
    @State private var fileError: String?
    /// Face ID was asked for on this visit (and maybe cancelled): don't ask again until you tap Unlock.
    @State private var askedToUnlock = false

    private var facts: [Fact] {
        document.facts.filter { $0.status != .superseded }.sorted { $0.key.sortOrder < $1.key.sortOrder }
    }

    /// The document's own fields, then other details about its holder, then each family member's.
    private var mainFacts: [Fact] { facts.filter { $0.key != .detail } }
    private var holderDetails: [Fact] {
        facts.filter { $0.key == .detail && $0.section == nil && $0.relation == nil }.sorted { ($0.label ?? "") < ($1.label ?? "") }
    }

    /// What the document records, under its own section headings, in the document's order.
    private var contentGroups: [(section: String, facts: [Fact])] {
        let entries = facts.filter { $0.section != nil }.sorted { $0.position < $1.position }
        var order: [String] = []
        var grouped: [String: [Fact]] = [:]
        for fact in entries {
            let section = fact.section ?? "Other"
            if grouped[section] == nil { order.append(section) }
            grouped[section, default: []].append(fact)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private struct FamilyGroup {
        var id: String
        var title: String
        var facts: [Fact]
    }

    private var familyGroups: [FamilyGroup] {
        let details = facts.filter { $0.key == .detail && $0.section == nil && $0.relation != nil }
        let grouped = Dictionary(grouping: details) { "\($0.relationRaw ?? "")|\(($0.personName ?? "").uppercased())" }
        return grouped.map { id, facts in
            let first = facts[0]
            let name = first.personName.flatMap { $0.isEmpty ? nil : $0 }
            let title = [first.relation?.label, name].compactMap { $0 }.joined(separator: " · ")
            // Name first, then the rest alphabetically.
            let sorted = facts.sorted { a, b in
                let an = a.label?.lowercased() == "name", bn = b.label?.lowercased() == "name"
                return an != bn ? an : (a.label ?? "") < (b.label ?? "")
            }
            return FamilyGroup(id: id, title: title, facts: sorted)
        }
        .sorted { ($0.facts[0].relation?.order ?? 0, $0.title) < ($1.facts[0].relation?.order ?? 0, $1.title) }
    }

    private func shown(_ facts: [Fact]) -> [Fact] {
        onlyUncertain ? facts.filter { $0.status == .needsReview } : facts
    }

    private func factRow(_ fact: Fact) -> some View {
        FactRow(
            fact: fact, reveal: reveal, isSelected: selected == fact,
            onReveal: { reveal.reveal(facts, reason: "Unlock \(document.title)") },
            onConfirm: { confirm(fact, value: $0) },
            onEdit: { edit(fact) },
            onCopy: { copy(fact) }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) {
                selected = fact
                // Show where it was read: open the preview if you'd collapsed it.
                if previewSize == .collapsed, fact.cropRect != nil { previewSize = .medium }
            }
        }
        .accessibilityAddTraits(.isButton)
        .listRowBackground(selected == fact ? Color.dsTintSoft : nil)
        .swipeActions(edge: .leading) {
            if fact.status == .needsReview, fact.check != .conflict {
                Button("Looks Right", systemImage: "checkmark") { confirm(fact, value: nil) }
                    .tint(Color.dsTintFill)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleteField(fact) }
            Button("Edit", systemImage: "pencil") { edit(fact) }
        }
        .contextMenu { menu(for: fact) }
    }

    private var uncertain: [Fact] { facts.filter { $0.status == .needsReview } }

    private var highlight: (page: Int, rect: CGRect)? {
        guard let selected, let rect = selected.cropRect, let page = selected.cropPage else { return nil }
        return (page, rect)
    }

    var body: some View {
        GeometryReader { geometry in
            let height = previewHeight(in: geometry.size.height)
            VStack(spacing: 0) {
                if document.bookmark != nil {
                    Group {
                        if height < PreviewSize.barHeight + 30 {
                            CollapsedPreviewBar(document: document, isLocked: needsFaceID && !reveal.isUnlocked) {
                                withAnimation(.snappy) { previewSize = .medium }
                            }
                        } else {
                            PreviewPane(document: document, highlight: highlight, reveal: reveal) {
                                reveal.reveal(facts, reason: "Unlock \(document.title)")
                            }
                            .overlay(alignment: .topTrailing) {
                                Button("Hide Document", systemImage: "eye.slash") {
                                    withAnimation(.snappy) { previewSize = .collapsed }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.circle)
                                .padding(8)
                            }
                        }
                    }
                    .frame(height: height)
                    .clipped()
                    // The handle resizes the document while it's shown; hiding it is the eye button's job.
                    if previewSize != .collapsed {
                        PreviewHandle(size: $previewSize)
                            .gesture(resizeGesture(total: geometry.size.height))
                    } else {
                        Divider()
                    }
                }
                factList
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        // The file and its fields fill the screen; the tab bar would cover the end of the list.
        .toolbar(.hidden, for: .tabBar)
        // Opening a document asks for Face ID once, which shows the file and every number together. They stay
        // shown until you leave the page or Dossier locks; editing or scanning from here isn't leaving.
        .task { unlockAutomatically() }
        .onChange(of: appLock.isLocked) { _, locked in
            if locked {
                reveal.hide()
                askedToUnlock = false
            } else {
                // Just unlocked the app: that check opens the document too, without asking again.
                unlockAutomatically()
            }
        }
        .onDisappear {
            guard !isPresentingOnTop else { return }
            reveal.hide()
            askedToUnlock = false
        }
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
                    if canEditFile {
                        Button("Edit Pages", systemImage: "square.grid.2x2") { withUnlock { isEditingPages = true } }
                    }
                    replaceMenu
                    if !document.dismissedFields.isEmpty {
                        Button("Restore Deleted Fields", systemImage: "arrow.uturn.backward") {
                            document.dismissedFields = []
                            importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                        }
                    }
                    Divider()
                    Button("Remove from Vault", systemImage: "trash", role: .destructive) { removing = [document] }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .removeDocuments($removing, leavingScreen: true)
        .fullScreenCover(isPresented: $isEditingPages) { PageEditor(document: document) }
        .fullScreenCover(isPresented: $isScanningReplacement) {
            DocumentScanner(onPages: { replacementScan = $0 }, finishTitle: "Use")
        }
        .fileImporter(isPresented: $isChoosingReplacement, allowedContentTypes: FileAccess.readableTypes) { result in
            do {
                try importer.attach(try result.get(), to: document, context: modelContext, preferPrivateCloud: usePrivateCloud)
            } catch {
                fileError = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Replace \(document.fileName)?",
            isPresented: Binding(get: { replacementScan != nil && sourceIsPDF }, set: { if !$0 { replacementScan = nil } }),
            titleVisibility: .visible
        ) {
            Button(replacementScan?.count == 1 ? "Replace with 1 Page" : "Replace with \(replacementScan?.count ?? 0) Pages", role: .destructive) {
                if let pages = replacementScan { replaceFile(with: pages) }
                replacementScan = nil
            }
        } message: {
            Text("The file in iCloud Drive gets the scanned pages instead of its current ones, and Dossier reads it again.")
        }
        .sheet(isPresented: Binding(get: { replacementScan != nil && !sourceIsPDF }, set: { if !$0 { replacementScan = nil } })) {
            if let pages = replacementScan {
                SavePDFSheet(
                    title: "Save Scan",
                    previews: pages.map(\.page),
                    suggestedName: (document.fileName as NSString).deletingPathExtension,
                    makePDF: { await SaveScanSheet.makePDF(pages) }
                ) { file, folder in
                    replacementScan = nil
                    do {
                        try importer.attach(file, within: folder, to: document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                    } catch {
                        fileError = error.localizedDescription
                    }
                }
            }
        }
        .alert("Couldn’t change the file", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("OK") { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
        .sheet(isPresented: $showingMissing) { MissingSourceSheet(document: document) }
        .sheet(isPresented: $showingDecision) { DocumentDecisionSheet(document: document) }
        .sheet(isPresented: $isPlacing) { LibraryPlacementSheet(document: document) }
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
                ForEach(shown(mainFacts)) { factRow($0) }
            } header: {
                StatusLine(document: document, uncertainCount: uncertain.count, onlyUncertain: $onlyUncertain)
                    .textCase(nil)
            } footer: {
                if !facts.isEmpty {
                    Text("Tap a field to see where it was read. Confirming a name, birth date or place of birth also confirms it on your other documents.")
                }
            }

            ForEach(contentGroups, id: \.section) { group in
                if !shown(group.facts).isEmpty {
                    Section(group.section) {
                        ForEach(shown(group.facts)) { factRow($0) }
                    }
                }
            }

            if !shown(holderDetails).isEmpty {
                Section("More details") {
                    ForEach(shown(holderDetails)) { factRow($0) }
                }
            }

            ForEach(familyGroups, id: \.id) { group in
                if !shown(group.facts).isEmpty {
                    Section(group.title) {
                        ForEach(shown(group.facts)) { factRow($0) }
                    }
                }
            }

            if let placement = document.placement {
                Section {
                    LabeledContent("Name", value: placement.name)
                    LabeledContent("Folder", value: ([placement.person, placement.category, placement.folder]).joined(separator: " › "))
                    Button("Rename or Move", systemImage: "folder") { isPlacing = true }
                } header: {
                    Text("In your library")
                } footer: {
                    Text(document.placementIsYours
                        ? "You chose this name and folder, so Dossier keeps them."
                        : "Dossier chose this name and folder from what it read. Your file isn’t renamed or moved.")
                }
            }

            Section {
                LabeledContent("File", value: document.fileName)
                LabeledContent("Location", value: document.sourceMissing ? "Removed" : (document.locationDescription ?? "Unknown"))
                LabeledContent("Pages read", value: "\(document.pageCount)")
                LabeledContent("Read by", value: document.engine.displayName)
                if canEditFile {
                    Button("Edit Pages", systemImage: "square.grid.2x2") { withUnlock { isEditingPages = true } }
                }
                replaceMenu
                Button("Read again", systemImage: "arrow.clockwise") {
                    importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                }
            } header: {
                Text("Source")
            } footer: {
                Text(sourceIsPDF || !canEditFile
                    ? "Edit Pages saves your changes to the file. Replacing with a file you choose leaves the current file where it is."
                    : "This file is a photo. Editing or scanning saves a new PDF to iCloud Drive; the photo isn’t changed.")
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
        Divider()
        Button("Delete Field", systemImage: "trash", role: .destructive) { deleteField(fact) }
    }

    /// Deletes a field and remembers it, so reading the document again doesn't bring it back.
    private func deleteField(_ fact: Fact) {
        if selected == fact { selected = nil }
        let id = fact.fieldID
        if !document.dismissedFields.contains(id) { document.dismissedFields.append(id) }
        withAnimation { modelContext.delete(fact) }
        try? modelContext.save()
    }

    // MARK: Preview size

    private func previewHeight(in total: CGFloat) -> CGFloat {
        let base = previewSize.height(in: total)
        guard let dragTranslation, previewSize != .collapsed else { return base }
        return min(max(base + dragTranslation, PreviewSize.medium.height(in: total)), total * PreviewSize.maxFraction)
    }

    /// Drag the handle: the preview follows your finger and settles on the nearest size, taking the
    /// flick's speed into account.
    private func resizeGesture(total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { dragTranslation = $0.translation.height }
            .onEnded { value in
                let projected = previewSize.height(in: total) + value.predictedEndTranslation.height
                let nearest = PreviewSize.resizable.min { abs($0.height(in: total) - projected) < abs($1.height(in: total) - projected) } ?? .medium
                withAnimation(.snappy) {
                    previewSize = nearest
                    dragTranslation = nil
                }
            }
    }

    // MARK: Actions

    private var needsFaceID: Bool {
        document.facts.contains { $0.isSensitive || $0.cropRevealsNumber }
    }

    /// Something from this page is covering it (an editor, the scanner, a sheet), so it hasn't been left.
    private var isPresentingOnTop: Bool {
        isEditingPages || isScanningReplacement || isChoosingReplacement || replacementScan != nil
            || editing != nil || showingMissing || showingDecision || !removing.isEmpty
    }

    private func unlockAutomatically() {
        guard needsFaceID, !reveal.isUnlocked, !askedToUnlock, !appLock.isLocked else { return }
        #if DEBUG
        // UI tests run on simulators without Face ID, where the prompt is a passcode sheet over the app.
        if SampleVault.isRequested { return }
        #endif
        askedToUnlock = true
        reveal.reveal(facts, reason: "Unlock \(document.title)", reusing: appLock.recentUnlock())
    }

    /// The file is there to edit.
    private var canEditFile: Bool {
        document.bookmark != nil && !document.sourceMissing && [.ready, .failed].contains(document.state)
    }

    private var sourceIsPDF: Bool {
        document.bookmark.flatMap(FileAccess.resolve).map { FileAccess.isPDF($0.url) } ?? true
    }

    private var replaceMenu: some View {
        Menu {
            Button("Scan New Pages", systemImage: "doc.viewfinder") { isScanningReplacement = true }
            Button("Choose Another File", systemImage: "folder") { isChoosingReplacement = true }
        } label: {
            Label("Replace File", systemImage: "arrow.triangle.2.circlepath")
        }
    }

    /// The pages of a file that shows a number appear only after Face ID, like its preview.
    private func withUnlock(_ action: @escaping () -> Void) {
        let needsFaceID = document.facts.contains { $0.isSensitive || $0.cropRevealsNumber }
        if !needsFaceID || reveal.isUnlocked {
            action()
        } else {
            reveal.reveal(facts, reason: "Unlock \(document.title)", then: action)
        }
    }

    /// Writes a scan over the PDF in place, then reads it again.
    private func replaceFile(with pages: [ScannedPage]) {
        guard let url = document.bookmark.flatMap(FileAccess.resolve)?.url else { return }
        Task {
            guard let pdf = await SaveScanSheet.makePDF(pages) else {
                fileError = "The scan couldn’t be saved."
                return
            }
            do {
                try FileAccess.write(pdf, to: url)
                importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

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
            reveal.reveal(facts, reason: "Unlock \(document.title)") {
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
                    Text(fact.displayLabel)
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

    private var usesDatePicker: Bool {
        (fact.key.isDate && (value.isEmpty || SimpleDate(iso: value) != nil)) || (fact.key == .detail && SimpleDate(iso: value) != nil)
    }

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
                        DatePicker(fact.displayLabel, selection: $date, displayedComponents: .date)
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            // Dates are stored as calendar days at midnight UTC.
                            .environment(\.timeZone, .gmt)
                            .frame(maxWidth: .infinity)
                    } else {
                        TextField(fact.displayLabel, text: $text, axis: .vertical)
                            .font(fact.key.isMonospaced ? .dsFieldValue : .body)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text(fact.displayLabel)
                } footer: {
                    if SharedConfirmation.sharedKey(for: fact.key) != nil {
                        Text("Saving confirms it. The same value on your other documents is confirmed too.")
                    } else {
                        Text("Saving confirms it.")
                    }
                }
            }
            .navigationTitle("Edit \(fact.displayLabel)")
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

/// The sizes the document preview settles on. The fields always keep at least a quarter of the screen.
enum PreviewSize: String, CaseIterable {
    case collapsed, medium, large

    static let barHeight: CGFloat = 60
    static let maxFraction: CGFloat = 0.75
    /// The sizes the handle moves between. Hiding is done with the eye button.
    static let resizable: [PreviewSize] = [.medium, .large]

    func height(in total: CGFloat) -> CGFloat {
        switch self {
        case .collapsed: Self.barHeight
        case .medium: total * 0.42
        case .large: total * 0.72
        }
    }
}

/// The grabber between the file and its fields, while the file is shown. Drag it, or double-tap it, to make
/// the file half or large.
struct PreviewHandle: View {
    @Binding var size: PreviewSize

    var body: some View {
        Capsule()
            .fill(Color(uiColor: .tertiaryLabel))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay(alignment: .top) { Divider() }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.snappy) { size = size == .large ? .medium : .large }
            }
            .accessibilityElement()
            .accessibilityLabel("Document preview size")
            .accessibilityValue(size == .large ? "Large" : "Half")
            .accessibilityHint("Swipe up or down to change it.")
            .accessibilityAdjustableAction { direction in
                let all = PreviewSize.resizable, index = all.firstIndex(of: size) ?? 0
                withAnimation(.snappy) {
                    switch direction {
                    case .increment: size = all[min(index + 1, all.count - 1)]
                    case .decrement: size = all[max(index - 1, 0)]
                    @unknown default: break
                    }
                }
            }
    }
}

/// The file folded into one line. Tap it to show the file again.
struct CollapsedPreviewBar: View {
    let document: SourceDocument
    let isLocked: Bool
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 12) {
                Image(systemName: isLocked ? "lock.doc" : "doc.text")
                    .font(.title3)
                    .foregroundStyle(Color.dsTint)
                    .frame(width: 32, height: 36)
                    .background(Color.dsTintSoft, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(document.fileName).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                    Text(isLocked ? "Locked" : (document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Label("Show", systemImage: "eye")
                    .labelStyle(.iconOnly)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dsTint)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityLabel("Show \(document.fileName)")
    }
}
