import LocalAuthentication
import SwiftData
import SwiftUI
import WebKit

/// Choosing a website to fill: common applications, recent sites, or any address.
struct WebFillStart: View {
    @State private var address = ""
    @State private var opening: WebFillTarget?
    @State private var recent = WebFillHistory.recent
    @State private var confirmClear = false

    static let applications: [(name: String, detail: String, url: String)] = [
        ("US visa (DS-160)", "ceac.state.gov", "https://ceac.state.gov/genniv/"),
        ("ESTA", "esta.cbp.dhs.gov", "https://esta.cbp.dhs.gov/"),
        ("USCIS online account", "my.uscis.gov", "https://my.uscis.gov/"),
        ("US passport renewal", "travel.state.gov", "https://travel.state.gov/content/travel/en/passports/have-passport/renew-online.html"),
        ("I-94 records", "i94.cbp.dhs.gov", "https://i94.cbp.dhs.gov/"),
        ("Canada eTA", "canada.ca", "https://www.canada.ca/en/immigration-refugees-citizenship/services/visit-canada/eta/apply.html"),
        ("UK ETA", "gov.uk", "https://www.gov.uk/guidance/apply-for-an-electronic-travel-authorisation-eta"),
    ]

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Website address", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(openAddress)
                    if !address.isEmpty {
                        Button("Open", action: openAddress).fontWeight(.semibold)
                    }
                }
            } footer: {
                Text("Open an application and sign in as usual. On each page, tap Fill: Dossier shows what it will enter before anything is written, and never submits for you.")
            }

            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent, id: \.self) { url in
                        Button { opening = WebFillTarget(url: url) } label: {
                            Label(url.host() ?? url.absoluteString, systemImage: "clock")
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            Section("Applications") {
                ForEach(Self.applications, id: \.url) { app in
                    Button { opening = URL(string: app.url).map(WebFillTarget.init) } label: {
                        TileRow(symbol: "globe", badge: nil, title: app.name, subtitle: app.detail)
                    }
                    .foregroundStyle(.primary)
                }
            }

            Section {
                Button("Clear Website Data", role: .destructive) { confirmClear = true }
            } footer: {
                Text("Sign-ins and cookies from sites you open here stay in Dossier, separate from Safari. Only field labels are sent to Private Cloud Compute to match fields; your values never are.")
            }
        }
        .navigationTitle("Fill a Website")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recent = WebFillHistory.recent }
        .fullScreenCover(item: $opening) { target in
            WebFillView(start: target.url)
        }
        .confirmationDialog("Clear website data?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Website Data", role: .destructive) {
                Task { await WebFillSession.clearWebsiteData() }
                WebFillHistory.clear()
                FormMemory.forgetAll()
                recent = []
            }
        } message: {
            Text("You’ll be signed out of sites opened in Dossier, and the fields Dossier learned on them are forgotten.")
        }
    }

    private func openAddress() {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text.contains("://") ? text : "https://\(text)") else { return }
        opening = WebFillTarget(url: url)
    }
}

struct WebFillTarget: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The browser: the site, with a Fill button that reads the page, shows what will be entered, and writes it.
struct WebFillView: View {
    let start: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @Query private var documents: [SourceDocument]
    @Query private var overrides: [ProfileOverride]
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var session = WebFillSession()
    @State private var catalog = FormCatalog(entries: [])
    @State private var review: WebFillPlan?
    @State private var isPreparing = false
    @State private var notice: String?
    @State private var savingPage: Data?
    @State private var addressText = ""
    @FocusState private var isEditingAddress: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if session.isLoading {
                    ProgressView(value: session.progress).progressViewStyle(.linear).tint(Color.dsTint)
                }
                WebViewHost(webView: session.webView)
                    .overlay {
                        if let error = session.loadError {
                            ContentUnavailableView("Can’t open the page", systemImage: "wifi.exclamationmark", description: Text(error))
                                .background(Color(uiColor: .systemBackground))
                        }
                    }
            }
            .overlay(alignment: .top) {
                if let notice {
                    Text(notice)
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding()
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(5))
                            withAnimation { self.notice = nil }
                        }
                }
            }
            .toolbar { toolbar }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            catalog = FormCatalog.build(documents: documents, overrides: overrides)
            session.onPageLoaded = { Task { await session.countFillable(catalog: catalog) } }
            session.open(start.absoluteString)
        }
        .sheet(item: $review) { plan in
            WebFillReview(plan: plan, catalog: catalog) { chosen, attachments in
                review = nil
                Task { await fill(plan, chosen: chosen, attachments: attachments) }
            }
        }
        .sheet(isPresented: Binding(get: { savingPage != nil }, set: { if !$0 { savingPage = nil } })) {
            if let pdf = savingPage {
                SavePDFSheet(
                    title: "Save Page",
                    previews: [],
                    suggestedName: session.title.isEmpty ? "Web page" : session.title,
                    makePDF: { pdf }
                ) { file, folder in
                    savingPage = nil
                    importer.add([file], within: folder, context: modelContext, preferPrivateCloud: usePrivateCloud)
                    withAnimation { notice = "Saved to your vault." }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .principal) {
            TextField("Website address", text: $addressText)
                .focused($isEditingAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .multilineTextAlignment(isEditingAddress ? .leading : .center)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                .onSubmit { session.open(addressText) }
                .onChange(of: isEditingAddress) { _, editing in
                    addressText = editing ? (session.url?.absoluteString ?? "") : (session.url?.host() ?? "")
                }
                .onChange(of: session.url) { _, url in
                    if !isEditingAddress { addressText = url?.host() ?? "" }
                }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Reload", systemImage: "arrow.clockwise") { session.webView.reload() }
                Button("Save Page to Vault", systemImage: "square.and.arrow.down") {
                    Task { savingPage = await session.pagePDF() }
                }
                if let url = session.url {
                    Link(destination: url) { Label("Open in Safari", systemImage: "safari") }
                }
                Divider()
                Button("Forget Matches for This Site", systemImage: "arrow.uturn.backward") {
                    FormMemory.forget(site: session.site)
                    withAnimation { notice = "Dossier will match this site’s fields afresh." }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Back", systemImage: "chevron.backward") { session.webView.goBack() }
                .disabled(!session.canGoBack)
            Button("Forward", systemImage: "chevron.forward") { session.webView.goForward() }
                .disabled(!session.canGoForward)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button {
                Task { await prepare() }
            } label: {
                if isPreparing {
                    ProgressView()
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.sparkles")
                        Text(session.fillableCount > 0 ? "Fill \(session.fillableCount)" : "Fill")
                    }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPreparing || session.isLoading)
        }
    }

    /// Reads the page, matches every field (rules, what this site taught Dossier, then the model), and
    /// shows the plan.
    private func prepare() async {
        isPreparing = true
        defer { isPreparing = false }
        catalog = FormCatalog.build(documents: documents, overrides: overrides)
        let fields = await session.scan()
        guard !fields.isEmpty else {
            withAnimation { notice = "There are no fields on this page." }
            return
        }
        let slots = Set(catalog.slots.map(\.slot))
        let memory = FormMemory.matches(for: session.site)
        var matches: [String: FieldMatch] = [:]
        for field in fields where field.inputType != "file" {
            if let match = FormMatcher.match(field, slots: slots, memory: memory) { matches[field.id] = match }
        }
        // Fields you told Dossier to leave alone aren't sent to the model.
        let rest = fields.filter { matches[$0.id] == nil && $0.inputType != "file" && memory[$0.memoryKey] == nil }
        let suggested = await FieldAssistant().suggest(for: rest, slots: catalog.slots, preferPrivateCloud: usePrivateCloud)
        matches.merge(suggested) { current, _ in current }
        review = WebFillPlan(site: session.site, fields: fields, matches: matches)
    }

    private func fill(_ plan: WebFillPlan, chosen: [String: FieldMatch], attachments: [String: SourceDocument]) async {
        let assignment = FormMatcher.assign(plan.fields, matches: chosen, catalog: catalog)
        // Numbers need Face ID. Without it, everything else is still filled and the numbers are left.
        var context: LAContext?
        var skippedNumbers = 0
        if catalog.needsFaceID(assignment.entries.values) {
            context = try? await Authenticator.authenticate(reason: "Fill your document numbers")
            if context == nil { skippedNumbers = assignment.entries.values.filter { catalog.entry($0)?.isSensitive == true }.count }
        }
        var values: [String: [String]] = [:]
        for field in plan.fields {
            guard let id = assignment.entries[field.id], let entry = catalog.entry(id), let value = catalog.value(of: entry, context: context) else { continue }
            values[field.id] = FormMatcher.candidates(for: value, kind: entry.kind, part: chosen[field.id]?.part, field: field)
        }
        let results = await session.fill(values)
        var attached = 0
        for (token, document) in attachments {
            guard let url = document.bookmark.flatMap(FileAccess.resolve)?.url, let data = try? FileAccess.read(url) else { continue }
            let type = FileAccess.isPDF(url) ? "application/pdf" : "image/jpeg"
            if await session.attach(data, name: document.fileName, type: type, to: token) { attached += 1 }
        }
        let filled = results.values.filter { $0 }.count
        var message = filled == 1 ? "Filled 1 field." : "Filled \(filled) fields."
        if results.count > filled { message += " \(results.count - filled) didn’t take a value; check them." }
        if attached > 0 { message += attached == 1 ? " Attached 1 file." : " Attached \(attached) files." }
        if skippedNumbers > 0 { message += skippedNumbers == 1 ? " 1 number was left without Face ID." : " \(skippedNumbers) numbers were left without Face ID." }
        for (section, count) in assignment.remaining.sorted(by: { $0.key < $1.key }) {
            message += "\n\(count) more \(section.lowercased()): use the site’s Add button, then tap Fill again."
        }
        withAnimation { notice = message }
        await session.countFillable(catalog: catalog)
    }
}

/// What a page has and what Dossier suggests for it.
struct WebFillPlan: Identifiable {
    let id = UUID()
    let site: String
    let fields: [FieldDescriptor]
    let matches: [String: FieldMatch]
}

/// Hosts the session's web view.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: Review

/// What Dossier will enter on this page, field by field, before anything is written. Change any match;
/// Dossier remembers the change for this site.
struct WebFillReview: View {
    let plan: WebFillPlan
    let catalog: FormCatalog
    let onFill: ([String: FieldMatch], [String: SourceDocument]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var documents: [SourceDocument]
    @State private var matches: [String: FieldMatch] = [:]
    @State private var skipped: Set<String> = []
    @State private var attachments: [String: SourceDocument] = [:]
    @State private var choosingFor: FieldDescriptor?

    private var assignment: FormAssignment { FormMatcher.assign(plan.fields, matches: matches, catalog: catalog) }
    private var uploads: [FieldDescriptor] { plan.fields.filter { $0.inputType == "file" } }
    private var matched: [FieldDescriptor] { plan.fields.filter { $0.inputType != "file" && assignment.entries[$0.id] != nil } }
    private var unmatched: [FieldDescriptor] { plan.fields.filter { $0.inputType != "file" && assignment.entries[$0.id] == nil } }
    private var fillCount: Int { matched.filter { !skipped.contains($0.id) }.count + attachments.count }

    var body: some View {
        NavigationStack {
            List {
                if !matched.isEmpty {
                    Section {
                        ForEach(matched) { field in
                            row(field)
                        }
                    } header: {
                        Text("Dossier will enter")
                    } footer: {
                        Text("Tap a field to choose a different value. Fields that already have something in them are off unless you turn them on.")
                    }
                }

                if !assignment.remaining.isEmpty {
                    Section {
                        ForEach(assignment.remaining.sorted { $0.key < $1.key }, id: \.key) { name, count in
                            Label("\(count) more \(name.lowercased()) after these", systemImage: "rectangle.stack.badge.plus")
                        }
                    } footer: {
                        Text("After filling, use the site’s Add button for another entry, then tap Fill again: Dossier continues where it left off.")
                    }
                }

                if !uploads.isEmpty {
                    Section("Uploads") {
                        ForEach(uploads) { field in
                            Menu {
                                ForEach(documents.filter { $0.isReady && $0.bookmark != nil }) { document in
                                    Button(document.title) { attachments[field.id] = document }
                                }
                                if attachments[field.id] != nil {
                                    Divider()
                                    Button("Don’t Attach", role: .destructive) { attachments[field.id] = nil }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.label).font(.footnote).foregroundStyle(.secondary)
                                    Text(attachments[field.id]?.title ?? "Attach from your vault").foregroundStyle(attachments[field.id] == nil ? Color.dsTint : .primary)
                                }
                            }
                        }
                    }
                }

                if !unmatched.isEmpty {
                    Section {
                        ForEach(unmatched) { field in
                            Button { choosingFor = field } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.label.isEmpty ? "Unlabeled field" : field.label).foregroundStyle(.primary).lineLimit(2)
                                    if !field.context.isEmpty { Text(field.context).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                                }
                            }
                        }
                    } header: {
                        Text("Left for you")
                    } footer: {
                        Text("Questions, declarations and anything Dossier doesn’t know. Tap one to fill it from your values.")
                    }
                }
            }
            .navigationTitle(plan.site.isEmpty ? "Fill" : plan.site)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    var chosen = matches
                    for id in skipped { chosen[id] = nil }
                    onFill(chosen, attachments)
                } label: {
                    Text(fillCount == 1 ? "Fill 1 Field" : "Fill \(fillCount) Fields").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(fillCount == 0)
                .padding()
                .background(.bar)
            }
            .sheet(item: $choosingFor) { field in
                SlotPicker(catalog: catalog, current: matches[field.id]?.slot) { slot in
                    matches[field.id] = slot.map { FieldMatch(slot: $0, part: FormMatcher.datePart(field), source: .you) }
                    if slot != nil { skipped.remove(field.id) }
                    FormMemory.remember(slot, for: field, on: plan.site)
                }
            }
            .onAppear {
                matches = plan.matches
                // Don't overwrite what's already on the page unless you say so.
                skipped = Set(plan.fields.filter { !$0.currentValue.isEmpty }.map(\.id))
            }
        }
    }

    private func row(_ field: FieldDescriptor) -> some View {
        let entry = assignment.entries[field.id].flatMap(catalog.entry)
        return HStack(spacing: 12) {
            Button { choosingFor = field } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Text(preview(entry, field: field))
                        .font(entry?.isSensitive == true || entry?.kind == .date ? .dsFieldValue : .body)
                        .foregroundStyle(.primary)
                    if let entry, entry.group != "You" {
                        Text(entry.group).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("Fill", isOn: Binding(get: { !skipped.contains(field.id) }, set: { if $0 { skipped.remove(field.id) } else { skipped.insert(field.id) } }))
                .labelsHidden()
        }
    }

    private func preview(_ entry: FormEntry?, field: FieldDescriptor) -> String {
        guard let entry else { return "—" }
        if entry.isSensitive { return entry.masked ?? "•••• ••" }
        guard let value = catalog.value(of: entry, context: nil) else { return "—" }
        return FormMatcher.shown(FormMatcher.candidates(for: value, kind: entry.kind, part: matches[field.id]?.part, field: field), in: field) ?? value
    }
}

/// Choosing which of your values a field takes, or none.
struct SlotPicker: View {
    let catalog: FormCatalog
    let current: String?
    let onChoose: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var groups: [(name: String, entries: [FormEntry])] {
        let shown = catalog.entries.filter { $0.row == nil || $0.row == 0 }
            .filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
        var order: [String] = []
        var grouped: [String: [FormEntry]] = [:]
        for entry in shown {
            let name = entry.row == nil ? entry.group : entry.group.replacingOccurrences(of: " 1", with: "s")
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(entry)
        }
        return order.map { ($0, grouped[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("None of My Values", systemImage: "nosign") { choose(nil) }
                }
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.entries) { entry in
                            Button { choose(entry.slot) } label: {
                                HStack {
                                    Text(entry.label).foregroundStyle(.primary)
                                    Spacer()
                                    if entry.slot == current { Image(systemName: "checkmark").foregroundStyle(Color.dsTint) }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search your values")
            .navigationTitle("Choose a Value")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func choose(_ slot: String?) {
        onChoose(slot)
        dismiss()
    }
}
