import Foundation

/// One filing line for a category: what goes in it, or what goes in another category instead.
nonisolated struct FilingLine: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id = UUID()
    /// "Insurance cards and proof of coverage".
    var text: String
    /// Nil for a "What goes here" line. The other category's name for a "Not here" line.
    var pointsTo: String?
    /// You wrote or edited it. Dossier never changes your lines.
    var isYours = false

    var isExclusion: Bool { pointsTo != nil }
}

/// One category: a shelf in the Vault and a top-level folder in the library.
nonisolated struct CategoryDefinition: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The name you see. Unique in the list, ignoring case.
    var name: String
    /// The default name it started as, such as "Home". Kept when you rename it, so kinds with a fixed
    /// place (a lease goes to Home) still find it. Nil for a category you added.
    var builtIn: String?
    var lines: [FilingLine] = []

    var id: String { name }
    var includes: [FilingLine] { lines.filter { !$0.isExclusion } }
    var exclusions: [FilingLine] { lines.filter(\.isExclusion) }
}

/// Your categories, in shelf order. The on-device model files documents into these only, following their
/// lines. Saved as JSON in UserDefaults under `storageKey`, so a view that reads it with
/// `@AppStorage(CategoryList.storageKey)` updates when it changes.
nonisolated struct CategoryList: Codable, Equatable, Sendable {
    var categories: [CategoryDefinition]
    /// Old names, lower-cased, to the name they have now: "housing" → "Home".
    var aliases: [String: String] = [:]

    static let storageKey = "categoryList"
    static let other = "Other"

    // MARK: Storage

    init(categories: [CategoryDefinition], aliases: [String: String] = [:]) {
        self.categories = categories
        self.aliases = aliases
    }

    init(json: String) {
        let saved = (try? JSONDecoder().decode(CategoryList.self, from: Data(json.utf8)))
        self = saved.map { $0.normalized() } ?? .defaults
    }

    var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The saved list, or the defaults when nothing is saved.
    static var current: CategoryList {
        CategoryList(json: UserDefaults.standard.string(forKey: storageKey) ?? "")
    }

    /// Changes the saved list.
    static func update(_ change: (inout CategoryList) -> Void) {
        var list = current
        change(&list)
        save(list)
    }

    static func save(_ list: CategoryList) {
        UserDefaults.standard.set(list.normalized().json, forKey: storageKey)
    }

    // MARK: Reading

    var names: [String] { categories.map(\.name) }

    func category(named name: String) -> CategoryDefinition? {
        guard let resolved = resolve(name) else { return nil }
        return categories.first { $0.name == resolved }
    }

    /// The name a category has now: the same name in any case, or an old name it had. Nil when it isn't in
    /// the list.
    func resolve(_ name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let match = categories.first(where: { $0.name.lowercased() == key }) { return match.name }
        if let alias = aliases[key], categories.contains(where: { $0.name == alias }) { return alias }
        return nil
    }

    /// The category that started as this default name, whatever it's called now. Nil when you deleted it.
    func builtIn(_ defaultName: String) -> String? {
        categories.first { $0.builtIn == defaultName }?.name
    }

    /// Position on the Vault: list order, then categories not in the list by name, Other always last.
    func order(of name: String) -> Int {
        if let resolved = resolve(name), let index = names.firstIndex(of: resolved) {
            return resolved == Self.other ? Int.max : index
        }
        return name == Self.other ? Int.max : categories.count
    }

    // MARK: Changing

    /// Adds a category before Other. False when the name is blank or already used.
    @discardableResult
    mutating func add(_ name: String, lines: [FilingLine] = []) -> Bool {
        let name = Self.clean(name)
        guard !name.isEmpty, !categories.contains(where: { $0.name.lowercased() == name.lowercased() }) else { return false }
        aliases[name.lowercased()] = nil
        let lines = lines.isEmpty ? [FilingLine(text: name)] : lines
        let index = categories.firstIndex { $0.name == Self.other } ?? categories.endIndex
        categories.insert(CategoryDefinition(name: name, builtIn: nil, lines: lines), at: index)
        return true
    }

    /// Renames a category. Lines that point to it follow, and the old name becomes an alias. False for
    /// Other, a blank name or a name already used.
    @discardableResult
    mutating func rename(_ old: String, to new: String) -> Bool {
        let new = Self.clean(new)
        guard let old = resolve(old), old != Self.other, !new.isEmpty,
              let index = categories.firstIndex(where: { $0.name == old }) else { return false }
        if old == new { return true }
        if categories.contains(where: { $0.name.lowercased() == new.lowercased() && $0.name != old }) { return false }
        categories[index].name = new
        for c in categories.indices {
            for l in categories[c].lines.indices where categories[c].lines[l].pointsTo == old {
                categories[c].lines[l].pointsTo = new
            }
        }
        for (key, value) in aliases where value == old { aliases[key] = new }
        aliases[old.lowercased()] = new
        aliases[new.lowercased()] = nil
        return true
    }

    /// Deletes a category and the Suggested lines that point to it. Your lines that point to it point to
    /// Other instead. False for Other.
    @discardableResult
    mutating func delete(_ name: String) -> Bool {
        guard let name = resolve(name), name != Self.other else { return false }
        categories.removeAll { $0.name == name }
        for c in categories.indices {
            categories[c].lines.removeAll { $0.pointsTo == name && !$0.isYours }
            for l in categories[c].lines.indices where categories[c].lines[l].pointsTo == name {
                categories[c].lines[l].pointsTo = Self.other
            }
        }
        aliases = aliases.filter { $0.value != name }
        return true
    }

    /// Moves categories, as a List's onMove gives them. Other stays last.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var moved = categories
        let items = source.sorted().map { moved[$0] }
        for index in source.sorted(by: >) { moved.remove(at: index) }
        let before = source.filter { $0 < destination }.count
        let target = min(max(destination - before, 0), moved.count)
        moved.insert(contentsOf: items, at: target)
        categories = moved
        self = normalized()
    }

    /// Saves a rule in your words as one of your "What goes here" lines, first on the category's page. The
    /// on-device model follows your lines before its own. Nothing when the text is blank or already there.
    mutating func addRule(_ text: String, to name: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let name = resolve(name), let index = categories.firstIndex(where: { $0.name == name }) else { return }
        guard !categories[index].lines.contains(where: { $0.text.lowercased() == text.lowercased() && $0.pointsTo == nil }) else { return }
        categories[index].lines.insert(FilingLine(text: text, isYours: true), at: 0)
    }

    /// Replaces a category's lines.
    mutating func setLines(_ lines: [FilingLine], for name: String) {
        guard let name = resolve(name), let index = categories.firstIndex(where: { $0.name == name }) else { return }
        categories[index].lines = lines
    }

    /// Puts back a built-in category's default lines. Your lines are dropped. Nothing for a category you added.
    mutating func resetLines(for name: String) {
        guard let name = resolve(name), let index = categories.firstIndex(where: { $0.name == name }),
              let builtIn = categories[index].builtIn,
              let lines = Self.defaults.categories.first(where: { $0.builtIn == builtIn })?.lines else { return }
        let current = self
        categories[index].lines = lines.compactMap { line in
            guard let target = line.pointsTo else { return line }
            // Point to the category's name now; drop the line if you deleted that category.
            guard let now = current.builtIn(target) else { return nil }
            var line = line
            line.pointsTo = now
            return line
        }
    }

    /// Other present and last; names unique.
    func normalized() -> CategoryList {
        var seen = Set<String>()
        var list = categories.filter { seen.insert($0.name.lowercased()).inserted }
        let other = list.first { $0.name == Self.other }
            ?? Self.defaults.categories.first { $0.name == Self.other }!
        list.removeAll { $0.name == Self.other }
        list.append(other)
        return CategoryList(categories: list, aliases: aliases)
    }

    static func clean(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: The model's instructions

    /// The categories and their lines, for the on-device model that files documents.
    var promptText: String {
        var lines: [String] = []
        // Your rules first: the model must follow them before the category lines.
        let rules = self.rules
        if !rules.isEmpty {
            lines.append("The owner's rules (follow these first; they win over every line below):")
            for rule in rules { lines.append("- \(rule.line.text) → \(rule.line.pointsTo ?? rule.category)") }
            lines.append("")
        }
        lines.append("Categories (choose exactly one name):")
        for category in categories {
            lines.append("- \(category.name)")
            let includes = category.includes.filter { !$0.isYours }.map(\.text).filter { !$0.isEmpty }
            if !includes.isEmpty { lines.append("  Goes here: \(includes.joined(separator: "; "))") }
            let exclusions = category.exclusions.filter { !$0.text.isEmpty && !$0.isYours }
                .map { "\($0.text) (use \($0.pointsTo ?? Self.other))" }
            if !exclusions.isEmpty { lines.append("  Not here: \(exclusions.joined(separator: "; "))") }
        }
        return lines.joined(separator: "\n")
    }

    /// Lines you wrote, with the category each is on, in shelf order.
    var rules: [(category: String, line: FilingLine)] {
        categories.flatMap { category in
            category.lines.filter { $0.isYours && !$0.text.isEmpty }.map { (category: category.name, line: $0) }
        }
    }

    // MARK: Defaults

    /// The 14 default categories and their lines, in shelf order. Old names are aliases.
    static let defaults: CategoryList = {
        func c(_ name: String, _ includes: [String], _ exclusions: [(String, String)] = []) -> CategoryDefinition {
            CategoryDefinition(
                name: name, builtIn: name,
                lines: includes.map { FilingLine(text: $0) } + exclusions.map { FilingLine(text: $0.0, pointsTo: $0.1) }
            )
        }
        return CategoryList(categories: [
            c("Identity", ["Passports, driver’s licences and state IDs", "Birth, marriage and divorce certificates", "Social Security cards and name changes"],
              [("Visas and green cards", "Immigration")]),
            c("Immigration", ["Visas, green cards and EAD cards", "I-797 notices, I-94 records and I-20s", "Naturalization papers"],
              [("Passports", "Identity")]),
            c("Health", ["Medical exams and lab results", "Vaccination records", "Prescriptions, dental and vision records"],
              [("Insurance cards", "Insurance")]),
            c("Insurance", ["Health, auto, home, renters and life policies", "Insurance cards and proof of coverage", "Claims and letters from insurers"],
              [("Medical bills and lab results", "Health"), ("Tax forms from an insurer, such as 1095-A", "Taxes"), ("Travel insurance", "Travel")]),
            c("Money", ["Bank and credit card statements", "Loans, investments and retirement accounts"],
              [("Tax forms", "Taxes")]),
            c("Taxes", ["Tax returns", "W-2s, 1099s and 1095s", "Records kept for deductions"]),
            c("Home", ["Leases, deeds and mortgages", "Utility bills and HOA papers", "Home warranties"],
              [("Renters and home insurance", "Insurance")]),
            c("Vehicles", ["Titles and registrations", "Inspections, car loans and repair records"],
              [("Auto insurance", "Insurance")]),
            c("Work", ["Offer letters and contracts", "Pay stubs and benefits papers", "Professional licences and certifications"],
              [("W-2s", "Taxes")]),
            c("Education", ["Diplomas and transcripts", "Certificates and course records"],
              [("I-20s", "Immigration")]),
            c("Legal", ["Wills, powers of attorney and trusts", "Court papers and signed contracts"],
              [("Leases", "Home")]),
            c("Purchases", ["Receipts", "Product warranties and manuals"],
              [("Home warranties", "Home")]),
            c("Travel", ["Itineraries, flight and hotel bookings", "Travel insurance"],
              [("Passports", "Identity"), ("Visas", "Immigration")]),
            c(CategoryList.other, ["Anything that fits no other category"]),
        ], aliases: ["housing": "Home", "tax and money": "Money"])
    }()
}
