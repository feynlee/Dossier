import Foundation
import LocalAuthentication

/// Answers "what's my X" for forms from your compiled personal information, so forms use the same values
/// you see (and may have edited) in Personal information.
struct FactBook {
    let documents: [SourceDocument]
    let profile: Profile
    let timeline: LifeTimeline

    init(documents: [SourceDocument], overrides: [ProfileOverride] = []) {
        let ready = documents.filter(\.isReady)
        self.documents = ready
        self.timeline = TimelineLoader.timeline(from: ready)
        self.profile = Profile.build(documents: ready, overrides: overrides, timeline: timeline)
    }

    /// The value as it should be written into a field. Sensitive values need a context that passed Face ID.
    func string(for value: FormValue, dateStyle: FormDateStyle, context: LAContext?) -> String? {
        switch value {
        case .familyName: return profile.value(.surname, context: context)
        case .givenName: return profile.value(.givenNames, context: context)?.split(separator: " ").first.map(String.init)
        case .middleName:
            let names = profile.value(.givenNames, context: context)?.split(separator: " ") ?? []
            return names.count > 1 ? names.dropFirst().joined(separator: " ") : nil
        case .dateOfBirth: return profile.value(.dateOfBirth, context: context).flatMap(SimpleDate.init(iso:)).map(dateStyle.format)
        case .placeOfBirth: return profile.value(.placeOfBirth, context: context)
        case .sex: return profile.value(.sex, context: context)
        case .nationality: return profile.value(.nationality, context: context)
        case .passportNumber: return profile.value(.passportNumber, context: context)
        case .alienNumber: return profile.value(.alienNumber, context: context)
        case .licenceNumber: return profile.value(.licenceNumber, context: context)
        case .passportExpiry:
            return passportFact(.expiryDate).flatMap { VaultReader.value(of: $0) }.flatMap(SimpleDate.init(iso:)).map(dateStyle.format)
        case .i94Number:
            guard let context, let fact = documents.first(where: { $0.kind == .i94 })?.fact(.i94Number) else { return nil }
            return try? VaultReader.reveal(fact, context: context)
        case .lastArrivalDate:
            return timeline.trips.compactMap(\.arrival).max().map(dateStyle.format)
        case .street, .unit, .city, .state, .postalCode:
            guard let address = profile.value(.currentAddress, context: context) else { return nil }
            let parts = AddressParts(address)
            switch value {
            case .street: return parts.street
            case .unit: return parts.unit
            case .city: return parts.city
            case .state: return parts.state
            default: return parts.postalCode
            }
        }
    }

    /// Whether a value is available at all (without opening sensitive ones).
    func has(_ value: FormValue) -> Bool {
        switch value {
        case .passportNumber: available(.passportNumber)
        case .alienNumber: available(.alienNumber)
        case .licenceNumber: available(.licenceNumber)
        case .i94Number: documents.contains { $0.kind == .i94 && $0.fact(.i94Number) != nil }
        case .passportExpiry: passportFact(.expiryDate) != nil
        case .unit: string(for: .unit, dateStyle: .monthDayYear, context: nil) != nil
        case .middleName: string(for: .middleName, dateStyle: .monthDayYear, context: nil) != nil
        default: string(for: value, dateStyle: .monthDayYear, context: nil) != nil
        }
    }

    /// `•••• •• 4821` for a sensitive value, for the list of fields before filling.
    func masked(_ value: FormValue) -> String? {
        switch value {
        case .passportNumber: profile.masked(.passportNumber)
        case .alienNumber: profile.masked(.alienNumber)
        case .licenceNumber: profile.masked(.licenceNumber)
        case .i94Number: documents.first { $0.kind == .i94 }?.fact(.i94Number).map { VaultReader.masked($0) }
        default: nil
        }
    }

    private func available(_ key: ProfileKey) -> Bool {
        guard let entry = profile.entry(key) else { return false }
        return entry.override != nil || entry.fact != nil
    }

    private func passportFact(_ key: FactKey) -> Fact? {
        profile.entry(.passportNumber)?.fact?.document?.fact(key)
    }
}
