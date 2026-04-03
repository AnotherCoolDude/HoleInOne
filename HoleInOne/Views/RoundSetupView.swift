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
    @State private var mappedPins: Int = 0

    // Course overview image loaded from club website
    @State private var overviewImage: UIImage?
    @State private var isLoadingOverview = false

    @Environment(\.modelContext) private var modelContext

    private var totalHoles: Int { course?.holes.count ?? 18 }

    private var displayName: String    { course?.name    ?? preloadName    }
    private var displayCity: String    { course?.city    ?? preloadCity    }
    private var displayCountry: String { course?.country ?? preloadCountry }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // Course overview image (Platzuebersicht) — shown when available
                courseOverviewImage
                    .padding(.top, overviewImage == nil ? 24 : 0)

                // Header — always visible the moment you navigate here
                VStack(spacing: 6) {
                    Text(displayName)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("\(displayCity), \(displayCountry)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, overviewImage == nil ? 0 : 4)

                // Status banner — transitions from blue "fetching" → GPS badge
                statusBanner
                    .padding(.horizontal)

                // Player-recorded GPS progress (always shown once course loaded)
                if !isLoadingCourse {
                    playerGPSBadge
                        .padding(.horizontal)
                }

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

                // Start Round button — greyed out while loading
                startButton
                    .padding(.horizontal)
                    .padding(.bottom, 24)
            }
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
            mappedPins  = LearnedGPSStore(modelContext: modelContext).mappedPinCount(courseId: courseId)
            await loadCourse()
            // Load overview image after course is available (URL may come from course or scraper cache)
            await loadOverviewImage()
        }
    }

    // MARK: - Course overview image

    @ViewBuilder
    private var courseOverviewImage: some View {
        if let image = overviewImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: "map.fill")
                            .font(.caption2)
                        Text("Course overview")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                }
        } else if isLoadingOverview {
            // Placeholder shimmer while image loads
            RoundedRectangle(cornerRadius: 0)
                .fill(Color.secondary.opacity(0.12))
                .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60)
                .overlay {
                    ProgressView()
                        .tint(.secondary)
                }
        }
        // Fallback: club photo from Wikipedia / og:image when no Platzuebersicht found
        if overviewImage == nil && !isLoadingOverview {
            CoursePhotoView(
                courseId: courseId,
                clubName: preloadName,
                city: preloadCity,
                country: preloadCountry,
                size: .banner(height: 200)
            )
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
                Text("Searching OpenStreetMap, then satellite imagery if needed")
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
            gpsQualityBadge(for: course?.osmQuality ?? .none, source: course?.gpsSource ?? .osm)
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

    // MARK: - Overview image loading

    private func loadOverviewImage() async {
        // Use URL baked into the course model (filled in by ClubWebsiteScraper via toGolfCourse)
        guard let imageURL = course?.overviewImageURL else { return }
        isLoadingOverview = true
        defer { isLoadingOverview = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: imageURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else { return }
            overviewImage = image
        } catch {
            // Silently ignore — overview image is decorative, not critical
            #if DEBUG
            print("[RoundSetupView] Failed to load overview image: \(error.localizedDescription)")
            #endif
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

    // MARK: - Player GPS badge

    @ViewBuilder
    private var playerGPSBadge: some View {
        if mappedPins == 0 {
            bannerRow(color: .indigo) {
                Image(systemName: "figure.walk").foregroundStyle(.indigo)
            } title: {
                Text("No holes mapped by you yet")
                    .font(.caption.bold()).foregroundStyle(.indigo)
            } detail: {
                Text("Walk the course and tap \"Mark Pin\" on each hole to build your own GPS data.")
            }
        } else if mappedPins < totalHoles {
            bannerRow(color: .indigo) {
                Image(systemName: "location.fill.viewfinder").foregroundStyle(.indigo)
            } title: {
                Text("Your GPS: \(mappedPins)/\(totalHoles) holes mapped")
                    .font(.caption.bold()).foregroundStyle(.indigo)
            } detail: {
                Text("Keep playing to map the remaining \(totalHoles - mappedPins) holes.")
            }
        } else {
            bannerRow(color: .indigo) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.indigo)
            } title: {
                Text("Your GPS: all \(totalHoles) holes mapped")
                    .font(.caption.bold()).foregroundStyle(.indigo)
            } detail: {
                Text("Full pin distances available from your own recorded data.")
            }
        }
    }

    // MARK: - GPS quality badge

    @ViewBuilder
    private func gpsQualityBadge(
        for quality: OSMHoleData.GPSQuality,
        source: OSMHoleData.DataSource = .osm
    ) -> some View {
        let sourceName: String = {
            switch source {
            case .osm:       return "OpenStreetMap"
            case .satellite: return "satellite imagery"
            case .bundled:   return "bundled data"
            }
        }()
        let sourceIcon: String = source == .satellite ? "camera.aperture" : "map"

        switch quality {
        case .full(let n):
            bannerRow(color: .green) {
                Image(systemName: "location.fill").foregroundStyle(.green)
            } title: {
                Text("GPS: \(n)/\(n) holes via \(sourceName)")
                    .font(.caption.bold()).foregroundStyle(.green)
            } detail: {
                Text("Pin distances fully available.")
            }
        case .partial(let found, let total):
            bannerRow(color: .orange) {
                Image(systemName: sourceIcon).foregroundStyle(.orange)
            } title: {
                Text("GPS: \(found)/\(total) holes via \(sourceName)")
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
                Text("No hole coordinates found. Walk the course and tap \"Mark Pin\" to build your own GPS data.")
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
