import Charts
import SwiftUI

/// Timeline › Overview: homes, status, documents and trips as swimlanes on one axis, days abroad per year,
/// and a crosshair that answers "on this date".
struct TimelineOverviewView: View {
    let timeline: LifeTimeline

    @State private var selectedDate: Date?

    private var domain: ClosedRange<Date> {
        let years = timeline.years
        return (SimpleDate(year: years.lowerBound, month: 1, day: 1) ?? .distantPast).date...(SimpleDate(year: years.upperBound + 1, month: 1, day: 1) ?? .distantFuture).date
    }

    var body: some View {
        List {
            Section {
                lanes
                    .frame(height: CGFloat(80 + 26 * laneCount))
            } footer: {
                Text("Tap or drag across the chart to see a date.")
            }

            if let selectedDate {
                OnDateCard(timeline: timeline, date: SimpleDate(utc: selectedDate))
            }

            Section("Days outside the US") {
                daysAbroad.frame(height: 150)
            }
        }
    }

    private var laneCount: Int { 3 + timeline.documents.count }

    private var lanes: some View {
        Chart {
            ForEach(timeline.homes) { home in
                band(lane: "Homes", name: home.address.components(separatedBy: ",").first ?? home.address, start: home.start, end: home.end)
            }
            ForEach(timeline.gaps, id: \.start) { gap in
                RectangleMark(xStart: .value("From", gap.start.date), xEnd: .value("To", gap.end.date), y: .value("Lane", "Homes"), height: 18)
                    .foregroundStyle(Color.dsWarning.opacity(0.35))
            }
            ForEach(timeline.statuses) { status in
                band(lane: "Status", name: status.name, start: status.start, end: status.end)
            }
            ForEach(timeline.documents) { document in
                band(lane: document.name, name: "", start: document.start, end: document.end)
            }
            ForEach(timeline.trips) { trip in
                PointMark(x: .value("Departed", trip.departure.date), y: .value("Lane", "Trips"))
                    .symbol { Capsule().fill(Color.dsTint).frame(width: 3, height: 14) }
            }
            if let selectedDate {
                RuleMark(x: .value("Selected", selectedDate))
                    .foregroundStyle(Color.dsTint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            RuleMark(x: .value("Today", timeline.today.date))
                .foregroundStyle(.primary)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .year)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.year(.twoDigits), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let lane = value.as(String.self) { Text(lane).font(.caption2).lineLimit(1) }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
    }

    @ChartContentBuilder
    private func band(lane: String, name: String, start: SimpleDate?, end: SimpleDate?) -> some ChartContent {
        let from = start ?? SimpleDate(utc: domain.lowerBound)
        let to = end ?? timeline.today
        let active = selectedDate.map { SimpleDate(utc: $0) }.map { from <= $0 && $0 <= to } ?? (end == nil)
        RectangleMark(xStart: .value("From", from.date), xEnd: .value("To", min(to.date, domain.upperBound)), y: .value("Lane", lane), height: 18)
            .foregroundStyle(active ? Color.dsTintFill : Color.dsTintSoft)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .annotation(position: .overlay, alignment: .leading) {
                if !name.isEmpty {
                    Text(name).font(.system(size: 9, weight: .semibold)).foregroundStyle(active ? Color.white : Color.primary).padding(.leading, 4).lineLimit(1)
                }
            }
    }

    private var daysAbroad: some View {
        Chart(Array(timeline.years), id: \.self) { year in
            let days = timeline.daysAbroad(in: year)
            BarMark(x: .value("Year", String(year)), y: .value("Days", days))
                .foregroundStyle(days > 0 ? Color.dsTintFill : Color.dsTintSoft)
                .annotation(position: .top) {
                    if days > 0 { Text("\(days)").font(.caption2).foregroundStyle(.secondary) }
                }
        }
        .chartYAxis(.hidden)
    }
}

/// "On 15 Mar 2023": where you lived, your status, and which documents were valid.
private struct OnDateCard: View {
    let timeline: LifeTimeline
    let date: SimpleDate

    var body: some View {
        Section("On \(date.display)") {
            LabeledContent("Home", value: timeline.home(on: date)?.address ?? "Not on record")
            let statuses = timeline.statuses(on: date)
            LabeledContent("Status", value: statuses.isEmpty ? "Not on record" : statuses.map(\.name).joined(separator: ", "))
            let documents = timeline.validDocuments(on: date)
            LabeledContent("Valid documents", value: documents.isEmpty ? "None on record" : documents.map(\.name).joined(separator: ", "))
            if let trip = timeline.trips.first(where: { $0.departure <= date && date < ($0.arrival ?? ($0.isOngoing ? timeline.today : $0.departure)) }) {
                LabeledContent("Travelling", value: trip.destination ?? "Outside the US")
            }
        }
    }
}
