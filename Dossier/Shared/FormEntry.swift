import Foundation

/// What kind of value an entry holds, which decides how it's written into a field.
nonisolated enum FormValueKind: String, Codable, Sendable {
    case text, date, sex, country, number
}

/// One value Dossier can put into a form: your family name, your father's date of birth, the street of
/// your second-to-last address. Values stay sealed: ordinary ones under the vault key, numbers under the
/// Face ID–gated key.
nonisolated struct FormEntry: Identifiable, Hashable, Codable, Sendable {
    /// What the value is, without whose or which: "you.familyName", "family.father.dateOfBirth",
    /// "previousAddress.street". Slots and their labels never contain values, so they can be sent to the
    /// model and remembered per website.
    var slot: String
    /// For repeated sections (previous addresses, trips, children): 0 is the most recent or first.
    var row: Int?
    /// A label without values: "Father’s date of birth".
    var label: String
    /// Where it shows in lists, which may name people: "Father · ERIK ERIKSSON".
    var group: String
    var kind: FormValueKind
    var isSensitive: Bool
    var sealed: Data
    /// `•••• •• 4821` for numbers.
    var masked: String?

    var id: String { row.map { "\(slot)#\($0)" } ?? slot }
}
