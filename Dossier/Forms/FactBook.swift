import Foundation
import LocalAuthentication

/// Answers "what's my X" from verified facts, picking the right document for each value: passport details
/// from the passport, the A-Number from immigration documents, the address from your current home.
struct FactBook {
    let documents: [SourceDocument]
    let timeline: LifeTimeline

    init(documents: [SourceDocument]) {
        self.documents = documents
        self.timeline = TimelineLoader.timeline(from: documents)
    }

    /// The fact backing a value, if any, preferring verified facts and newer documents.
    func fact(for value: FormValue) -> Fact? {
        switch value {
        case .familyName: return fact(.surname, in: [.passport, .greenCard, .employmentAuthorization, .driversLicense, .stateID])
        case .givenName, .middleName: return fact(.givenNames, in: [.passport, .greenCard, .employmentAuthorization, .driversLicense, .stateID])
        case .dateOfBirth: return fact(.dateOfBirth, in: [.passport, .greenCard, .employmentAuthorization, .driversLicense, .stateID])
        case .placeOfBirth: return fact(.placeOfBirth, in: [.passport, .greenCard, .employmentAuthorization])
        case .sex: return fact(.sex, in: [.passport, .greenCard, .driversLicense, .stateID])
        case .nationality: return fact(.nationality, in: [.passport, .greenCard, .employmentAuthorization])
        case .passportNumber: return fact(.documentNumber, in: [.passport])
        case .passportExpiry: return fact(.expiryDate, in: [.passport])
        case .alienNumber: return fact(.alienNumber, in: [.greenCard, .employmentAuthorization, .uscisNotice])
        case .i94Number: return fact(.i94Number, in: [.i94])
        case .licenceNumber: return fact(.documentNumber, in: [.driversLicense, .stateID])
        case .lastArrivalDate, .street, .unit, .city, .state, .postalCode: return nil
        }
    }

    /// The value as it should be written into a field. Sensitive values need a context that passed Face ID.
    func string(for value: FormValue, dateStyle: FormDateStyle, context: LAContext?) -> String? {
        switch value {
        case .lastArrivalDate:
            return timeline.trips.compactMap(\.arrival).max().map(dateStyle.format)
        case .street, .unit, .city, .state, .postalCode:
            guard let address = currentAddress else { return nil }
            let parts = AddressParts(address)
            switch value {
            case .street: return parts.street
            case .unit: return parts.unit
            case .city: return parts.city
            case .state: return parts.state
            default: return parts.postalCode
            }
        default:
            guard let fact = fact(for: value) else { return nil }
            let raw: String?
            if fact.isSensitive {
                guard let context else { return nil }
                raw = try? VaultReader.reveal(fact, context: context)
            } else {
                raw = VaultReader.value(of: fact)
            }
            guard let raw else { return nil }
            if value.isDate { return SimpleDate(iso: raw).map(dateStyle.format) ?? raw }
            switch value {
            case .givenName: return raw.split(separator: " ").first.map(String.init)
            case .middleName:
                let names = raw.split(separator: " ")
                return names.count > 1 ? names.dropFirst().joined(separator: " ") : nil
            default: return raw
            }
        }
    }

    /// Whether a value is available at all (without opening sensitive ones).
    func has(_ value: FormValue) -> Bool {
        switch value {
        case .lastArrivalDate: timeline.trips.contains { $0.arrival != nil }
        case .street, .city, .state, .postalCode: currentAddress != nil
        case .unit: currentAddress.map { AddressParts($0).unit != nil } ?? false
        case .middleName: fact(for: .middleName).flatMap { VaultReader.value(of: $0) }.map { $0.contains(" ") } ?? false
        default: fact(for: value) != nil
        }
    }

    private var currentAddress: String? {
        timeline.home(on: timeline.today)?.address ?? timeline.homes.last?.address
    }

    private func fact(_ key: FactKey, in kinds: [DocumentKind]) -> Fact? {
        let candidates = documents
            .filter { kinds.contains($0.kind) }
            .sorted { (kinds.firstIndex(of: $0.kind) ?? 0, $1.ingestedAt) < (kinds.firstIndex(of: $1.kind) ?? 0, $0.ingestedAt) }
            .compactMap { $0.fact(key) }
        return candidates.first { $0.status == .verified } ?? candidates.first
    }
}
