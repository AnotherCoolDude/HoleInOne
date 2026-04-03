import CoreLocation
import Foundation

// MARK: - GolfCourseAPI.com Service
//
// Base URL : https://api.golfcourseapi.com/v1
// Auth     : "Authorization: Key <apiKey>" header
// Endpoints discovered:
//   GET /v1/courses          – paginated list (20/page), use ?page=N
//   GET /v1/courses/{id}     – single course by integer ID
//
// ⚠️  Important limitations of this API:
//   • No server-side search  – the ?search= param is silently ignored;
//     filtering must be done client-side.
//   • No per-hole GPS        – individual hole tee/pin coordinates are not
//     provided. Only the overall course lat/lon is available.
//     The app's GolfHole.teeCoordinate / pinCoordinate will be nil for API
//     courses; users must walk the course to set pin locations (future feature).

// MARK: - API domain models

/// Full course data as returned by golfcourseapi.com.
/// Does not contain per-hole GPS; use GolfCourse for playable rounds.
struct CourseAPIResult: Identifiable {
    let id: Int
    let clubName: String
    let courseName: String
    let location: CourseAPILocation
    let tees: CourseAPITees
}

struct CourseAPILocation {
    let address: String
    let city: String
    let state: String
    let country: String
    let latitude: Double
    let longitude: Double

    var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

struct CourseAPITees {
    let male: [CourseTeeOption]
    let female: [CourseTeeOption]

    var isEmpty: Bool { male.isEmpty && female.isEmpty }

    /// Returns the best available tee for display (male first, then female).
    var primary: CourseTeeOption? { male.first ?? female.first }
}

struct CourseTeeOption: Identifiable {
    let id = UUID()
    let teeName: String
    let courseRating: Double
    let slopeRating: Int
    let bogeyRating: Double
    let totalYards: Int
    let totalMeters: Int
    let numberOfHoles: Int
    let parTotal: Int

    // Front/back split ratings
    let frontCourseRating: Double
    let frontSlopeRating: Int
    let frontBogeyRating: Double
    let backCourseRating: Double
    let backSlopeRating: Int
    let backBogeyRating: Double

    let holes: [TeeHole]
}

struct TeeHole {
    let par: Int
    let yardage: Int
    let handicap: Int
    var lengthMeters: Int { Int((Double(yardage) * 0.9144).rounded()) }
}

struct PaginationMetadata {
    let currentPage: Int
    let pageSize: Int
    let firstPage: Int
    let lastPage: Int
    let totalRecords: Int

    var hasNextPage: Bool { currentPage < lastPage }
    var hasPreviousPage: Bool { currentPage > firstPage }
}

struct CourseListResult {
    let courses: [CourseAPIResult]
    let metadata: PaginationMetadata
}

// MARK: - Service

actor GolfAPIService {
    static let shared = GolfAPIService()

    private let apiKey = "2AYZOT5Y7IEFANIYUALGSSYPCU"
    private let baseURL = "https://api.golfcourseapi.com/v1"

    private init() {}

    // MARK: - Endpoints

    /// Returns one page of courses (20 per page). Pages run from 1 to metadata.lastPage.
    func listCourses(page: Int = 1) async throws -> CourseListResult {
        let url = try buildURL(path: "/courses", query: ["page": "\(max(1, page))"])
        let response: CoursesListDTO = try await fetch(url: url)
        return CourseListResult(
            courses: response.courses.map(\.asDomain),
            metadata: response.metadata.asDomain
        )
    }

    /// Fetches a single course by its integer ID.
    func fetchCourse(id: Int) async throws -> CourseAPIResult {
        let url = try buildURL(path: "/courses/\(id)")
        let response: CourseDetailDTO = try await fetch(url: url)
        return response.course.asDomain
    }

    // MARK: - Higher-level helpers

    /// Client-side search: fetches pages until enough matches are found or all pages are exhausted.
    /// The API provides no server-side filtering, so this is done in-process.
    /// - Parameters:
    ///   - query:      Text to match against club_name, course_name, city, state, or country (case-insensitive).
    ///   - maxResults: Stop after collecting this many matches (default 30).
    ///   - maxPages:   Guard against scanning the entire dataset (default 10 pages = 200 courses).
    func searchCourses(
        query: String,
        maxResults: Int = 30,
        maxPages: Int = 10
    ) async throws -> [CourseAPIResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        var results: [CourseAPIResult] = []
        var page = 1
        var lastPage = Int.max

        while results.count < maxResults && page <= min(lastPage, maxPages) {
            let list = try await listCourses(page: page)
            lastPage = list.metadata.lastPage

            let matches = list.courses.filter { course in
                let tokens = query.lowercased().split(separator: " ").map(String.init)
                let searchable = [
                    course.clubName,
                    course.courseName,
                    course.location.city,
                    course.location.state,
                    course.location.country
                ].joined(separator: " ").lowercased()
                return tokens.allSatisfy { searchable.contains($0) }
            }
            results.append(contentsOf: matches)
            page += 1
        }

        return Array(results.prefix(maxResults))
    }

    /// Converts a `CourseAPIResult` into the app's `GolfCourse` playable model.
    ///
    /// Automatically attempts to enrich per-hole GPS coordinates from OpenStreetMap
    /// via `OSMGolfService`. Results are cached for 30 days so subsequent calls are
    /// instant. If OSM has no data for the course, all holes fall back to the
    /// course's own lat/lon as a placeholder.
    ///
    /// - Parameter teeGender: "male" or "female"; falls back to whichever is available.
    func toGolfCourse(_ result: CourseAPIResult, teeGender: String = "male") async -> GolfCourse {
        let courseId    = "\(result.id)"
        let courseCoord = result.location.coordinate

        let tee: CourseTeeOption? = teeGender == "female"
            ? (result.tees.female.first ?? result.tees.male.first)
            : (result.tees.male.first ?? result.tees.female.first)

        let expectedHoles = tee?.numberOfHoles ?? 18

        // Fetch OSM hole coordinates (cached after first successful lookup)
        let osmData = try? await OSMGolfService.shared.fetchHoleCoordinates(
            courseId: courseId,
            courseName: result.clubName,
            location: courseCoord,
            expectedHoles: expectedHoles
        )

        let holes: [GolfHole]
        if let tee {
            holes = tee.holes.enumerated().map { index, h in
                let holeNumber = index + 1
                let pinCoord = osmData?.pinCoordinate(forHole: holeNumber) ?? courseCoord
                let teeCoord = osmData?.teeCoordinate(forHole: holeNumber) ?? courseCoord
                return GolfHole(
                    number: holeNumber,
                    par: h.par,
                    handicap: h.handicap,
                    teeCoordinate: teeCoord,
                    pinCoordinate: pinCoord,
                    lengthMeters: h.lengthMeters
                )
            }
        } else {
            // Course has no tee data — generate generic 18-hole scaffold
            holes = (1...18).map { num in
                GolfHole(
                    number: num,
                    par: 4,
                    handicap: num,
                    teeCoordinate: osmData?.teeCoordinate(forHole: num) ?? courseCoord,
                    pinCoordinate: osmData?.pinCoordinate(forHole: num) ?? courseCoord,
                    lengthMeters: 0
                )
            }
        }

        return GolfCourse(
            id: courseId,
            name: result.courseName.isEmpty ? result.clubName : result.courseName,
            city: result.location.city,
            state: result.location.state,
            country: result.location.country,
            holes: holes,
            osmQuality: osmData?.quality ?? .none
        )
    }

    // MARK: - Bundled fallback (offline / development)

    /// Loads the bundled `sample_courses.json`. Used when the API is unreachable.
    func loadBundledCourses() throws -> [GolfCourse] {
        guard let url = Bundle.main.url(forResource: "sample_courses", withExtension: "json") else {
            throw GolfCourseAPIError.bundleFileNotFound
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([GolfCourse].self, from: data)
    }

    // MARK: - Private networking

    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GolfCourseAPIError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw GolfCourseAPIError.unauthorized
        case 404:
            throw GolfCourseAPIError.notFound
        case 429:
            throw GolfCourseAPIError.rateLimitExceeded
        default:
            throw GolfCourseAPIError.serverError(statusCode: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GolfCourseAPIError.decodingFailed(error)
        }
    }

    private func buildURL(path: String, query: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: baseURL + path) else {
            throw GolfCourseAPIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw GolfCourseAPIError.invalidURL }
        return url
    }
}

// MARK: - Errors

enum GolfCourseAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case notFound
    case rateLimitExceeded
    case serverError(statusCode: Int)
    case decodingFailed(Error)
    case bundleFileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:               return "Invalid request URL."
        case .invalidResponse:          return "Received an unexpected server response."
        case .unauthorized:             return "Invalid API key. Check your GolfCourseAPI credentials."
        case .notFound:                 return "Course not found."
        case .rateLimitExceeded:        return "Daily API rate limit reached. Try again tomorrow."
        case .serverError(let code):    return "Server error (HTTP \(code)). Please try again."
        case .decodingFailed(let e):    return "Failed to parse server response: \(e.localizedDescription)"
        case .bundleFileNotFound:       return "Bundled course data file is missing."
        }
    }
}

// MARK: - JSON DTOs (private — mirrors exact API response shape)

private struct CoursesListDTO: Decodable {
    let courses: [CourseDTO]
    let metadata: MetadataDTO
}

private struct CourseDetailDTO: Decodable {
    let course: CourseDTO
}

private struct MetadataDTO: Decodable {
    let current_page: Int
    let page_size: Int
    let first_page: Int
    let last_page: Int
    let total_records: Int

    var asDomain: PaginationMetadata {
        PaginationMetadata(
            currentPage: current_page,
            pageSize: page_size,
            firstPage: first_page,
            lastPage: last_page,
            totalRecords: total_records
        )
    }
}

private struct CourseDTO: Decodable {
    let id: Int
    let club_name: String
    let course_name: String
    let location: LocationDTO
    let tees: TeesDTO

    var asDomain: CourseAPIResult {
        CourseAPIResult(
            id: id,
            clubName: club_name,
            courseName: course_name,
            location: location.asDomain,
            tees: tees.asDomain
        )
    }
}

private struct LocationDTO: Decodable {
    let address: String
    let city: String
    let state: String
    let country: String
    let latitude: Double
    let longitude: Double

    var asDomain: CourseAPILocation {
        CourseAPILocation(
            address: address,
            city: city,
            state: state,
            country: country,
            latitude: latitude,
            longitude: longitude
        )
    }
}

/// The "tees" field can be an empty object `{}` or contain "female" / "male" arrays.
private struct TeesDTO: Decodable {
    let female: [TeeOptionDTO]?
    let male: [TeeOptionDTO]?

    var asDomain: CourseAPITees {
        CourseAPITees(
            male: male?.map(\.asDomain) ?? [],
            female: female?.map(\.asDomain) ?? []
        )
    }
}

private struct TeeOptionDTO: Decodable {
    let tee_name: String
    let course_rating: Double
    let slope_rating: Int
    let bogey_rating: Double
    let total_yards: Int
    let total_meters: Int
    let number_of_holes: Int
    let par_total: Int
    let front_course_rating: Double
    let front_slope_rating: Int
    let front_bogey_rating: Double
    let back_course_rating: Double
    let back_slope_rating: Int
    let back_bogey_rating: Double
    let holes: [TeeHoleDTO]

    var asDomain: CourseTeeOption {
        CourseTeeOption(
            teeName: tee_name,
            courseRating: course_rating,
            slopeRating: slope_rating,
            bogeyRating: bogey_rating,
            totalYards: total_yards,
            totalMeters: total_meters,
            numberOfHoles: number_of_holes,
            parTotal: par_total,
            frontCourseRating: front_course_rating,
            frontSlopeRating: front_slope_rating,
            frontBogeyRating: front_bogey_rating,
            backCourseRating: back_course_rating,
            backSlopeRating: back_slope_rating,
            backBogeyRating: back_bogey_rating,
            holes: holes.map(\.asDomain)
        )
    }
}

private struct TeeHoleDTO: Decodable {
    let par: Int
    let yardage: Int
    let handicap: Int

    var asDomain: TeeHole {
        TeeHole(par: par, yardage: yardage, handicap: handicap)
    }
}
