import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class CourseSearchViewModel {
    var query: String = ""
    var searchResults: [CourseAPIResult] = []
    var browseResults: [CourseAPIResult] = []
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var errorMessage: String?
    var recentCourses: [SavedCourse] = []

    // Pagination state for browse mode
    var currentPage: Int = 1
    var totalPages: Int = 1
    var totalCourses: Int = 0
    var hasMorePages: Bool { currentPage < totalPages }

    private let api = GolfAPIService.shared
    private var searchTask: Task<Void, Never>?

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

    // MARK: - Convert to playable GolfCourse

    /// Converts a search/browse result into a GolfCourse for round setup.
    /// NOTE: per-hole GPS is unavailable from this API; pin coordinates will
    /// use the course's own lat/lon as a placeholder.
    func toGolfCourse(_ result: CourseAPIResult) async throws -> GolfCourse {
        // Fetch full detail (browse results may lack tee data)
        let detail = try await api.fetchCourse(id: result.id)
        return await api.toGolfCourse(detail)
    }

    // MARK: - Private

    private func performSearch(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            searchResults = try await api.searchCourses(query: query, maxResults: 40, maxPages: 15)
            if searchResults.isEmpty {
                errorMessage = "No courses found for "\(query)". Try a city name or partial course name."
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
