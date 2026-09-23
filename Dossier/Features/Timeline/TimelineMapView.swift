import MapKit
import SwiftUI

/// Timeline › Map: homes as numbered pins joined by dotted moves, and trips (with a destination you added) as
/// arcs from the home you lived in at the time. Only the selected year's trips are drawn, so the map stays
/// readable; the scrubber moves the camera to that year's home.
struct TimelineMapView: View {
    let timeline: LifeTimeline
    @Binding var selectedYear: Int
    let geocoder: Geocoder

    @State private var position = MapCameraPosition.automatic

    private var selectedHome: LifeTimeline.Home? {
        timeline.homes(in: selectedYear).last
    }

    private var destinations: [String] {
        timeline.trips.compactMap(\.destination)
    }

    var body: some View {
        Map(position: $position) {
            let located = timeline.homes.enumerated().compactMap { index, home in
                geocoder.coordinate(for: home.address).map { (index, home, $0) }
            }
            if located.count > 1 {
                MapPolyline(coordinates: located.map(\.2))
                    .stroke(Color.dsTint, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 7]))
            }
            ForEach(located, id: \.1.id) { index, home, coordinate in
                Annotation(home.address, coordinate: coordinate) {
                    HomePin(number: index + 1, isSelected: home == selectedHome)
                }
                .annotationTitles(home == selectedHome ? .visible : .hidden)
            }
            ForEach(timeline.trips(in: selectedYear)) { trip in
                if let destination = trip.destination,
                   let to = geocoder.coordinate(for: destination),
                   let from = timeline.home(on: trip.departure).flatMap({ geocoder.coordinate(for: $0.address) }) {
                    MapPolyline(coordinates: [from, to], contourStyle: .geodesic)
                        .stroke(Color.dsTint.opacity(0.8), lineWidth: 2)
                    Marker(destination, systemImage: "airplane", coordinate: to)
                        .tint(Color.dsTint)
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let home = selectedHome {
                    let number = (timeline.homes.firstIndex(of: home) ?? 0) + 1
                    HStack(alignment: .firstTextBaseline) {
                        Text(home.address).font(.headline)
                        Spacer()
                        Text("Home \(number) of \(timeline.homes.count)").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("\(intervalText(home.start, home.end)) · \(home.source)").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("No home on record for \(String(selectedYear))").font(.headline)
                }
                let trips = timeline.trips(in: selectedYear)
                if !trips.isEmpty {
                    Text(trips.count == 1 ? "1 trip this year" : "\(trips.count) trips this year").font(.footnote).foregroundStyle(.secondary)
                }
                YearScrubber(timeline: timeline, selectedYear: $selectedYear)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .task(id: timeline.homes.map(\.address) + destinations) {
            await geocoder.resolve(timeline.homes.map(\.address) + destinations)
            focus()
        }
        .onChange(of: selectedYear) { focus() }
    }

    private func focus() {
        guard let home = selectedHome, let coordinate = geocoder.coordinate(for: home.address) else { return }
        withAnimation(.snappy) {
            position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 400_000, longitudinalMeters: 400_000))
        }
    }
}

private struct HomePin: View {
    let number: Int
    let isSelected: Bool

    var body: some View {
        Text("\(number)")
            .font(.caption.bold())
            .foregroundStyle(isSelected ? .white : Color.dsTint)
            .frame(width: 26, height: 26)
            .background(Circle().fill(isSelected ? Color.dsTintFill : Color(uiColor: .systemBackground)))
            .overlay(Circle().stroke(isSelected ? Color.white : Color.dsTint, lineWidth: 2.5))
            .accessibilityLabel("Home \(number)")
    }
}
