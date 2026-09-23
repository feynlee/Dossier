import SwiftData
import SwiftUI

/// One document: a status line, its facts (sensitive ones masked), and where they came from.
struct DocumentDetailView: View {
    let document: SourceDocument

    @Environment(\.scenePhase) private var scenePhase
    @State private var reveal = RevealState()
    @State private var copied = false
    @State private var sourceFact: Fact?

    private var facts: [Fact] {
        document.facts.filter { $0.status != .superseded }.sorted { $0.key.sortOrder < $1.key.sortOrder }
    }

    var body: some View {
        List {
            Section {
                StatusLine(document: document)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(facts) { fact in
                    FactRow(fact: fact, reveal: reveal) {
                        reveal.reveal(facts, reason: "Reveal \(fact.key.label.lowercased())")
                    }
                    .contextMenu {
                        if fact.cropRect != nil, !document.relativePath.isEmpty, !fact.isSensitive || reveal.value(for: fact) != nil {
                            Button("Show where this was read", systemImage: "text.viewfinder") { sourceFact = fact }
                        }
                        if let value = fact.isSensitive ? reveal.value(for: fact) : VaultReader.value(of: fact) {
                            Button("Copy for 60 seconds", systemImage: "doc.on.doc") {
                                VaultReader.copy(value)
                                copied = true
                            }
                        }
                    }
                }
            }

            Section("Source") {
                LabeledContent("File", value: document.fileName)
                LabeledContent("Pages read", value: "\(document.pageCount)")
                LabeledContent("Read by", value: document.engine.displayName)
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { reveal.hide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            reveal.hide()
        }
        .alert("Couldn’t reveal", isPresented: .constant(reveal.error != nil)) {
            Button("OK") { reveal.error = nil }
        } message: {
            Text(reveal.error ?? "")
        }
        .sensoryFeedback(.success, trigger: copied)
        .sheet(item: $sourceFact) { fact in
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    if let rect = fact.cropRect, let page = fact.cropPage {
                        SourceCropView(relativePath: document.relativePath, page: page, rect: rect)
                    }
                    Text("\(document.fileName) · page \(fact.cropPage ?? fact.page)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
                .navigationTitle(fact.key.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sourceFact = nil } } }
            }
            .presentationDetents([.medium])
        }
    }
}

/// "Verified · checked against the MRZ", with a seal in the tint.
private struct StatusLine: View {
    let document: SourceDocument

    var body: some View {
        let pending = document.facts.filter { $0.status == .needsReview }.count
        HStack(spacing: 6) {
            if pending > 0 {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(Color.dsBadgeNeutral)
                Text(pending == 1 ? "1 fact to review" : "\(pending) facts to review")
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.dsTint)
                Text("Verified · \(strongestCheck.summary)")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var strongestCheck: FactCheck {
        let checks = Set(document.facts.map(\.check))
        for check in [FactCheck.mrz, .barcode, .userConfirmed, .pageText] where checks.contains(check) { return check }
        return .userConfirmed
    }
}

struct FactRow: View {
    let fact: Fact
    let reveal: RevealState
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(fact.key.label)
                if fact.status == .needsReview {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(Color.dsBadgeNeutral)
                        .accessibilityLabel("Needs review")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if fact.isSensitive {
                MaskedValueView(masked: VaultReader.masked(fact), revealed: reveal.value(for: fact), onReveal: onReveal)
            } else {
                let value = VaultReader.value(of: fact).map { VaultReader.display($0, for: fact.key) } ?? "—"
                Text(value)
                    .font(fact.key.isMonospaced ? .dsFieldValue : .body)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
