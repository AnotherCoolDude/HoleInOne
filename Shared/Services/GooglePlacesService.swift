import CoreLocation
import Foundation

// MARK: - GooglePlacesService
//
// Fetches rich course metadata (website, location, photos) from the
// Google Places API (New) using Text Search, Nearby Search, and photo media requests.
//
// Requires GOOGLE_PLACES_KEY in Secrets.xcconfig (gitignored).
// Get a key at: console.cloud.google.com → APIs → Places API (New)
//
// API docs: https://developers.google.com/maps/documentation/places/web-service/text-search
//           https://developers.google.com/maps/documentation/places/web-service/nearby-search
//
// Pricing (as of 2025):
//   Nearby Search — $0.032 / request
//   Text Search   — $0.017 / request
//   Photo (Basic) — $0.007 / photo session
//   All have a shared $200/month free tier.
//
// We cache results for 30 days to minimise billing.

// MARK: - Nearby course model

/// A golf course returned by Google Places Nearby Search (or OSM as fallback).
/// Used to populate the "Nearby" section on the home screen.
struct NearbyGolfCourse: Identifiable, Hashable {
    let id: String           // Google Place ID ("ChIJ…") or OSM element id ("way/123456")
    let name: String
    let coordinate: Coordinate
    var distanceMeters: Double = 0

    var distanceLabel: String {
        distanceMeters < 1_000
            ? String(format: "%.0f m", distanceMeters)
            : String(format: "%.1f km", distanceMeters / 1_000)
    }
}

// MARK: - Text search result model

struct GooglePlaceResult {
    let placeId:    String
    let name:       String
    let website:    URL?
    let coordinate: Coordinate?
    /// Up to 3 photo URLs suitable for display at ~800 px width.
    let photoURLs:  [URL]

    var primaryPhotoURL: URL? { photoURLs.first }
}

// MARK: - Service

actor GooglePlacesService {
    static let shared = GooglePlacesService()

    private let baseURL    = "https://places.googleapis.com/v1"
    private let maxPhotos  = 3
    private let cacheTTL: TimeInterval = 30 * 24 * 60 * 60   // 30 days

    private var memoryCache: [String: (result: GooglePlaceResult, at: Date)] = [:]

    private var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_KEY") as? String ?? ""
    }
    var isConfigured: Bool { !apiKey.isEmpty }

    private init() {}

    // MARK: - Public API

    /// Searches for a golf course by name near the given coordinate.
    /// Returns nil when the API key is absent or no match is found.
    func searchGolfCourse(
        name: String,
        near coordinate: Coordinate
    ) async -> GooglePlaceResult? {
        guard isConfigured else { return nil }
        let cacheKey = "\(name)|\(Int(coordinate.latitude))|\(Int(coordinate.longitude))"

        // Memory cache
        if let hit = memoryCache[cacheKey],
           Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.result
        }
        // Disk cache
        if let hit = loadFromDisk(key: cacheKey) { return hit }

        guard let result = await fetchFromAPI(name: name, near: coordinate) else { return nil }

        memoryCache[cacheKey] = (result, .now)
        saveToDisk(result: result, key: cacheKey)
        return result
    }

    // MARK: - Nearby Search

    /// Returns up to `limit` golf courses within `radiusKm` of `location`,
    /// sorted by distance. Results are NOT cached (caller should debounce).
    /// Returns an empty array when the API key is not configured.
    func nearbyGolfCourses(
        location: Coordinate,
        radiusKm: Double = 25,
        limit: Int = 10
    ) async -> [NearbyGolfCourse] {
        guard isConfigured else { return [] }
        guard let url = URL(string: "\(baseURL)/places:searchNearby") else { return [] }

        let body: [String: Any] = [
            "includedTypes":   ["golf_course"],
            "maxResultCount":  20,          // fetch extra, trim after distance sort
            "locationRestriction": [
                "circle": [
                    "center": ["latitude": location.latitude, "longitude": location.longitude],
                    "radius": radiusKm * 1_000
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,             forHTTPHeaderField: "X-Goog-Api-Key")
        // Only id, name and location — cheapest Nearby Search field mask
        request.setValue(
            "places.id,places.displayName,places.location",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = bodyData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }
        guard let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]] else {
            #if DEBUG
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            print("[GooglePlaces] Nearby search failed: \(preview)")
            #endif
            return []
        }

        let userCL = CLLocation(latitude: location.latitude, longitude: location.longitude)

        let courses: [NearbyGolfCourse] = places.compactMap { place in
            guard let id          = place["id"] as? String,
                  let displayName = (place["displayName"] as? [String: Any])?["text"] as? String,
                  let loc         = place["location"] as? [String: Any],
                  let lat         = loc["latitude"]  as? Double,
                  let lon         = loc["longitude"] as? Double else { return nil }

            let coord = Coordinate(latitude: lat, longitude: lon)
            let dist  = userCL.distance(from: CLLocation(latitude: lat, longitude: lon))
            return NearbyGolfCourse(id: id, name: displayName, coordinate: coord, distanceMeters: dist)
        }

        return courses
            .sorted { $0.distanceMeters < $1.distanceMeters }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - API fetch (Text Search + Photos)

    private func fetchFromAPI(name: String, near coord: Coordinate) async -> GooglePlaceResult? {
        // Step 1: Text Search
        guard let searchResult = await textSearch(name: name, near: coord) else { return nil }

        // Step 2: Fetch photo media URLs (parallel)
        let photoNames = Array(searchResult.rawPhotoNames.prefix(maxPhotos))
        let photoURLs: [URL] = await withTaskGroup(of: URL?.self) { group in
            for photoName in photoNames {
                group.addTask { await self.fetchPhotoURL(photoName: photoName) }
            }
            var urls: [URL] = []
            for await url in group { if let u = url { urls.append(u) } }
            return urls
        }

        return GooglePlaceResult(
            placeId:    searchResult.placeId,
            name:       searchResult.name,
            website:    searchResult.website,
            coordinate: searchResult.coordinate,
            photoURLs:  photoURLs
        )
    }

    // MARK: - Text Search

    private struct RawSearchResult {
        let placeId:       String
        let name:          String
        let website:       URL?
        let coordinate:    Coordinate?
        let rawPhotoNames: [String]
    }

    private func textSearch(name: String, near coord: Coordinate) async -> RawSearchResult? {
        guard let url = URL(string: "\(baseURL)/places:searchText") else { return nil }

        let body: [String: Any] = [
            "textQuery":    "\(name) golf course",
            "maxResultCount": 1,
            "includedType": "golf_course",
            "locationBias": [
                "circle": [
                    "center": ["latitude": coord.latitude, "longitude": coord.longitude],
                    "radius": 10_000.0
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json",           forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,                       forHTTPHeaderField: "X-Goog-Api-Key")
        // Only fetch the fields we actually use
        request.setValue(
            "places.id,places.displayName,places.websiteUri,places.location,places.photos",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]],
              let first = places.first else {
            #if DEBUG
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            print("[GooglePlaces] Text search no match: \(preview)")
            #endif
            return nil
        }

        let placeId = first["id"] as? String ?? ""
        let displayName = (first["displayName"] as? [String: Any])?["text"] as? String ?? name
        let websiteStr  = first["websiteUri"] as? String
        let website     = websiteStr.flatMap { URL(string: $0) }

        var coordinate: Coordinate?
        if let loc = first["location"] as? [String: Double],
           let lat = loc["latitude"], let lon = loc["longitude"] {
            coordinate = Coordinate(latitude: lat, longitude: lon)
        }

        let photoNames: [String] = (first["photos"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }

        return RawSearchResult(
            placeId:       placeId,
            name:          displayName,
            website:       website,
            coordinate:    coordinate,
            rawPhotoNames: photoNames
        )
    }

    // MARK: - Photo URL fetch

    private func fetchPhotoURL(photoName: String) async -> URL? {
        // skipHttpRedirect=true returns JSON {"photoUri": "..."} instead of a redirect
        let urlStr = "\(baseURL)/\(photoName)/media?maxWidthPx=800&skipHttpRedirect=true&key=\(apiKey)"
        guard let url = URL(string: urlStr) else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photoUri = json["photoUri"] as? String else { return nil }

        return URL(string: photoUri)
    }

    // MARK: - Disk cache (UserDefaults, 30-day TTL)

    private struct CacheEntry: Codable {
        let placeId:    String
        let name:       String
        let websiteStr: String?
        let latitude:   Double?
        let longitude:  Double?
        let photoURLs:  [String]
        let savedAt:    Date
    }

    private func diskKey(_ key: String) -> String { "google_place_v1_\(key.hash)" }

    private func saveToDisk(result: GooglePlaceResult, key: String) {
        let entry = CacheEntry(
            placeId:    result.placeId,
            name:       result.name,
            websiteStr: result.website?.absoluteString,
            latitude:   result.coordinate?.latitude,
            longitude:  result.coordinate?.longitude,
            photoURLs:  result.photoURLs.map(\.absoluteString),
            savedAt:    .now
        )
        if let data = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(data, forKey: diskKey(key))
        }
    }

    private func loadFromDisk(key: String) -> GooglePlaceResult? {
        guard let data  = UserDefaults.standard.data(forKey: diskKey(key)),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
              Date().timeIntervalSince(entry.savedAt) < cacheTTL else { return nil }

        let coord: Coordinate? = entry.latitude.flatMap { lat in
            entry.longitude.map { lon in Coordinate(latitude: lat, longitude: lon) }
        }
        return GooglePlaceResult(
            placeId:    entry.placeId,
            name:       entry.name,
            website:    entry.websiteStr.flatMap { URL(string: $0) },
            coordinate: coord,
            photoURLs:  entry.photoURLs.compactMap { URL(string: $0) }
        )
    }
}
