import SwiftData
import SwiftUI

/// One trip from the I-94 history: dates, ports, where you went (entered by you), and which documents were
/// valid when you left.
struct TripDetailView: View {
    let trip: LifeTimeline.Trip
    let timeline: LifeTimeline
    let documents: [SourceDocument]
    let onChange: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var destination = ""

    var body: some View {
        List {
            Section {
                TileRow(symbol: "airplane", badge: trip.needsReview ? .review : .verified, title: "Left the US", subtitle: "\(trip.departure.display) · \(trip.departurePort)")
                if let arrival = trip.arrival {
                    TileRow(symbol: "airplane", badge: trip.needsReview ? .review : .verified, title: "Came back", subtitle: "\(arrival.display) · \(trip.arrivalPort ?? "")")
                } else {
                    TileRow(symbol: "airplane", badge: .review, title: trip.isOngoing ? "Not back yet" : "Return not on record", subtitle: trip.isOngoing ? "No arrival after this departure." : "Check your I-94 history for this arrival.")
                }
            } footer: {
                if !trip.isMissingReturn {
                    Text("\(trip.days(today: timeline.today)) days outside the US, counted in Days abroad.")
                }
            }

            Section {
                TextField("Where did you go?", text: $destination)
                    .textContentType(.addressCity)
                    .onSubmit(save)
            } header: {
                Text("Destination")
            } footer: {
                Text("I-94 records don’t say where you went. Add it to see this trip on the map.")
            }

            let valid = timeline.validDocuments(on: trip.departure)
            if !valid.isEmpty {
                Section("Valid when you left") {
                    ForEach(valid) { document in
                        TileRow(symbol: "person.text.rectangle", badge: .verified, title: document.name, subtitle: document.end.map { "Valid until \($0.display)" })
                    }
                }
            }
        }
        .navigationTitle(trip.destination ?? "Trip")
        .onAppear { destination = trip.destination ?? "" }
        .onDisappear(perform: save)
    }

    private func save() {
        let value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != (trip.destination ?? ""), let event = TimelineLoader.travelEvent(for: trip, in: documents) else { return }
        event.sealedDestination = value.isEmpty ? nil : try? Sealer.shared.seal(value, sensitive: false)
        try? modelContext.save()
        onChange()
    }
}
