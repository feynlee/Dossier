import Charts
import SwiftUI

/// The strip shared by all Timeline views: homes as bands, trips as ticks, gaps as orange hatching, today
/// as a line. Tap or drag to choose a year.
struct YearScrubber: View {
    let timeline: LifeTimeline
    @Binding var selectedYear: Int

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
            .chartDateSelection { date in
                let year = SimpleDate(utc: date).year
                if years.contains(year) { selectedYear = year }
            }
            .frame(height: 70)

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

extension View {
    /// Tap or drag across a chart's plot area to pick a date. Charts' own selection doesn't receive touches
    /// inside a List row, so this reads the position through the chart proxy instead.
    func chartDateSelection(_ onSelect: @escaping (Date) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = value.location.x - geometry[plotFrame].origin.x
                                if let date: Date = proxy.value(atX: x) { onSelect(date) }
                            }
                    )
            }
        }
    }
}
