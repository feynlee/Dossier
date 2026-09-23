import Foundation
import FoundationModels

/// The schema the language model fills in for one document. Properties are generated in declaration
/// order: first what the document is, then its fields.
@Generable(description: "What one identity, immigration, travel or housing document says about its holder")
nonisolated struct DocumentReading {
    @Guide(
        description: """
            The kind of document. passport: a national passport. greenCard: a US permanent resident card. \
            employmentAuthorization: a US EAD card. visa: a visa foil. driversLicense or stateID: a US or \
            Canadian card. lease: a residential lease. uscisNotice: an I-797 or other USCIS notice. i94: an \
            I-94 arrival record or travel history. other: anything else.
            """,
        .anyOf(DocumentKind.allCases.map(\.rawValue))
    )
    var kind: String

    @Guide(description: "A short title in sentence case, such as \"Passport\", \"Green card\" or \"Lease for 88 Pine Ave\".")
    var title: String

    @Guide(description: "Every listed fact that is printed on the document. Omit facts that are not printed; never guess.")
    var fields: [ReadField]
}

@Generable(description: "One fact printed on the document")
nonisolated struct ReadField {
    @Guide(
        description: """
            Which fact this is. documentNumber is the passport, card, visa or licence number. alienNumber is \
            the USCIS number or A-Number. address is the holder's residential address; for a lease, the \
            rented unit. receiptNumber is a USCIS receipt number such as IOE0912345678.
            """,
        .anyOf(FactKey.allCases.map(\.rawValue))
    )
    var key: String

    @Guide(description: "The value as printed. Dates as YYYY-MM-DD. Names as printed. An address on one line with unit, city, state and ZIP code.")
    var value: String

    @Guide(description: "The 1-based page the value is printed on.")
    var page: Int
}
