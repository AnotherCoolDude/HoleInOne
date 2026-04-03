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

    func fetchRecentCourses() -> [SavedCourse] {
        let descriptor = FetchDescriptor<SavedCourse>(
            sortBy: [SortDescriptor(\.lastPlayed, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Private

    private func saveRecentCourse(_ course: GolfCourse) {
        let descriptor = FetchDescriptor<SavedCourse>(
            predicate: #Predicate { $0.courseId == course.id }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.lastPlayed = .now
        } else {
            modelContext.insert(SavedCourse(from: course))
        }
        try? modelContext.save()
    }
}
