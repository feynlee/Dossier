import LocalAuthentication
import SwiftUI

/// Your values, grouped as in Dossier, after Face ID. Numbers stay masked in the list and are opened only
/// when you pick one.
struct AutoFillPicker: View {
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @State private var context: LAContext?
    @State private var snapshot: AutoFillStore.Snapshot?
    @State private var search = ""
    @State private var failed: String?

    private var groups: [(name: String, entries: [FormEntry])] {
        let entries = (snapshot?.entries ?? []).filter { entry in
            search.isEmpty || entry.label.localizedCaseInsensitiveContains(search) || entry.group.localizedCaseInsensitiveContains(search)
                || (!entry.isSensitive && (value(of: entry)?.localizedCaseInsensitiveContains(search) ?? false))
        }
        var order: [String] = []
        var grouped: [String: [FormEntry]] = [:]
        for entry in entries {
            if grouped[entry.group] == nil { order.append(entry.group) }
            grouped[entry.group, default: []].append(entry)
        }
        return order.map { ($0, grouped[$0]!) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if context == nil {
                    ContentUnavailableView {
                        Label("Dossier is locked", systemImage: "lock.shield")
                    } description: {
                        Text(failed ?? "Unlock to choose a value.")
                    } actions: {
                        Button("Unlock", systemImage: "faceid") { Task { await unlock() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if snapshot?.entries.isEmpty ?? true {
                    ContentUnavailableView("Nothing to fill yet", systemImage: "doc.text", description: Text("Open Dossier and add your documents. AutoFill offers what Dossier reads from them."))
                } else {
                    List {
                        ForEach(groups, id: \.name) { group in
                            Section(group.name) {
                                ForEach(group.entries) { entry in
                                    Button { pick(entry) } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.label).font(.footnote).foregroundStyle(.secondary)
                                            Text(display(entry)).foregroundStyle(.primary)
                                                .font(entry.isSensitive || entry.kind == .date ? .body.monospaced() : .body)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .searchable(text: $search, prompt: "Search your values")
                }
            }
            .navigationTitle("Dossier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
        }
        .tint(Color(red: 0x4B / 255, green: 0x45 / 255, blue: 0xC6 / 255))
        .task { await unlock() }
    }

    private func unlock() async {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Choose a value from Dossier")
            snapshot = AutoFillStore.load()
            self.context = context
        } catch {
            failed = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
        }
    }

    private func value(of entry: FormEntry) -> String? {
        entry.isSensitive ? nil : try? Sealer.shared.open(entry.sealed)
    }

    /// Dates as "12 Aug 1990"; numbers masked.
    private func display(_ entry: FormEntry) -> String {
        if entry.isSensitive { return entry.masked ?? "•••• ••" }
        guard let value = value(of: entry) else { return "—" }
        if entry.kind == .date, let date = ISO8601DateFormatter.dateOnly.date(from: value) {
            return date.formatted(.dateTime.day().month(.abbreviated).year())
        }
        return value
    }

    /// Inserts the value: dates as MM/DD/YYYY, which most forms in the US expect.
    private func pick(_ entry: FormEntry) {
        Task {
            var text: String?
            if entry.isSensitive {
                if let context { text = try? Sealer.shared.openSensitive(entry.sealed, context: context) }
                // A passcode unlock can't open Face ID–protected numbers: ask for Face ID itself.
                if text == nil, let biometric = try? await Authenticator.authenticate(reason: "Insert \(entry.label.lowercased())") {
                    text = try? Sealer.shared.openSensitive(entry.sealed, context: biometric)
                }
            } else {
                text = value(of: entry)
            }
            guard var text else { return }
            if entry.kind == .date, let date = ISO8601DateFormatter.dateOnly.date(from: text) {
                let parts = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: date)
                text = String(format: "%02d/%02d/%04d", parts.month ?? 1, parts.day ?? 1, parts.year ?? 2000)
            }
            onPick(text)
        }
    }
}

extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .gmt
        return formatter
    }()
}
