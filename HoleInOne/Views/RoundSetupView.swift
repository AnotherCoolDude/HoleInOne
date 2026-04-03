import SwiftUI

struct RoundSetupView: View {
    let course: GolfCourse
    @State private var selection: Round.HoleSelection = .all18

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text(course.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("\(course.city), \(course.country)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            // OSM GPS quality badge
            gpsQualityBadge(for: course.osmQuality)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 12) {
                Text("Holes to play")
                    .font(.headline)
                Picker("Holes", selection: $selection) {
                    ForEach(Round.HoleSelection.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)

            VStack(spacing: 4) {
                Text("\(selection.holeNumbers.count) holes")
                    .font(.title.bold())
                Text("Holes \(selection.holeNumbers.first!)–\(selection.holeNumbers.last!)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            NavigationLink(destination: RoundView(round: Round(course: course, selection: selection))) {
                Label("Start Round", systemImage: "flag.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Setup Round")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - GPS quality badge

    @ViewBuilder
    private func gpsQualityBadge(for quality: OSMHoleData.GPSQuality) -> some View {
        switch quality {
        case .full(let n):
            gpsBadge(
                icon: "location.fill",
                color: .green,
                text: "GPS: \(n)/\(n) holes via OpenStreetMap",
                detail: "Pin distances fully available."
            )
        case .partial(let found, let total):
            gpsBadge(
                icon: "location",
                color: .orange,
                text: "GPS: \(found)/\(total) holes via OpenStreetMap",
                detail: "Pin distances available for \(found) holes. Remaining holes use course centre."
            )
        case .none:
            gpsBadge(
                icon: "location.slash",
                color: .red,
                text: "GPS unavailable",
                detail: "No hole coordinates found in OpenStreetMap. Par, yardage, and swing tracking still work."
            )
        }
    }

    private func gpsBadge(icon: String, color: Color, text: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
