import CoreLocation
import Foundation
import SwiftData

/// CRUD service for player-recorded hole GPS coordinates.
@MainActor
final class LearnedGPSStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Fetch

    /// All learned entries for a course, keyed by hole number.
    func fetchAll(courseId: String) -> [Int: LearnedHoleGPS] {
        let descriptor = FetchDescriptor<LearnedHoleGPS>(
            predicate: #Predicate { $0.courseId == courseId }
        )
        let results = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: results.map { ($0.holeNumber, $0) })
    }

    private func fetchOrCreate(courseId: String, holeNumber: Int) -> LearnedHoleGPS {
        let descriptor = FetchDescriptor<LearnedHoleGPS>(
            predicate: #Predicate { $0.courseId == courseId && $0.holeNumber == holeNumber }
        )
        if let existing = try? modelContext.fetch(descriptor).first { return existing }
        let entry = LearnedHoleGPS(courseId: courseId, holeNumber: holeNumber)
        modelContext.insert(entry)
        return entry
    }

    // MARK: - Record

    func recordPin(courseId: String, holeNumber: Int, coordinate: CLLocationCoordinate2D) {
        let entry = fetchOrCreate(courseId: courseId, holeNumber: holeNumber)
        entry.pinLatitude   = coordinate.latitude
        entry.pinLongitude  = coordinate.longitude
        entry.pinRecordedAt = .now
        try? modelContext.save()
    }

    func recordTee(courseId: String, holeNumber: Int, coordinate: CLLocationCoordinate2D) {
        let entry = fetchOrCreate(courseId: courseId, holeNumber: holeNumber)
        entry.teeLatitude   = coordinate.latitude
        entry.teeLongitude  = coordinate.longitude
        entry.teeRecordedAt = .now
        try? modelContext.save()
    }

    // MARK: - Clear (re-record from scratch)

    func clearPin(courseId: String, holeNumber: Int) {
        guard let entry = fetchOrCreate(courseId: courseId, holeNumber: holeNumber) as LearnedHoleGPS?,
              entry.hasPin else { return }
        entry.pinLatitude   = nil
        entry.pinLongitude  = nil
        entry.pinRecordedAt = nil
        try? modelContext.save()
    }

    func clearTee(courseId: String, holeNumber: Int) {
        guard let entry = fetchOrCreate(courseId: courseId, holeNumber: holeNumber) as LearnedHoleGPS?,
              entry.hasTee else { return }
        entry.teeLatitude   = nil
        entry.teeLongitude  = nil
        entry.teeRecordedAt = nil
        try? modelContext.save()
    }

    // MARK: - Progress

    /// How many holes have at least a pin recorded for this course.
    func mappedPinCount(courseId: String) -> Int {
        let descriptor = FetchDescriptor<LearnedHoleGPS>(
            predicate: #Predicate { $0.courseId == courseId && $0.pinLatitude != nil }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// Wipes all learned GPS for a course — useful if the club redesigns their layout.
    func clearAll(courseId: String) {
        let descriptor = FetchDescriptor<LearnedHoleGPS>(
            predicate: #Predicate { $0.courseId == courseId }
        )
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        entries.forEach { modelContext.delete($0) }
        try? modelContext.save()
    }
}
