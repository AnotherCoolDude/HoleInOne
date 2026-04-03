import CoreLocation
import Foundation

// MARK: - OSMGolfService
//
// Enriches GolfCourse models with real per-hole GPS coordinates sourced from
// OpenStreetMap (OSM) via the free Overpass API.
//
// OSM golf tags used:
//   golf=green          → putting green polygon  (ref = hole number)
//   golf=tee            → tee box polygon        (ref = hole number)
//   leisure=golf_course → overall course area    (name, bounding-box)
//
// Query mirror: overpass.kumi.systems (reliable; main server often returns 504)
//
// Strategy:
//   Step 1 – find course boundary by name + location → precise bounding box
//   Step 2 – query greens + tees within that bbox
//   Fallback – if name match fails, use a 700 m radius bbox from course lat/lon

// MARK: - Public types

struct OSMHoleData {
    struct HoleCoords {
        let holeNumber: Int
        let pinCoordinate: Coordinate?   // center of green
        let teeCoordinate: Coordinate?   // centroid of all tee boxes for this hole
    }

    enum DataSource: String, Codable, Hashable {
        case osm         // OpenStreetMap Overpass API
        case satellite   // Satellite image colour + contour detection
        case bundled     // Hardcoded in sample_courses.json
    }

    let holes: [HoleCoords]
    let sourceCourse: String?    // OSM course name that was matched
    let quality: GPSQuality
    var dataSource: DataSource = .osm

    enum GPSQuality: Equatable {
        case full(holes: Int)
        case partial(found: Int, of: Int)
        case none

        var label: String {
            switch self {
            case .full(let n):           return "GPS: \(n)/\(n) holes"
            case .partial(let f, let t): return "GPS: \(f)/\(t) holes"
            case .none:                  return "GPS unavailable"
            }
        }

        var isUsable: Bool {
            switch self {
            case .none: return false
            default:    return true
            }
        }
    }

    /// Returns the pin coordinate for `holeNumber`, or nil if not found.
    func pinCoordinate(forHole number: Int) -> Coordinate? {
        holes.first(where: { $0.holeNumber == number })?.pinCoordinate
    }

    /// Returns the tee coordinate for `holeNumber`, or nil if not found.
    func teeCoordinate(forHole number: Int) -> Coordinate? {
        holes.first(where: { $0.holeNumber == number })?.teeCoordinate
    }
}

// MARK: - Nearby course discovery

/// A golf course found in OpenStreetMap near the user's location.
/// Used to populate the "Nearby" section without requiring an API key or
/// a match against the golfcourseapi.com database.
struct NearbyOSMCourse: Identifiable, Hashable {
    let id: String          // OSM element id, e.g. "way/123456"
    let name: String
    let coordinate: Coordinate
    var distanceMeters: Double = 0

    var distanceLabel: String {
        distanceMeters < 1_000
            ? String(format: "%.0f m", distanceMeters)
            : String(format: "%.1f km", distanceMeters / 1_000)
    }
}

// MARK: - Service

actor OSMGolfService {
    static let shared = OSMGolfService()

    private let overpassURL = "https://overpass.kumi.systems/api/interpreter"
    private let cacheKeyPrefix = "osm_hole_data_"
    private let cacheTTLSeconds: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    private init() {}

    // MARK: - Nearby course discovery

    /// Returns golf courses within `radiusKm` kilometres of `location`,
    /// sorted by distance, capped at `limit`.
    ///
    /// Uses the Overpass `around` filter which is fast even for large radii.
    /// Results are not cached — the caller should debounce as needed.
    func nearbyGolfCourses(
        location: Coordinate,
        radiusKm: Double = 25,
        limit: Int = 10
    ) async -> [NearbyOSMCourse] {
        let radiusM = Int(radiusKm * 1_000)
        // Query ways, nodes and relations tagged leisure=golf_course within radius.
        // `out center` returns a single representative point for each element.
        let query = """
        [out:json][timeout:20];
        (
          way(around:\(radiusM),\(location.latitude),\(location.longitude))[leisure=golf_course];
          node(around:\(radiusM),\(location.latitude),\(location.longitude))[leisure=golf_course];
          relation(around:\(radiusM),\(location.latitude),\(location.longitude))[leisure=golf_course];
        );
        out center tags;
        """

        guard let data = try? await overpassQuery(query),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else {
            return []
        }

        let userLoc = CLLocation(latitude: location.latitude, longitude: location.longitude)

        var courses: [NearbyOSMCourse] = []
        for element in elements {
            // Resolve centre coordinate (ways/relations expose a "center" sub-dict)
            let lat: Double
            let lon: Double
            if let centre = element["center"] as? [String: Double],
               let clat = centre["lat"], let clon = centre["lon"] {
                lat = clat; lon = clon
            } else if let elat = element["lat"] as? Double,
                      let elon = element["lon"] as? Double {
                lat = elat; lon = elon
            } else {
                continue
            }

            let tags = element["tags"] as? [String: String] ?? [:]
            let name = tags["name"] ?? tags["name:en"] ?? "Golf Course"

            let osmType = element["type"] as? String ?? "node"
            let osmId   = element["id"]   as? Int    ?? 0
            let id      = "\(osmType)/\(osmId)"

            let courseLoc = CLLocation(latitude: lat, longitude: lon)
            var course = NearbyOSMCourse(
                id: id,
                name: name,
                coordinate: Coordinate(latitude: lat, longitude: lon)
            )
            course.distanceMeters = userLoc.distance(from: courseLoc)
            courses.append(course)
        }

        return courses
            .sorted { $0.distanceMeters < $1.distanceMeters }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Main entry point

    /// Returns per-hole GPS coordinates from OSM for the given course.
    /// Results are cached for 30 days.
    func fetchHoleCoordinates(
        courseId: String,
        courseName: String,
        location: Coordinate,
        expectedHoles: Int = 18
    ) async throws -> OSMHoleData {
        // 1. Check cache first
        if let cached = loadCache(courseId: courseId) {
            return cached
        }

        // 2. Step 1: find course bounding box by name
        let bbox = await findCourseBoundingBox(name: courseName, near: location)
            ?? fallbackBBox(from: location, radiusMeters: 700)

        // 3. Step 2: fetch greens + tees within bbox
        let greens = try await fetchGolfFeatures(type: "green", bbox: bbox)
        let tees   = try await fetchGolfFeatures(type: "tee",   bbox: bbox)

        // 4. Build per-hole data
        let data = buildHoleData(
            greens: greens,
            tees: tees,
            courseCenter: location,
            expectedHoles: expectedHoles,
            osmCourseName: bbox.sourceName
        )

        // 5. Cache and return
        saveCache(courseId: courseId, data: data)
        return data
    }

    // MARK: - Step 1: find course boundary

    private func findCourseBoundingBox(name: String, near location: Coordinate) async -> OSMBBox? {
        // Build a fuzzy name match query for leisure=golf_course
        let safeName = name
            .replacingOccurrences(of: "\"", with: "")
            .components(separatedBy: .whitespaces)
            .prefix(4)
            .joined(separator: " ")

        let query = """
        [out:json][timeout:15];
        (
          way["leisure"="golf_course"]["name"~"\(safeName)",i](around:1500,\(location.latitude),\(location.longitude));
          relation["leisure"="golf_course"]["name"~"\(safeName)",i](around:1500,\(location.latitude),\(location.longitude));
        );
        out bb tags ids;
        """

        guard let data = try? await overpassQuery(query),
              let response = try? JSONDecoder().decode(OverpassResponse.self, from: data) else {
            return nil
        }

        // Pick the element whose name is most similar to our query
        let candidates = response.elements.compactMap { elem -> (OSMBBox, Double)? in
            guard let bounds = elem.bounds else { return nil }
            let osmName = elem.tags?["name"] ?? ""
            let score = nameSimilarity(osmName, name)
            let bbox = OSMBBox(
                minLat: bounds.minlat, minLon: bounds.minlon,
                maxLat: bounds.maxlat, maxLon: bounds.maxlon,
                sourceName: osmName
            )
            return (bbox, score)
        }

        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    // MARK: - Step 2: fetch golf features within bbox

    private func fetchGolfFeatures(type: String, bbox: OSMBBox) async throws -> [OverpassElement] {
        let query = """
        [out:json][timeout:20];
        (
          way["golf"="\(type)"](\(bbox.minLat),\(bbox.minLon),\(bbox.maxLat),\(bbox.maxLon));
          relation["golf"="\(type)"](\(bbox.minLat),\(bbox.minLon),\(bbox.maxLat),\(bbox.maxLon));
        );
        out center tags;
        """
        let data = try await overpassQuery(query)
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        return response.elements
    }

    // MARK: - Build per-hole data

    private func buildHoleData(
        greens: [OverpassElement],
        tees: [OverpassElement],
        courseCenter: Coordinate,
        expectedHoles: Int,
        osmCourseName: String?
    ) -> OSMHoleData {

        // Group greens by hole number
        var greensByHole: [Int: [Coordinate]] = [:]
        for elem in greens {
            guard let refStr = elem.tags?["ref"],
                  let ref = Int(refStr),
                  ref >= 1 && ref <= 18,
                  let center = elem.center else { continue }
            greensByHole[ref, default: []].append(Coordinate(latitude: center.lat, longitude: center.lon))
        }

        // Group tees by hole number
        var teesByHole: [Int: [Coordinate]] = [:]
        for elem in tees {
            guard let refStr = elem.tags?["ref"],
                  let ref = Int(refStr),
                  ref >= 1 && ref <= 18,
                  let center = elem.center else { continue }
            teesByHole[ref, default: []].append(Coordinate(latitude: center.lat, longitude: center.lon))
        }

        // Build HoleCoords
        var holes: [OSMHoleData.HoleCoords] = []
        for holeNum in 1...18 {
            let greenCoords = greensByHole[holeNum] ?? []
            let teeCoords   = teesByHole[holeNum]   ?? []

            // Pick the green closest to course center when multiple exist
            let pinCoord = greenCoords
                .min(by: { distanceBetween($0, courseCenter) < distanceBetween($1, courseCenter) })

            // Average all tee boxes for this hole
            let teeCoord = teeCoords.isEmpty ? nil : centroid(of: teeCoords)

            if pinCoord != nil || teeCoord != nil {
                holes.append(OSMHoleData.HoleCoords(
                    holeNumber: holeNum,
                    pinCoordinate: pinCoord,
                    teeCoordinate: teeCoord
                ))
            }
        }

        // Determine quality
        let pinsFound = holes.filter { $0.pinCoordinate != nil }.count
        let quality: OSMHoleData.GPSQuality
        if pinsFound == 0 {
            quality = .none
        } else if pinsFound >= expectedHoles {
            quality = .full(holes: pinsFound)
        } else {
            quality = .partial(found: pinsFound, of: expectedHoles)
        }

        return OSMHoleData(holes: holes, sourceCourse: osmCourseName, quality: quality)
    }

    // MARK: - Networking

    private func overpassQuery(_ query: String) async throws -> Data {
        guard let url = URL(string: overpassURL) else {
            throw OSMError.invalidURL
        }
        guard let body = "data=\(query)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let bodyData = body.data(using: .utf8) else {
            throw OSMError.encodingFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OSMError.serverError
        }
        return data
    }

    // MARK: - Caching

    private struct CacheEntry: Codable {
        let data: CodableOSMHoleData
        let timestamp: Date
    }

    private func cacheKey(courseId: String) -> String {
        cacheKeyPrefix + courseId
    }

    private func loadCache(courseId: String) -> OSMHoleData? {
        let key = cacheKey(courseId: courseId)
        guard let raw = UserDefaults.standard.data(forKey: key),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: raw),
              Date().timeIntervalSince(entry.timestamp) < cacheTTLSeconds else {
            return nil
        }
        return entry.data.toOSMHoleData()
    }

    private func saveCache(courseId: String, data: OSMHoleData) {
        let key = cacheKey(courseId: courseId)
        let entry = CacheEntry(data: CodableOSMHoleData(from: data), timestamp: Date())
        if let encoded = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    /// Clears the cached OSM data for a specific course (useful for debugging).
    func clearCache(courseId: String) {
        UserDefaults.standard.removeObject(forKey: cacheKey(courseId: courseId))
    }

    /// Clears all cached OSM data.
    func clearAllCaches() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(cacheKeyPrefix) }
            .forEach { defaults.removeObject(forKey: $0) }
    }

    // MARK: - Helpers

    private func fallbackBBox(from coord: Coordinate, radiusMeters: Double) -> OSMBBox {
        // Approximate degree offset for a given metre radius
        let latDelta = radiusMeters / 111_000
        let lonDelta = radiusMeters / (111_000 * cos(coord.latitude * .pi / 180))
        return OSMBBox(
            minLat: coord.latitude  - latDelta,
            minLon: coord.longitude - lonDelta,
            maxLat: coord.latitude  + latDelta,
            maxLon: coord.longitude + lonDelta,
            sourceName: nil
        )
    }

    private func centroid(of coords: [Coordinate]) -> Coordinate {
        let lat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let lon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        return Coordinate(latitude: lat, longitude: lon)
    }

    private func distanceBetween(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dLat = (a.latitude  - b.latitude)  * .pi / 180
        let dLon = (a.longitude - b.longitude) * .pi / 180
        return sqrt(dLat * dLat + dLon * dLon)  // angular distance, fine for ranking
    }

    /// Simple character overlap similarity (0–1) for matching course names.
    private func nameSimilarity(_ a: String, _ b: String) -> Double {
        let aWords = Set(a.lowercased().split(separator: " ").map(String.init))
        let bWords = Set(b.lowercased().split(separator: " ").map(String.init))
        guard !bWords.isEmpty else { return 0 }
        return Double(aWords.intersection(bWords).count) / Double(bWords.count)
    }
}

// MARK: - Errors

enum OSMError: LocalizedError {
    case invalidURL
    case encodingFailed
    case serverError

    var errorDescription: String? {
        switch self {
        case .invalidURL:      return "Invalid Overpass API URL."
        case .encodingFailed:  return "Failed to encode Overpass query."
        case .serverError:     return "Overpass API returned an error. Try again later."
        }
    }
}

// MARK: - Internal types

private struct OSMBBox {
    let minLat: Double
    let minLon: Double
    let maxLat: Double
    let maxLon: Double
    let sourceName: String?
}

// MARK: - Overpass JSON DTOs

private struct OverpassResponse: Decodable {
    let elements: [OverpassElement]
}

private struct OverpassElement: Decodable {
    let type: String
    let id: Int
    let tags: [String: String]?
    let center: OverpassCenter?
    let bounds: OverpassBounds?
}

private struct OverpassCenter: Decodable {
    let lat: Double
    let lon: Double
}

private struct OverpassBounds: Decodable {
    let minlat: Double
    let minlon: Double
    let maxlat: Double
    let maxlon: Double
}

// MARK: - Codable wrappers for cache persistence

private struct CodableOSMHoleData: Codable {
    struct CodableHoleCoords: Codable {
        let holeNumber: Int
        let pinLat: Double?
        let pinLon: Double?
        let teeLat: Double?
        let teeLon: Double?
    }

    let holes: [CodableHoleCoords]
    let sourceCourse: String?
    let qualityType: String       // "full", "partial", "none"
    let qualityFound: Int
    let qualityOf: Int

    init(from data: OSMHoleData) {
        self.holes = data.holes.map {
            CodableHoleCoords(
                holeNumber: $0.holeNumber,
                pinLat: $0.pinCoordinate?.latitude,
                pinLon: $0.pinCoordinate?.longitude,
                teeLat: $0.teeCoordinate?.latitude,
                teeLon: $0.teeCoordinate?.longitude
            )
        }
        self.sourceCourse = data.sourceCourse
        switch data.quality {
        case .full(let n):           qualityType = "full";    qualityFound = n; qualityOf = n
        case .partial(let f, let t): qualityType = "partial"; qualityFound = f; qualityOf = t
        case .none:                  qualityType = "none";    qualityFound = 0; qualityOf = 0
        }
    }

    func toOSMHoleData() -> OSMHoleData {
        let holeCoords = holes.map { h -> OSMHoleData.HoleCoords in
            let pin = (h.pinLat != nil && h.pinLon != nil)
                ? Coordinate(latitude: h.pinLat!, longitude: h.pinLon!)
                : nil
            let tee = (h.teeLat != nil && h.teeLon != nil)
                ? Coordinate(latitude: h.teeLat!, longitude: h.teeLon!)
                : nil
            return OSMHoleData.HoleCoords(holeNumber: h.holeNumber, pinCoordinate: pin, teeCoordinate: tee)
        }
        let quality: OSMHoleData.GPSQuality
        switch qualityType {
        case "full":    quality = .full(holes: qualityFound)
        case "partial": quality = .partial(found: qualityFound, of: qualityOf)
        default:        quality = .none
        }
        return OSMHoleData(holes: holeCoords, sourceCourse: sourceCourse, quality: quality)
    }
}
