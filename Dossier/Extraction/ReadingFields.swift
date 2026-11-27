import Foundation
import FoundationModels

/// A field you ask Dossier to read from a document, such as "Landlord's phone", with an optional hint that
/// says what you mean ("yes, no, or the conditions").
nonisolated struct AskedField: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var hint: String = ""

    var id: String { name.lowercased() }

    /// How the prompt names it: the name, then the hint in brackets.
    var promptText: String {
        let hint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        return hint.isEmpty ? "\"\(name)\"" : "\"\(name)\" (\(hint))"
    }
}

/// What to read from a document besides its kind's standard facts: the fields you asked for, and whether
/// Dossier also reads anything else it thinks is important. A document's own fields come first, then its
/// category's rule, then the default (no fields, and everything useful).
nonisolated struct ReadingFields: Codable, Equatable, Sendable {
    var fields: [AskedField] = []
    /// Also read what Dossier thinks is important: the document's other contents and details.
    var readsUseful = true

    var json: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    init(fields: [AskedField] = [], readsUseful: Bool = true) {
        self.fields = fields
        self.readsUseful = readsUseful
    }

    init?(json: String?) {
        guard let json, let data = json.data(using: .utf8), let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }

    /// The names in order, for a tag: "Landlord's phone, Security deposit".
    var summary: String { fields.map(\.name).joined(separator: ", ") }

    /// Adds a field unless one with the same name is there already. Returns whether it was added.
    @discardableResult
    mutating func add(_ name: String, hint: String = "") -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !fields.contains(where: { $0.id == trimmed.lowercased() }) else { return false }
        fields.append(AskedField(name: trimmed, hint: hint))
        return true
    }
}

/// Which fields a document is read with.
nonisolated enum FieldSource: Equatable, Sendable {
    /// Fields set for this document.
    case own(ReadingFields)
    /// Its category's rule, such as Housing.
    case rule(category: String, fields: ReadingFields)
    /// What Dossier thinks is important.
    case standard

    var fields: ReadingFields? {
        switch self {
        case .own(let fields), .rule(_, let fields): fields
        case .standard: nil
        }
    }

    /// How it's stored on a document after reading: "own", "rule:Housing" or "default".
    var raw: String {
        switch self {
        case .own: "own"
        case .rule(let category, _): "rule:\(category)"
        case .standard: "default"
        }
    }

    /// The tag shown on files and documents.
    var tag: String {
        switch self {
        case .own(let fields): fields.fields.isEmpty ? "Your fields" : "Your fields: \(fields.summary)"
        case .rule(let category, _): "\(category) rule"
        case .standard: "Default"
        }
    }

    /// A short tag, without the field names.
    var shortTag: String {
        switch self {
        case .own: "Your fields"
        case .rule(let category, _): "\(category) rule"
        case .standard: "Default"
        }
    }

    var isStandard: Bool { self == .standard }
}

/// Standing rules: one set of fields per library category, kept in UserDefaults like "Also look for".
nonisolated enum FieldRules {
    static let rulesKey = "categoryFieldRules"
    /// Settings › Reading › Ask when adding files: show the add sheet before reading.
    static let askWhenAddingKey = "askForFieldsWhenAdding"

    static var all: [String: ReadingFields] {
        guard let data = UserDefaults.standard.data(forKey: rulesKey),
              let rules = try? JSONDecoder().decode([String: ReadingFields].self, from: data) else { return [:] }
        return rules
    }

    static func rule(for category: String?) -> ReadingFields? {
        guard let category else { return nil }
        let rules = all
        if let rule = rules[category] ?? rules.first(where: { $0.key.caseInsensitiveCompare(category) == .orderedSame })?.value {
            return rule
        }
        // A rule saved under a category's old name, such as Housing for Home.
        let list = CategoryList.current
        guard let resolved = list.resolve(category) else { return nil }
        return rules.first { list.resolve($0.key) == resolved }?.value
    }

    /// Moves a category's rule to its new name.
    static func rename(_ old: String, to new: String) {
        var rules = all
        guard let key = rules.keys.first(where: { $0.caseInsensitiveCompare(old) == .orderedSame }), old != new else { return }
        rules[new] = rules.removeValue(forKey: key)
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: rulesKey)
    }

    /// Saves a category's rule; nil or an empty rule that reads everything useful removes it.
    static func set(_ fields: ReadingFields?, for category: String) {
        var rules = all
        if let fields, !(fields.fields.isEmpty && fields.readsUseful) {
            rules[category] = fields
        } else {
            rules[category] = nil
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: rulesKey)
    }

    static var asksWhenAdding: Bool {
        UserDefaults.standard.object(forKey: askWhenAddingKey) as? Bool ?? true
    }

    /// Which fields a document is read with: its own, else its category's rule, else the default.
    static func source(own: ReadingFields?, category: String?) -> FieldSource {
        // Own fields that are empty and read everything useful: you chose the default for this document.
        if let own { return own.fields.isEmpty && own.readsUseful ? .standard : .own(own) }
        if let category, let rule = rule(for: category) { return .rule(category: category, fields: rule) }
        return .standard
    }

    // MARK: Suggestions

    /// The standard facts Dossier always reads for a kind, by name: shown in gray in the field editor.
    static func standardFieldNames(for kind: DocumentKind) -> [String] {
        kind.importantKeys.map(\.label)
    }

    /// Common fields for a kind of document, to add with one tap.
    static func suggestions(for kind: DocumentKind, category: String?) -> [String] {
        switch kind {
        case .lease:
            return ["Monthly rent", "Landlord’s phone", "Security deposit", "Pets allowed", "Late fee", "Rent due date", "Parking"]
        case .passport, .greenCard, .employmentAuthorization, .visa, .driversLicense, .stateID:
            return ["Height", "Eye colour", "Issuing office", "Restrictions"]
        case .uscisNotice:
            return ["Case status", "Priority date", "Interview date", "Attorney"]
        case .i94:
            return ["Last arrival", "Port of entry"]
        case .other, .addedByYou:
            switch category {
            case "Health": return ["Doctor", "Clinic phone", "Next appointment", "Blood type", "Allergies"]
            case "Taxes", "Tax and money": return ["Tax year", "Total income", "Employer", "Amount due"]
            case "Money": return ["Account number", "Balance", "Statement date", "Interest rate"]
            case "Insurance": return ["Policy number", "Coverage", "Premium", "Renewal date", "Insurer phone"]
            case "Vehicles": return ["VIN", "Plate number", "Registration expiry", "Make and model"]
            case "Travel": return ["Confirmation number", "Departure date", "Return date", "Airline"]
            case "Education": return ["School", "Degree", "Graduation date", "GPA"]
            case "Work": return ["Employer", "Job title", "Start date", "Salary"]
            case "Home", "Housing": return ["Monthly payment", "Account number", "Due date", "Provider phone"]
            default: return ["Policy number", "Amount due", "Due date", "Contact phone", "Renewal date"]
            }
        }
    }

    /// Field names you used before, on other documents and in rules, most recent first.
    @MainActor
    static func usedBefore(in documents: [SourceDocument]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        let sources = documents.sorted { $0.ingestedAt > $1.ingestedAt }.compactMap(\.ownFields) + Array(all.values)
        for fields in sources {
            for field in fields.fields where seen.insert(field.id).inserted { names.append(field.name) }
        }
        return names
    }
}

// MARK: Identifying a file before it's read

/// What a file is, from its name and first page, read on this iPhone while the add sheet is open. Only a hint:
/// the full read decides the kind.
nonisolated struct FileGuess: Equatable, Sendable {
    var kind: DocumentKind
    /// A short word for what it is, such as "Lease" or "Insurance policy".
    var type: String
    /// A library category, such as Home.
    var category: String

    var label: String { "\(type) · \(category)" }
}

nonisolated enum FileIdentifier {
    /// Identifies a file you picked from its name and the text of its first page, with the on-device model,
    /// off the main actor. Nil when the model isn't available or the file can't be read.
    @concurrent
    static func identify(url: URL) async -> FileGuess? {
        guard let data = try? FileAccess.read(url) else { return nil }
        return await identify(data: data, fileName: url.lastPathComponent)
    }

    static func identify(data: Data, fileName: String) async -> FileGuess? {
        guard let image = try? PageReader.renderPage(0, of: data, fileName: fileName),
              let text = try? await PageReader.recognizeText(in: image) else { return nil }
        return await identify(fileName: fileName, text: text.lines.joined(separator: "\n"))
    }

    /// Identifies a document from pages already read.
    static func identify(fileName: String, pages: [ReadPage]) async -> FileGuess? {
        await identify(fileName: fileName, text: pages.first?.lines.joined(separator: "\n") ?? "")
    }

    /// The quick answer's shape: a kind, a type and one of your categories.
    static func quickIdentitySchema(_ categories: [String]) -> DynamicGenerationSchema {
        DynamicGenerationSchema(name: "QuickIdentity", description: "What a personal document is", properties: [
            .init(name: "kind", description: "The kind of document.",
                  schema: DynamicGenerationSchema(name: "Kind", anyOf: DocumentKind.allCases.filter { $0 != .addedByYou }.map(\.rawValue))),
            .init(name: "type", description: "Two or three words for what it is, in sentence case, such as \"Lease\", \"Insurance policy\", \"W-2\" or \"Lab results\".",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "category", description: "Where it belongs, exactly as named in the list of categories.",
                  schema: DynamicGenerationSchema(name: "Category", anyOf: categories)),
        ])
    }

    static func identify(fileName: String, text: String) async -> FileGuess? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        let instructions = """
            You say what kind of personal document a file is, from its file name and the text of its first page. \
            passport: a national passport. greenCard: a US permanent resident card. employmentAuthorization: a US \
            EAD card. visa: a visa foil. driversLicense or stateID: a US or Canadian card. lease: a residential \
            lease. uscisNotice: an I-797 or other USCIS notice. i94: an I-94 record. other: anything else.
            """
        let prompt = "File name: \(fileName)\nFirst page:\n\(String(text.prefix(1_500)))"
        do {
            let categories = CategoryList.current
            let session = LanguageModelSession(model: model, instructions: instructions)
            let schema = try GenerationSchema(root: quickIdentitySchema(categories.names), dependencies: [])
            let answer = try await session.respond(to: "\(categories.promptText)\n\n\(prompt)", schema: schema, options: GenerationOptions(samplingMode: .greedy)).content
            let kind = DocumentKind(rawValue: try answer.value(String.self, forProperty: "kind")) ?? .other
            let answerType = (try? answer.value(String.self, forProperty: "type")) ?? ""
            let answerCategory = (try? answer.value(String.self, forProperty: "category")).flatMap { categories.resolve($0) } ?? CategoryList.other
            // Kinds Dossier recognises always go to the same category.
            let rule = LibraryNaming.rule(for: kind)
            let type = rule?.type ?? (answerType.trimmingCharacters(in: .whitespaces).isEmpty ? kind.displayName : answerType)
            return FileGuess(kind: kind, type: type, category: LibraryPlanner.ruleCategory(for: kind, in: categories) ?? answerCategory)
        } catch {
            return nil
        }
    }
}
