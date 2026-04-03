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
            bannerRow(color: .blue) {
                ProgressView().tint(.blue)
            } title: {
                Text("Fetching hole data…")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
            } detail: {
                Text("Finding hole locations via OpenStreetMap")
            }
        } else if let error = loadError {
            bannerRow(color: .red) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            } title: {
                Text("Could not load course")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            } detail: {
                Text(error)
            }
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
            bannerRow(color: .green) {
                Image(systemName: "location.fill").foregroundStyle(.green)
            } title: {
                Text("GPS: \(n)/\(n) holes via OpenStreetMap")
                    .font(.caption.bold()).foregroundStyle(.green)
            } detail: {
                Text("Pin distances fully available.")
            }
        case .partial(let found, let total):
            bannerRow(color: .orange) {
                Image(systemName: "location").foregroundStyle(.orange)
            } title: {
                Text("GPS: \(found)/\(total) holes via OpenStreetMap")
                    .font(.caption.bold()).foregroundStyle(.orange)
            } detail: {
                Text("Pin distances available for \(found) holes. Remaining holes use course centre.")
            }
        case .none:
            bannerRow(color: .red) {
                Image(systemName: "location.slash").foregroundStyle(.red)
            } title: {
                Text("GPS unavailable")
                    .font(.caption.bold()).foregroundStyle(.red)
            } detail: {
                Text("No hole coordinates found in OpenStreetMap. Par, yardage, and swing tracking still work.")
            }
        }
    }

    // MARK: - Shared banner layout (no AnyView — concrete @ViewBuilder parameters only)

    private func bannerRow<Icon: View, Title: View, Detail: View>(
        color: Color,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder title: () -> Title,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                title()
                detail()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
