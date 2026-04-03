import Foundation
import SwiftData

/// Stores GPS coordinates recorded by the player while on the course.
/// One entry per hole per course. Pin and tee are recorded independently —
/// either can be nil if not yet walked.
@Model
final class LearnedHoleGPS {
    var courseId: String
    var holeNumber: Int

    // Pin (green centre) — nil until first recorded
    var pinLatitude: Double?
    var pinLongitude: Double?
    var pinRecordedAt: Date?

    // Tee box — nil until first recorded
    var teeLatitude: Double?
    var teeLongitude: Double?
    var teeRecordedAt: Date?

    init(courseId: String, holeNumber: Int) {
        self.courseId   = courseId
        self.holeNumber = holeNumber
    }

    var pinCoordinate: Coordinate? {
        guard let lat = pinLatitude, let lon = pinLongitude else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    var teeCoordinate: Coordinate? {
        guard let lat = teeLatitude, let lon = teeLongitude else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    var hasPin: Bool { pinRecordedAt != nil }
    var hasTee: Bool { teeRecordedAt != nil }
}
