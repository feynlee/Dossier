import Foundation
import FoundationModels

/// The schema the language model fills in for one document. Properties are generated in declaration
/// order: first what the document is, then its fields.
@Generable(description: "What one personal document says: its standard facts, everything else it records, and details about its holder")
nonisolated struct DocumentReading {
    @Guide(
        description: """
            The kind of document. passport: a national passport. greenCard: a US permanent resident card. \
            employmentAuthorization: a US EAD card. visa: a visa foil. driversLicense or stateID: a US or \
            Canadian card. lease: a residential lease. uscisNotice: an I-797 or other USCIS notice. i94: an \
            I-94 arrival record or travel history. other: anything else, such as a medical exam, vaccination \
            record, tax form, school record or bank statement.
            """,
        .anyOf(DocumentKind.allCases.filter { $0 != .addedByYou }.map(\.rawValue))
    )
    var kind: String

    @Guide(description: "A short title in sentence case naming what the document is, such as \"Passport\", \"Lease for 88 Pine Ave\", \"Report of medical examination (I-693)\" or \"International certificate of vaccination\".")
    var title: String

    @Guide(description: "The important facts printed on the document, as listed for its kind in the instructions. Omit facts that are not printed; never guess.")
    var fields: [ReadField]

    @Guide(description: "Everything else the document records, section by section in reading order, as described in the instructions: every filled-in field, table row, result and record. Empty only for a document with nothing beyond its facts.")
    var contents: [ReadEntry]

    @Guide(description: "Other details useful for filling in forms, about the holder and their family members, as described in the instructions. Empty if there are none.")
    var details: [ReadDetail]

    @Guide(description: "For an I-94 travel history only: every arrival and departure row. Empty for every other document.")
    var travel: [ReadTravelEvent]
}

@Generable(description: "One row of an I-94 travel history")
nonisolated struct ReadTravelEvent {
    @Guide(description: "The date as YYYY-MM-DD.")
    var date: String

    @Guide(description: "Whether the row is an arrival into or a departure from the United States.", .anyOf(["arrival", "departure"]))
    var kind: String

    @Guide(description: "The port or location code as printed, such as SEA.")
    var port: String
}

@Generable(description: "One fact printed on the document")
nonisolated struct ReadField {
    @Guide(
        description: """
            Which fact this is. documentNumber is the passport, card, visa or licence number. alienNumber is \
            the USCIS number or A-Number. address is the holder's residential address; for a lease, the \
            rented unit. receiptNumber is a USCIS receipt number such as IOE0912345678. validFrom and \
            validUntil are the dates a status, notice or card is valid between; uscisCategory is a visa \
            class, EAD category or green card category such as H-1B, C09 or IR1.
            """,
        .anyOf(FactKey.allCases.filter { $0 != .detail }.map(\.rawValue))
    )
    var key: String

    @Guide(description: "The value as printed. Dates as YYYY-MM-DD. Names as printed. An address on one line with unit, city, state and ZIP code.")
    var value: String

    @Guide(description: "The 1-based page the value is printed on.")
    var page: Int

    @Guide(
        description: """
            high when every character is clearly printed and it is certainly this fact. low when any part is \
            blurry, cut off, covered, handwritten, ambiguous (0 or O, 1 or I), or you had to choose between \
            several candidates.
            """,
        .anyOf(["high", "low"])
    )
    var confidence: String
}

@Generable(description: "One thing the document records, such as a test result, a vaccine dose, a tax box or a course grade")
nonisolated struct ReadEntry {
    @Guide(description: "The section it's in, using the document's own heading in sentence case, such as Vaccinations, Chest X-ray, Blood tests, Income or Courses.")
    var section: String

    @Guide(description: "What it is, using the document's own label, made unique within its section, such as \"MMR · dose 1\", \"IGRA result\", \"Box 1 · Wages\" or \"Biology 101\".")
    var label: String

    @Guide(description: "The value as printed. For a table row, the row's other columns joined with \" · \", such as \"2019-04-02 · Lot AB123 · King County clinic\". Dates as YYYY-MM-DD. Units and reference ranges as printed.")
    var value: String

    @Guide(description: "The 1-based page the value is printed on.")
    var page: Int

    @Guide(description: "high when it is clearly printed and certainly this entry; low when any part is blurry, handwritten or cut off.", .anyOf(["high", "low"]))
    var confidence: String

    @Guide(description: "yes when the value is an identification number such as a Social Security, account, policy, case or lot number on its own; no otherwise.", .anyOf(["yes", "no"]))
    var isNumber: String
}

@Generable(description: "A detail useful for filling in forms, about the holder or a family member of theirs")
nonisolated struct ReadDetail {
    @Guide(
        description: "Whose detail: holder for the document's holder, otherwise the family member's relationship to the holder.",
        .anyOf(["holder"] + Relation.allCases.map(\.rawValue))
    )
    var person: String

    @Guide(description: "The family member's full name as printed. Empty for the holder.")
    var personName: String

    @Guide(description: "A short name for the detail in sentence case, such as Height, Eye colour, Phone, Email, Occupation, Employer, Marital status, Name, Date of birth or Place of birth.")
    var label: String

    @Guide(description: "The value as printed. Dates as YYYY-MM-DD.")
    var value: String

    @Guide(description: "The 1-based page the value is printed on.")
    var page: Int

    @Guide(description: "high when it is clearly printed and certainly this detail; low otherwise.", .anyOf(["high", "low"]))
    var confidence: String

    @Guide(description: "yes for an identification number such as a Social Security, tax, national ID, account or case number; no otherwise.", .anyOf(["yes", "no"]))
    var isNumber: String
}

/// What to look for besides each kind's important facts. Set in Settings › Reading.
nonisolated struct DetailRequest: Sendable, Equatable {
    /// Other details about the holder and their family that are useful for forms.
    var findsUsefulDetails = true
    /// Details you asked for by name, such as "Height" or "Employer".
    var requested: [String] = []

    static let findsUsefulDetailsKey = "extractUsefulDetails"
    static let requestedKey = "extractRequestedDetails"

    static var current: DetailRequest {
        let defaults = UserDefaults.standard
        return DetailRequest(
            findsUsefulDetails: defaults.object(forKey: findsUsefulDetailsKey) as? Bool ?? true,
            requested: defaults.stringArray(forKey: requestedKey) ?? []
        )
    }

    var isEmpty: Bool { !findsUsefulDetails && requested.isEmpty }
}
