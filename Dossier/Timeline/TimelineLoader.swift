import CoreLocation
import Foundation
import MapKit

/// Builds a `LifeTimeline` from the vault. Values are opened with the vault key (no Face ID: nothing here is
/// a high-sensitivity number) and kept only in memory.
enum TimelineLoader {
    static func timeline(from documents: [SourceDocument], today: SimpleDate = .today) -> LifeTimeline {
        var homes: [LifeTimeline.Home] = []
        var statuses: [LifeTimeline.Span] = []
        var spans: [LifeTimeline.Span] = []
        var travel: [LifeTimeline.TravelRow] = []

        for document in documents.owners {
            let id = document.contentHash
            let review = document.needsReview
            let text = { (key: FactKey) -> String? in document.fact(key).flatMap { VaultReader.value(of: $0) } }
            let date = { (key: FactKey) -> SimpleDate? in text(key).flatMap(SimpleDate.init(iso:)) }

            switch document.kind {
            case .lease, .addedByYou:
                if let address = text(.address), let start = date(.leaseStartDate) ?? date(.validFrom) ?? date(.issueDate) {
                    homes.append(.init(id: id, address: address, start: start, end: date(.leaseEndDate) ?? date(.validUntil), source: document.title, needsReview: review))
                }
            case .driversLicense, .stateID:
                if let address = text(.address), let start = date(.issueDate) {
                    homes.append(.init(id: id, address: address, start: start, end: nil, source: document.title, fromLicence: true, needsReview: review))
                }
            case .greenCard:
                if let start = date(.residentSince) ?? date(.issueDate) {
                    let category = text(.uscisCategory).map { " (\($0))" } ?? ""
                    statuses.append(.init(id: id, name: "Permanent resident\(category)", start: start, end: nil, source: document.title, needsReview: review))
                }
            case .employmentAuthorization:
                if let start = date(.validFrom) ?? date(.issueDate) {
                    let category = text(.uscisCategory).map { " \($0)" } ?? ""
                    statuses.append(.init(id: id, name: "EAD\(category)", start: start, end: date(.validUntil) ?? date(.expiryDate), source: document.title, needsReview: review))
                }
            case .uscisNotice, .i94:
                if let start = date(.validFrom), let name = text(.uscisCategory) ?? text(.classOfAdmission) {
                    statuses.append(.init(id: id, name: name, start: start, end: date(.validUntil) ?? date(.admitUntil), source: document.title, needsReview: review))
                }
            case .passport, .visa, .other:
                break
            }

            if [.passport, .greenCard, .employmentAuthorization, .visa, .driversLicense, .stateID].contains(document.kind),
               let expiry = date(.expiryDate) {
                spans.append(.init(id: id, name: document.title, start: date(.issueDate), end: expiry, source: document.fileName, needsReview: review))
            }

            for event in document.travel {
                guard let dateText = try? Sealer.shared.open(event.sealedDate), let day = SimpleDate(iso: dateText) else { continue }
                travel.append(.init(
                    id: event.uuid.uuidString,
                    date: day,
                    isArrival: event.isArrival,
                    port: (try? Sealer.shared.open(event.sealedPort)) ?? "",
                    destination: event.sealedDestination.flatMap { try? Sealer.shared.open($0) },
                    needsReview: review
                ))
            }
        }
        return LifeTimeline(homes: homes, statuses: statuses, documents: spans, travel: travel, today: today)
    }

    /// Finds the stored travel event behind a trip, for editing its destination.
    static func travelEvent(for trip: LifeTimeline.Trip, in documents: [SourceDocument]) -> TravelEvent? {
        for document in documents {
            for event in document.travel where event.uuid.uuidString == trip.departureID {
                return event
            }
        }
        return nil
    }
}

/// Turns addresses into coordinates with MapKit. Only the address string is sent to Apple's geocoder, never a
/// document. Results stay in memory for this launch.
@Observable
final class Geocoder {
    private(set) var coordinates: [String: CLLocationCoordinate2D] = [:]
    @ObservationIgnored private var pending: Set<String> = []

    func coordinate(for address: String) -> CLLocationCoordinate2D? { coordinates[address] }

    func resolve(_ addresses: [String]) async {
        for address in addresses where coordinates[address] == nil && !pending.contains(address) {
            pending.insert(address)
            defer { pending.remove(address) }
            guard let request = MKGeocodingRequest(addressString: address),
                  let item = try? await request.mapItems.first else { continue }
            coordinates[address] = item.location.coordinate
        }
    }
}
