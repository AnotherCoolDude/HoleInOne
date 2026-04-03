import CoreLocation
import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class CourseSearchViewModel {
    var query: String = ""
    var searchResults: [CourseAPIResult] = []
    var browseResults: [CourseAPIResult] = []
    var nearbyCourses: [CourseAPIResult] = []
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var isLoadingNearby: Bool = false
    var errorMessage: String?
    var recentCourses: [SavedCourse] = []
    var favouriteCourses: [SavedCourse] = []

    // Pagination state for browse mode
    var currentPage: Int = 1
    var totalPages: Int = 1
    var totalCourses: Int = 0
    var hasMorePages: Bool { currentPage < totalPages }

    private let api = GolfAPIService.shared
    private var searchTask: Task<Void, Never>?
    private var nearbyUserLocation: CLLocation?
    private var nearbyLoadedFor: CLLocation?   // avoid re-fetching for same area

    // MARK: - Search

    func onQueryChange(_ newQuery: String) {
        searchTask?.cancel()
        searchResults = []
        errorMessage = nil

        guard newQuery.trimmingCharacters(in: .whitespaces).count >= 2 else { return }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))   // debounce
            guard !Task.isCancelled else { return }
            await performSearch(query: newQuery)
        }
    }

    // MARK: - Browse (paginated)

    func loadFirstPage() async {
        guard !isLoading else { return }
        browseResults = []
        currentPage = 1
        await loadPage(1)
    }

    func loadNextPage() async {
        guard hasMorePages, !isLoadingMore else { return }
        await loadPage(currentPage + 1)
    }

    // MARK: - Recent courses

    func loadRecentCourses(store: SwingHistoryStore) {
        recentCourses = store.fetchRecentCourses()
    }

    // MARK: - Favourites

    func loadFavourites(store: SwingHistoryStore) {
        favouriteCourses = store.fetchFavourites()
    }

    func isFavourite(courseId: String) -> Bool {
        favouriteCourses.contains { $0.courseId == courseId }
    }

    // MARK: - Nearby courses

    /// Searches for up to 10 courses near `location`, using reverse geocoding
    /// to narrow the API results to the local city (or country as fallback)
    /// before sorting by distance and truncating.
    func loadNearbyCourses(from location: CLLocation) async {
        // Skip if we already loaded for a point within 5 km of this one
        if let prev = nearbyLoadedFor, location.distance(from: prev) < 5_000 { return }
        guard !isLoadingNearby else { return }
        nearbyUserLocation = location
        isLoadingNearby = true
        defer { isLoadingNearby = false }

        // Force English locale so the API's English-named dataset matches
        // regardless of the device language (e.g. "Munich" not "München")
        let geocoder = CLGeocoder()
        let english  = Locale(identifier: "en_US")
        let placemarks = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: english)
        let city    = placemarks?.first?.locality ?? ""
        let country = placemarks?.first?.country  ?? ""

        // Try city first; fall back to country if city yields nothing
        var candidates = city.isEmpty ? [] :
            (try? await api.searchCourses(query: city,    maxResults: 60, maxPages: 5)) ?? []
        if candidates.isEmpty && !country.isEmpty {
            candidates = (try? await api.searchCourses(query: country, maxResults: 60, maxPages: 10)) ?? []
        }
        guard !candidates.isEmpty else { return }

        // Sort by crow-flies distance; drop courses with no coordinates
        let sorted = candidates
            .filter { $0.location.latitude != 0 || $0.location.longitude != 0 }
            .sorted {
                let a = CLLocation(latitude: $0.location.latitude, longitude: $0.location.longitude)
                let b = CLLocation(latitude: $1.location.latitude, longitude: $1.location.longitude)
                return location.distance(from: a) < location.distance(from: b)
            }

        nearbyCourses   = Array(sorted.prefix(10))
        nearbyLoadedFor = location
    }

    /// Formatted distance string from the last known user location to a course.
    func distanceLabel(to course: CourseAPIResult) -> String? {
        guard let userLoc = nearbyUserLocation,
              course.location.latitude != 0 || course.location.longitude != 0 else { return nil }
        let courseLoc = CLLocation(latitude: course.location.latitude, longitude: course.location.longitude)
        let metres = userLoc.distance(from: courseLoc)
        if metres < 1_000 {
            return String(format: "%.0f m", metres)
        } else {
            return String(format: "%.1f km", metres / 1_000)
        }
    }

    // MARK: - Convert to playable GolfCourse

    /// Converts a search/browse result into a GolfCourse for round setup,
    /// using the player's tee gender and preferred tee name from PlayerProfile.
    func toGolfCourse(_ result: CourseAPIResult) async throws -> GolfCourse {
        // Fetch full detail (browse results may lack tee data)
        let detail = try await api.fetchCourse(id: result.id)
        let profile = PlayerProfile.shared
        return await api.toGolfCourse(
            detail,
            teeGender: profile.teeGender.rawValue,
            preferredTeeName: profile.preferredTeeName
        )
    }

    // MARK: - Private

    private func performSearch(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            searchResults = try await api.searchCourses(query: query, maxResults: 20, maxPages: 5)
            if searchResults.isEmpty {
                errorMessage = "No courses found for \"\(query)\". Try a city name or partial course name."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPage(_ page: Int) async {
        if page == 1 {
            isLoading = true
        } else {
            isLoadingMore = true
        }
        defer {
            isLoading = false
            isLoadingMore = false
        }
        do {
            let result = try await api.listCourses(page: page)
            if page == 1 {
                browseResults = result.courses
            } else {
                browseResults.append(contentsOf: result.courses)
            }
            currentPage = result.metadata.currentPage
            totalPages = result.metadata.lastPage
            totalCourses = result.metadata.totalRecords
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
