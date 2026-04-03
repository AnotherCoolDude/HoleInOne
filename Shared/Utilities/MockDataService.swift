#if DEBUG
import Foundation
import SwiftData

/// Seeds the SwiftData store with realistic mock data for simulator testing.
/// Runs once per install — guarded by a UserDefaults flag so it never
/// overwrites data the user has already created.
@MainActor
enum MockDataService {

    private static let seededKey = "mock_data_seeded_v1"

    static func seedIfNeeded(modelContext: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        seed(modelContext: modelContext)
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    // Call this from a debug menu / button to reset and re-seed at any time.
    static func reseed(modelContext: ModelContext) {
        UserDefaults.standard.removeObject(forKey: seededKey)
        seed(modelContext: modelContext)
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    // MARK: - Private

    private static func seed(modelContext: ModelContext) {
        seedProfile()
        seedSavedCourses(modelContext: modelContext)
        seedRounds(modelContext: modelContext)
        try? modelContext.save()
    }

    // MARK: Player profile

    private static func seedProfile() {
        let profile = PlayerProfile.shared
        profile.name = "Alex"
        profile.handicapIndex = 14.2
        profile.teeGender = .male
        profile.preferredTeeName = "White"
    }

    // MARK: Saved courses (favourites + recent)

    private static func seedSavedCourses(modelContext: ModelContext) {
        let calendar = Calendar.current
        let now = Date.now

        // Pebble Beach — favourite + recently played
        let pebble = SavedCourse(
            courseId: "pebble-beach-gl",
            courseName: "Pebble Beach Golf Links",
            city: "Pebble Beach",
            country: "USA",
            isFavourite: true
        )
        pebble.lastPlayed = calendar.date(byAdding: .day, value: -3, to: now) ?? now
        modelContext.insert(pebble)

        // St Andrews — favourite, not yet played
        let standrews = SavedCourse(
            courseId: "st-andrews-old-course",
            courseName: "St Andrews Old Course",
            city: "St Andrews",
            country: "Scotland",
            isFavourite: true
        )
        // lastPlayed stays at .distantPast (set by the lightweight init)
        modelContext.insert(standrews)

        // Augusta National — recently played, not a favourite
        let augusta = SavedCourse(
            courseId: "augusta-national",
            courseName: "Augusta National Golf Club",
            city: "Augusta",
            country: "USA",
            isFavourite: false
        )
        augusta.lastPlayed = calendar.date(byAdding: .day, value: -10, to: now) ?? now
        modelContext.insert(augusta)
    }

    // MARK: Round history

    private static func seedRounds(modelContext: ModelContext) {
        let calendar = Calendar.current
        let now = Date.now

        // Round 1 — Pebble Beach, all 18, played 3 days ago (+5 over par)
        let round1 = RoundResult(
            courseId: "pebble-beach-gl",
            courseName: "Pebble Beach Golf Links",
            date: calendar.date(byAdding: .day, value: -3, to: now) ?? now,
            holeSelection: Round.HoleSelection.all18.rawValue
        )
        let pebblePars = [4,5,4,4,3,5,3,4,4,4,4,3,4,5,4,4,3,5]
        let pebbleStrokes = [5,6,4,5,3,6,4,5,5,4,5,3,5,6,5,4,4,6]
        for i in 0..<18 {
            let h = HoleResult(holeNumber: i+1, par: pebblePars[i], swingCount: pebbleStrokes[i])
            modelContext.insert(h)
            round1.holeResults.append(h)
        }
        modelContext.insert(round1)

        // Round 2 — Pebble Beach, front 9, played 3 days ago (earlier in the day) (-1 under par)
        let round2 = RoundResult(
            courseId: "pebble-beach-gl",
            courseName: "Pebble Beach Golf Links",
            date: calendar.date(byAdding: .hour, value: -74, to: now) ?? now,
            holeSelection: Round.HoleSelection.front9.rawValue
        )
        let front9Strokes = [4,5,4,4,2,5,3,4,4]
        for i in 0..<9 {
            let h = HoleResult(holeNumber: i+1, par: pebblePars[i], swingCount: front9Strokes[i])
            modelContext.insert(h)
            round2.holeResults.append(h)
        }
        modelContext.insert(round2)

        // Round 3 — Augusta National, all 18, played 10 days ago (+12 over par, rough day)
        let augustaPars   = [4,5,4,3,4,3,4,5,4,4,4,3,5,4,5,3,4,4]
        let augustaStrokes = [5,6,6,4,5,4,6,6,5,5,5,4,6,5,6,5,5,5]
        let round3 = RoundResult(
            courseId: "augusta-national",
            courseName: "Augusta National Golf Club",
            date: calendar.date(byAdding: .day, value: -10, to: now) ?? now,
            holeSelection: Round.HoleSelection.all18.rawValue
        )
        for i in 0..<18 {
            let h = HoleResult(holeNumber: i+1, par: augustaPars[i], swingCount: augustaStrokes[i])
            modelContext.insert(h)
            round3.holeResults.append(h)
        }
        modelContext.insert(round3)
    }
}
#endif
