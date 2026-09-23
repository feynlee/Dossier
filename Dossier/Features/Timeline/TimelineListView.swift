import SwiftUI

/// Timeline › List: the scrubber, then everything in the selected year.
struct TimelineListView: View {
    let timeline: LifeTimeline
    @Binding var selectedYear: Int
    let onFillGap: (LifeTimeline.Gap) -> Void

    var body: some View {
        let homes = timeline.homes(in: selectedYear)
        let trips = timeline.trips(in: selectedYear)
        let statuses = timeline.statuses(in: selectedYear)
        let gaps = timeline.gaps(in: selectedYear)

        List {
            Section {
                YearScrubber(timeline: timeline, selectedYear: $selectedYear)
            } footer: {
                if !timeline.gaps.isEmpty { Text("Orange marks a gap in your address history.") }
            }

            Section {
                if homes.isEmpty, trips.isEmpty, statuses.isEmpty, gaps.isEmpty {
                    Text("Nothing on record for \(String(selectedYear)).").foregroundStyle(.secondary)
                }
                ForEach(homes) { home in
                    TileRow(symbol: "house", badge: .verified, title: home.address, subtitle: "Home · \(intervalText(home.start, home.end))")
                }
                ForEach(gaps, id: \.start) { gap in
                    Button { onFillGap(gap) } label: {
                        TileRow(symbol: "house", badge: .expiring, title: intervalText(gap.start, gap.end), subtitle: "No address on file · Add one", subtitleIsWarning: true)
                    }
                    .foregroundStyle(.primary)
                }
                ForEach(trips) { trip in
                    NavigationLink(value: trip) {
                        TileRow(symbol: "airplane", badge: trip.isMissingReturn ? .review : .verified, title: trip.destination ?? "Outside the US", subtitle: tripSubtitle(trip))
                    }
                }
                ForEach(statuses) { status in
                    TileRow(symbol: "checkmark.shield", badge: .verified, title: status.name, subtitle: "Status · \(intervalText(status.start, status.end))")
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(selectedYear)).font(.title2.bold()).foregroundStyle(.primary).textCase(nil)
                    Spacer()
                    let days = timeline.daysAbroad(in: selectedYear)
                    Text(days == 1 ? "1 day abroad" : "\(days) days abroad").textCase(nil)
                }
            }
        }
    }

    private func tripSubtitle(_ trip: LifeTimeline.Trip) -> String {
        if trip.isMissingReturn { return "Left \(trip.departure.display) · return not on record" }
        let days = trip.days(today: timeline.today)
        let range = trip.arrival.map { "\(trip.departure.display) – \($0.display)" } ?? "Left \(trip.departure.display)"
        return "\(range) · \(days) days"
    }
}
