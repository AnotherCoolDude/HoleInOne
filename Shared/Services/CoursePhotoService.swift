import Foundation

// MARK: - CoursePhotoService
//
// Single point of truth for the representative photo of a golf course.
//
// Source priority (highest → lowest quality / relevance):
//   1. og:image from the club's own website   – club-chosen, always course-specific
//   2. Google Places photo                    – reliable, high-res, worldwide coverage
//   3. Wikipedia thumbnail                    – high quality, famous courses only
//
// The og:image is populated by ClubWebsiteScraper and fed in via
// `upgradeWithOgImage(_:for:)` when the scraper finishes. Wikipedia is queried
// lazily on first access, so list rows get photos quickly (~300 ms) without
// waiting for the full website scrape.
//
// Caching:
//   • In-memory dictionary for the current session (instant after first lookup)
//   • UserDefaults persistence under "course_photo_url_<courseId>" (30-day TTL)
//
// Usage in SwiftUI:
//   Use CoursePhotoView which wraps AsyncImage and calls this service lazily.

actor CoursePhotoService {
    static let shared = CoursePhotoService()

    private var memoryCache: [String: URL] = [:]
    private let cacheTTL: TimeInterval = 30 * 24 * 60 * 60
    private let cachePrefix = "course_photo_url_"

    private init() {}

    // MARK: - Public

    /// Returns the best available photo URL for the given course.
    /// Checks memory cache → UserDefaults → Wikipedia (async, ~300ms).
    /// Returns nil when no photo source produces a result.
    func photoURL(
        courseId: String,
        clubName: String,
        city: String,
        country: String,
        coordinate: Coordinate? = nil
    ) async -> URL? {
        // 1. In-memory (instant)
        if let hit = memoryCache[courseId] { return hit }

        // 2. Persisted cache (instant, no network)
        if let persisted = loadPersisted(courseId: courseId) {
            memoryCache[courseId] = persisted
            return persisted
        }

        // 3. Google Places (reliable worldwide, requires API key)
        if let coord = coordinate,
           let placesResult = await GooglePlacesService.shared.searchGolfCourse(name: clubName, near: coord),
           let photoURL = placesResult.primaryPhotoURL {
            persist(url: photoURL, courseId: courseId)
            return photoURL
        }

        // 4. Wikipedia thumbnail (~300 ms, no API key, famous courses only)
        if let wikiURL = await WikipediaPhotoService.shared.thumbnailURL(
            for: clubName, city: city, country: country
        ) {
            persist(url: wikiURL, courseId: courseId)
            return wikiURL
        }

        return nil
    }

    /// Called by ClubWebsiteScraper after it scrapes the club's homepage.
    /// The og:image is always preferred over Wikipedia because it's chosen by
    /// the club itself and is guaranteed to show their own course.
    func upgradeWithOgImage(_ ogImageURL: URL, for courseId: String) {
        // Only upgrade — don't downgrade a better og:image with the same or worse one
        memoryCache[courseId] = ogImageURL
        persist(url: ogImageURL, courseId: courseId)
    }

    /// Removes cached photo for a course (useful for refresh / debugging).
    func clearCache(for courseId: String) {
        memoryCache.removeValue(forKey: courseId)
        UserDefaults.standard.removeObject(forKey: persistenceKey(courseId))
    }

    // MARK: - Persistence

    private struct PersistedEntry: Codable {
        let urlString: String
        let timestamp: Date
    }

    private func persistenceKey(_ courseId: String) -> String { cachePrefix + courseId }

    private func loadPersisted(courseId: String) -> URL? {
        guard let raw = UserDefaults.standard.data(forKey: persistenceKey(courseId)),
              let entry = try? JSONDecoder().decode(PersistedEntry.self, from: raw),
              Date().timeIntervalSince(entry.timestamp) < cacheTTL else { return nil }
        return URL(string: entry.urlString)
    }

    private func persist(url: URL, courseId: String) {
        let entry = PersistedEntry(urlString: url.absoluteString, timestamp: .now)
        if let data = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(data, forKey: persistenceKey(courseId))
        }
    }
}
