#if DEBUG
import Foundation
import SwiftData

/// Seeds the SwiftData store with realistic mock data for simulator testing.
/// Fetches real courses from GolfCourseAPI and uses actual hole par data.
/// Runs once per install — guarded by a UserDefaults flag.
@MainActor
enum MockDataService {

    private static let seededKey = "mock_data_seeded_v4"

    static func seedIfNeeded(modelContext: ModelContext) async {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        await seed(modelContext: modelContext)
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    /// Reset and re-seed — useful from a debug button.
    static func reseed(modelContext: ModelContext) async {
        UserDefaults.standard.removeObject(forKey: seededKey)
        await seed(modelContext: modelContext)
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    // MARK: - Private

    private static func seed(modelContext: ModelContext) async {
        seedProfile()

        // Always start with the fully GPS-mapped bundled course (zero API cost)
        let bundled = (try? GolfAPIService.shared.loadBundledCourses()) ?? []
        let sierraStar = bundled.first { $0.id == "sierra-star-gc" }

        // Fetch additional courses from the API (may fail if limit reached)
        var courses: [GolfCourse] = sierraStar.map { [$0] } ?? []
        courses += await fetchSampleCourses()

        let finalCourses = courses.isEmpty ? bundled : courses
        seedSavedCourses(modelContext: modelContext, courses: finalCourses)
        seedRounds(modelContext: modelContext, courses: finalCourses)
        try? modelContext.save()
    }

    // MARK: - Fetch real courses from the API

    private static func fetchSampleCourses() async -> [GolfCourse] {
        let api = GolfAPIService.shared
        var courses: [GolfCourse] = []

        // Search queries → we keep the first match for each.
        // Sierra Star is bundled so it costs 0 API requests and has verified full GPS coverage.
        let queries = ["Sierra Star Golf", "Pebble Beach Golf Links", "Torrey Pines Golf Course"]

        for query in queries {
            guard courses.count < 3 else { break }
            do {
                if let result = try await api.searchCourses(query: query, maxResults: 1, maxPages: 2).first {
                    let detail = try await api.fetchCourse(id: result.id)
                    let course = await api.toGolfCourse(detail, teeGender: "male", preferredTeeName: "White")
                    courses.append(course)
                    print("[MockData] Fetched: \(course.name) (\(course.holes.count) holes)")
                }
            } catch {
                print("[MockData] Could not fetch \"\(query)\": \(error.localizedDescription)")
            }
        }

        return courses
    }

    // MARK: - Player profile

    private static func seedProfile() {
        let profile = PlayerProfile.shared
        guard profile.name.isEmpty else { return }   // don't overwrite if already set
        profile.name = "Alex"
        profile.handicapIndex = 14.2
        profile.teeGender = .male
        profile.preferredTeeName = "White"
    }

    // MARK: - Saved courses

    private static func seedSavedCourses(modelContext: ModelContext, courses: [GolfCourse]) {
        let calendar = Calendar.current
        let now = Date.now

        for (index, course) in courses.prefix(3).enumerated() {
            let saved = SavedCourse(
                courseId: course.id,
                courseName: course.name,
                city: course.city,
                country: course.country,
                isFavourite: index < 2          // first two are favourites
            )
            // First course played 3 days ago, second 10 days ago, third is favourite-only
            switch index {
            case 0: saved.lastPlayed = calendar.date(byAdding: .day, value: -3,  to: now) ?? now
            case 1: saved.lastPlayed = calendar.date(byAdding: .day, value: -10, to: now) ?? now
            default: break  // lastPlayed stays .distantPast
            }
            modelContext.insert(saved)
        }
    }

    // MARK: - Round history

    private static func seedRounds(modelContext: ModelContext, courses: [GolfCourse]) {
        let calendar = Calendar.current
        let now = Date.now

        guard let first = courses.first else { return }

        // Round 1 — first course, all 18, 3 days ago
        insertRound(
            modelContext: modelContext,
            course: first,
            selection: .all18,
            date: calendar.date(byAdding: .day, value: -3, to: now) ?? now,
            strokesOverPar: strokeOffsets(holes: first.holes.count, pattern: [1, 1, 0, 1, 0, 1, 0, 1, 1])
        )

        // Round 2 — first course, front 9, also 3 days ago (earlier)
        insertRound(
            modelContext: modelContext,
            course: first,
            selection: .front9,
            date: calendar.date(byAdding: .hour, value: -74, to: now) ?? now,
            strokesOverPar: strokeOffsets(holes: 9, pattern: [0, 1, 0, 0, -1, 1, 0, 1, 0])
        )

        if courses.count >= 2 {
            let second = courses[1]
            // Round 3 — second course, all 18, 10 days ago
            insertRound(
                modelContext: modelContext,
                course: second,
                selection: .all18,
                date: calendar.date(byAdding: .day, value: -10, to: now) ?? now,
                strokesOverPar: strokeOffsets(holes: second.holes.count, pattern: [2, 1, 2, 1, 1, 2, 1, 2, 1])
            )
        }
    }

    /// Inserts a `RoundResult` with `HoleResult` entries whose stroke counts are
    /// the hole's real par plus the corresponding offset (wraps around the pattern).
    private static func insertRound(
        modelContext: ModelContext,
        course: GolfCourse,
        selection: Round.HoleSelection,
        date: Date,
        strokesOverPar: [Int]
    ) {
        let round = RoundResult(
            courseId: course.id,
            courseName: course.name,
            date: date,
            holeSelection: selection.rawValue
        )
        modelContext.insert(round)

        let activeHoles = course.holes.filter { selection.holeNumbers.contains($0.number) }
        for (i, hole) in activeHoles.enumerated() {
            let offset = strokesOverPar[i % strokesOverPar.count]
            let strokes = max(1, hole.par + offset)
            let result = HoleResult(holeNumber: hole.number, par: hole.par, swingCount: strokes)
            modelContext.insert(result)
            round.holeResults.append(result)
        }
    }

    /// Builds an array of per-hole stroke offsets of the required length by
    /// repeating and cycling through `pattern`.
    private static func strokeOffsets(holes: Int, pattern: [Int]) -> [Int] {
        guard !pattern.isEmpty else { return Array(repeating: 1, count: holes) }
        return (0..<holes).map { pattern[$0 % pattern.count] }
    }
}
#endif
