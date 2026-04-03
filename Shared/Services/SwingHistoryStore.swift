import Foundation
import SwiftData

@MainActor
final class SwingHistoryStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Round management

    func startRound(course: GolfCourse, selection: Round.HoleSelection) -> RoundResult {
        let round = RoundResult(
            courseId: course.id,
            courseName: course.name,
            date: .now,
            holeSelection: selection.rawValue
        )
        modelContext.insert(round)
        saveRecentCourse(course)
        return round
    }

    func updateSwingCount(round: RoundResult, holeNumber: Int, par: Int, swingCount: Int) {
        if let existing = round.holeResults.first(where: { $0.holeNumber == holeNumber }) {
            existing.swingCount = swingCount
        } else {
            let result = HoleResult(holeNumber: holeNumber, par: par, swingCount: swingCount)
            modelContext.insert(result)
            round.holeResults.append(result)
        }
        try? modelContext.save()
    }

    // MARK: - Favourites

    /// Toggles the favourite state of a course. Creates a SavedCourse entry if none exists yet.
    @discardableResult
    func toggleFavourite(courseId: String, courseName: String, city: String, country: String) -> Bool {
        let existing = fetchSavedCourse(id: courseId)
        if let saved = existing {
            saved.isFavourite.toggle()
            try? modelContext.save()
            return saved.isFavourite
        } else {
            let saved = SavedCourse(courseId: courseId, courseName: courseName, city: city, country: country, isFavourite: true)
            modelContext.insert(saved)
            try? modelContext.save()
            return true
        }
    }

    func isFavourite(courseId: String) -> Bool {
        fetchSavedCourse(id: courseId)?.isFavourite ?? false
    }

    func fetchFavourites() -> [SavedCourse] {
        let descriptor = FetchDescriptor<SavedCourse>(
            predicate: #Predicate { $0.isFavourite == true },
            sortBy: [SortDescriptor(\.courseName)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Queries

    func fetchAllRounds() -> [RoundResult] {
        let descriptor = FetchDescriptor<RoundResult>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchRounds(for courseId: String) -> [RoundResult] {
        let descriptor = FetchDescriptor<RoundResult>(
            predicate: #Predicate { $0.courseId == courseId },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Returns recently played courses (lastPlayed != distantPast), newest first.
    func fetchRecentCourses() -> [SavedCourse] {
        let distantPast = Date.distantPast
        let descriptor = FetchDescriptor<SavedCourse>(
            predicate: #Predicate { $0.lastPlayed > distantPast },
            sortBy: [SortDescriptor(\.lastPlayed, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Private

    private func fetchSavedCourse(id: String) -> SavedCourse? {
        let descriptor = FetchDescriptor<SavedCourse>(
            predicate: #Predicate { $0.courseId == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func saveRecentCourse(_ course: GolfCourse) {
        if let existing = fetchSavedCourse(id: course.id) {
            existing.lastPlayed = .now
            existing.courseName = course.name   // keep name fresh
        } else {
            modelContext.insert(SavedCourse(from: course))
        }
        try? modelContext.save()
    }
}
