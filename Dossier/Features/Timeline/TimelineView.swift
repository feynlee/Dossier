import SwiftData
import SwiftUI

/// The Timeline tab: one history shown three ways — List, Map and Overview — driven by one selected year.
struct TimelineView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case list = "List"
        case map = "Map"
        case overview = "Overview"
        var id: String { rawValue }
    }

    @Query(sort: \SourceDocument.ingestedAt) private var documents: [SourceDocument]
    @State private var mode = Mode.list
    @State private var selectedYear = SimpleDate.today.year
    @State private var timeline = LifeTimeline(homes: [], statuses: [], documents: [], travel: [], today: .today)
    @State private var geocoder = Geocoder()
    @State private var gapToFill: LifeTimeline.Gap?

    var body: some View {
        NavigationStack {
            Group {
                if timeline.isEmpty {
                    ContentUnavailableView {
                        Label("No history yet", systemImage: "clock")
                    } description: {
                        Text("Leases, licences, immigration documents and I-94 travel records you add to your folder will appear here.")
                    }
                } else {
                    switch mode {
                    case .list: TimelineListView(timeline: timeline, selectedYear: $selectedYear, onFillGap: { gapToFill = $0 })
                    case .map: TimelineMapView(timeline: timeline, selectedYear: $selectedYear, geocoder: geocoder)
                    case .overview: TimelineOverviewView(timeline: timeline)
                    }
                }
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(mode == .map ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if mode == .map { modePicker.frame(width: 260) }
                }
            }
            .safeAreaInset(edge: .top) {
                if mode != .map {
                    modePicker
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationDestination(for: LifeTimeline.Trip.self) { trip in
                TripDetailView(trip: trip, timeline: timeline, documents: documents) { reload() }
            }
            .sheet(item: $gapToFill) { gap in
                AddAddressView(gap: gap) { reload() }
            }
        }
        .task(id: documents.map(\.persistentModelID)) { reload() }
        .onAppear { reload() }
    }

    private var modePicker: some View {
        Picker("View", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private func reload() {
        timeline = TimelineLoader.timeline(from: documents)
        if !timeline.years.contains(selectedYear) { selectedYear = timeline.years.upperBound }
    }
}

extension LifeTimeline.Gap: Identifiable {
    var id: String { start.iso }
}

/// "Aug 2020 – Jul 2022", or "Jan 2023 – now".
nonisolated func intervalText(_ start: SimpleDate?, _ end: SimpleDate?) -> String {
    let from = start?.monthYear ?? "?"
    guard let end else { return "\(from) – now" }
    return from == end.monthYear ? from : "\(from) – \(end.monthYear)"
}

nonisolated func dayRangeText(_ start: SimpleDate, _ end: SimpleDate?) -> String {
    guard let end else { return "\(start.display) – now" }
    return "\(start.display) – \(end.display)"
}
