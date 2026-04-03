import SwiftData
import SwiftUI

struct RoundSetupView: View {
    // Basic info available immediately (from search result or SavedCourse)
    let courseId: String
    let preloadName: String
    let preloadCity: String
    let preloadCountry: String

    // Loaded asynchronously in the background
    @State private var course: GolfCourse?
    @State private var isLoadingCourse = true
    @State private var loadError: String?

    @State private var selection: Round.HoleSelection = .all18
    @State private var isFavourite = false
    @Environment(\.modelContext) private var modelContext

    private var displayName: String    { course?.name    ?? preloadName    }
    private var displayCity: String    { course?.city    ?? preloadCity    }
    private var displayCountry: String { course?.country ?? preloadCountry }

    var body: some View {
        VStack(spacing: 28) {

            // Header — always visible the moment you navigate here
            VStack(spacing: 6) {
                Text(displayName)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("\(displayCity), \(displayCountry)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            // Status banner — transitions from blue "fetching" → GPS badge
            statusBanner
                .padding(.horizontal)

            // Hole picker
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

            if !isLoadingCourse, course != nil {
                VStack(spacing: 4) {
                    Text("\(selection.holeNumbers.count) holes")
                        .font(.title.bold())
                    Text("Holes \(selection.holeNumbers.first!)–\(selection.holeNumbers.last!)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Start Round button — greyed out while loading
            startButton
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
        .navigationTitle("Setup Round")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { toggleFavourite() } label: {
                    Image(systemName: isFavourite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavourite ? .red : .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(isFavourite ? "Remove from favourites" : "Add to favourites")
            }
        }
        .task {
            isFavourite = SwingHistoryStore(modelContext: modelContext).isFavourite(courseId: courseId)
            await loadCourse()
        }
    }

    // MARK: - Status banner

    @ViewBuilder
    private var statusBanner: some View {
        if isLoadingCourse {
            infoBanner(
                icon: { AnyView(ProgressView().tint(.blue)) },
                color: .blue,
                title: "Fetching hole data…",
                detail: "Finding hole locations via OpenStreetMap"
            )
        } else if let error = loadError {
            infoBanner(
                icon: { AnyView(Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)) },
                color: .red,
                title: "Could not load course",
                detail: error
            )
        } else {
            gpsQualityBadge(for: course?.osmQuality ?? .none)
        }
    }

    // MARK: - Start button

    @ViewBuilder
    private var startButton: some View {
        if let course {
            NavigationLink(destination: RoundView(round: Round(course: course, selection: selection))) {
                startLabel
                    .background(Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        } else {
            startLabel
                .background(Color.secondary.opacity(0.2))
                .foregroundStyle(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var startLabel: some View {
        Label("Start Round", systemImage: "flag.fill")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
    }

    // MARK: - Course loading

    private func loadCourse() async {
        isLoadingCourse = true
        defer { isLoadingCourse = false }
        do {
            guard let id = Int(courseId) else {
                // Bundled course (non-integer String ID)
                let courses = try GolfAPIService.shared.loadBundledCourses()
                course = courses.first { $0.id == courseId }
                if course == nil { loadError = "Course not found." }
                return
            }
            let apiResult = try await GolfAPIService.shared.fetchCourse(id: id)
            let profile = PlayerProfile.shared
            course = await GolfAPIService.shared.toGolfCourse(
                apiResult,
                teeGender: profile.teeGender.rawValue,
                preferredTeeName: profile.preferredTeeName
            )
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Favourite toggle

    private func toggleFavourite() {
        let store = SwingHistoryStore(modelContext: modelContext)
        isFavourite = store.toggleFavourite(
            courseId: courseId,
            courseName: displayName,
            city: displayCity,
            country: displayCountry
        )
    }

    // MARK: - GPS quality badge

    @ViewBuilder
    private func gpsQualityBadge(for quality: OSMHoleData.GPSQuality) -> some View {
        switch quality {
        case .full(let n):
            infoBanner(
                icon: { AnyView(Image(systemName: "location.fill").foregroundStyle(.green)) },
                color: .green,
                title: "GPS: \(n)/\(n) holes via OpenStreetMap",
                detail: "Pin distances fully available."
            )
        case .partial(let found, let total):
            infoBanner(
                icon: { AnyView(Image(systemName: "location").foregroundStyle(.orange)) },
                color: .orange,
                title: "GPS: \(found)/\(total) holes via OpenStreetMap",
                detail: "Pin distances available for \(found) holes. Remaining holes use course centre."
            )
        case .none:
            infoBanner(
                icon: { AnyView(Image(systemName: "location.slash").foregroundStyle(.red)) },
                color: .red,
                title: "GPS unavailable",
                detail: "No hole coordinates found in OpenStreetMap. Par, yardage, and swing tracking still work."
            )
        }
    }

    // MARK: - Shared banner layout

    private func infoBanner<Icon: View>(
        icon: () -> Icon,
        color: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
