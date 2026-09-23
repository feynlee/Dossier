import Charts
import SwiftUI

/// The strip shared by all Timeline views: homes as bands, trips as ticks, gaps as orange hatching, today
/// as a line. Tap or drag to choose a year.
struct YearScrubber: View {
    let timeline: LifeTimeline
    @Binding var selectedYear: Int

    @State private var rawSelection: Date?

    private var years: ClosedRange<Int> { timeline.years }

    var body: some View {
        VStack(spacing: 6) {
            Chart {
                if let start = SimpleDate(year: selectedYear, month: 1, day: 1), let end = SimpleDate(year: selectedYear + 1, month: 1, day: 1) {
                    RectangleMark(xStart: .value("From", start.date), xEnd: .value("To", end.date))
                        .foregroundStyle(Color.dsTintSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                ForEach(Array(timeline.homes.enumerated()), id: \.offset) { index, home in
                    let isSelected = timeline.homes(in: selectedYear).contains(home)
                    RectangleMark(
                        xStart: .value("Moved in", home.start.date),
                        xEnd: .value("Moved out", (home.end ?? timeline.today).date),
                        y: .value("Lane", "Homes"),
                        height: 20
                    )
                    .foregroundStyle(isSelected ? Color.dsTintFill : Color.dsTintSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("Home \(index + 1): \(intervalText(home.start, home.end))")
                }
                ForEach(timeline.gaps, id: \.start) { gap in
                    RectangleMark(xStart: .value("Gap from", gap.start.date), xEnd: .value("Gap to", gap.end.date), y: .value("Lane", "Homes"), height: 20)
                        .foregroundStyle(Color.dsWarning.opacity(0.35))
                        .accessibilityLabel("No address on file, \(intervalText(gap.start, gap.end))")
                }
                ForEach(timeline.trips) { trip in
                    PointMark(x: .value("Departed", trip.departure.date), y: .value("Lane", "Trips"))
                        .symbol { Capsule().fill(Color.dsTint).frame(width: 3, height: 12) }
                        .accessibilityLabel("Trip from \(trip.departure.display)")
                }
                RuleMark(x: .value("Today", timeline.today.date))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartYAxis(.hidden)
            .chartXScale(domain: (SimpleDate(year: years.lowerBound, month: 1, day: 1) ?? .distantPast).date...(SimpleDate(year: years.upperBound + 1, month: 1, day: 1) ?? .distantFuture).date)
            .chartXAxis {
                AxisMarks(values: .stride(by: .year)) { value in
                    AxisValueLabel(format: .dateTime.year(.twoDigits), centered: true)
                }
            }
            .chartXSelection(value: $rawSelection)
            .frame(height: 70)
            .onChange(of: rawSelection) { _, date in
                if let date { selectedYear = SimpleDate(utc: date).year }
            }

            HStack {
                Button("Previous year", systemImage: "chevron.left") { selectedYear -= 1 }
                    .disabled(selectedYear <= years.lowerBound)
                Spacer()
                Text(String(selectedYear)).font(.headline).monospacedDigit()
                Spacer()
                Button("Next year", systemImage: "chevron.right") { selectedYear += 1 }
                    .disabled(selectedYear >= years.upperBound)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .sensoryFeedback(.selection, trigger: selectedYear)
    }
}
