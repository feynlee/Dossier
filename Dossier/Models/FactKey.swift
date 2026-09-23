import Foundation

/// The kinds of document Dossier recognises.
nonisolated enum DocumentKind: String, CaseIterable, Codable, Sendable {
    case passport
    case greenCard
    case employmentAuthorization
    case visa
    case driversLicense
    case stateID
    case lease
    case uscisNotice
    case i94
    case other
    /// A record the user added by hand, such as an address for a gap in their history.
    case addedByYou

    var displayName: String {
        switch self {
        case .passport: "Passport"
        case .greenCard: "Green card"
        case .employmentAuthorization: "EAD card"
        case .visa: "Visa"
        case .driversLicense: "Driver’s licence"
        case .stateID: "State ID"
        case .lease: "Lease"
        case .uscisNotice: "USCIS notice"
        case .i94: "I-94 record"
        case .other: "Document"
        case .addedByYou: "Added by you"
        }
    }

    /// SF Symbols from the design system's iconography table.
    var symbol: String {
        switch self {
        case .passport: "person.text.rectangle"
        case .greenCard, .employmentAuthorization, .stateID: "person.crop.rectangle"
        case .visa: "checkmark.shield"
        case .driversLicense: "car"
        case .lease: "house"
        case .uscisNotice, .other: "doc.text"
        case .i94: "airplane"
        case .addedByYou: "house"
        }
    }
}

/// One kind of fact that can be extracted from a document.
nonisolated enum FactKey: String, CaseIterable, Codable, Sendable {
    case surname
    case givenNames
    case dateOfBirth
    case placeOfBirth
    case sex
    case nationality
    case documentNumber
    case issuingAuthority
    case issueDate
    case expiryDate
    case alienNumber
    case uscisCategory
    case residentSince
    case address
    case leaseStartDate
    case leaseEndDate
    case licenseClass
    case receiptNumber
    case noticeDate
    case formType
    case classOfAdmission
    case admitUntil
    case i94Number
    case validFrom
    case validUntil

    var label: String {
        switch self {
        case .surname: "Surname"
        case .givenNames: "Given names"
        case .dateOfBirth: "Date of birth"
        case .placeOfBirth: "Place of birth"
        case .sex: "Sex"
        case .nationality: "Nationality"
        case .documentNumber: "Document number"
        case .issuingAuthority: "Issuing authority"
        case .issueDate: "Issued"
        case .expiryDate: "Expires"
        case .alienNumber: "A-Number"
        case .uscisCategory: "Category"
        case .residentSince: "Resident since"
        case .address: "Address"
        case .leaseStartDate: "Lease start"
        case .leaseEndDate: "Lease end"
        case .licenseClass: "Class"
        case .receiptNumber: "Receipt number"
        case .noticeDate: "Notice date"
        case .formType: "Form"
        case .classOfAdmission: "Class of admission"
        case .admitUntil: "Admit until"
        case .i94Number: "I-94 number"
        case .validFrom: "Valid from"
        case .validUntil: "Valid until"
        }
    }

    /// High-sensitivity facts are encrypted to the Face ID–gated key and shown masked.
    var isSensitive: Bool {
        switch self {
        case .documentNumber, .alienNumber, .receiptNumber, .i94Number: true
        default: false
        }
    }

    var isDate: Bool {
        switch self {
        case .dateOfBirth, .issueDate, .expiryDate, .residentSince, .leaseStartDate, .leaseEndDate, .noticeDate, .admitUntil, .validFrom, .validUntil: true
        default: false
        }
    }

    /// Identifiers are set in SF Mono so that O/0 and I/1 can't be confused.
    var isMonospaced: Bool { isSensitive || isDate }

    /// Order of fields on a document's detail screen.
    var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
