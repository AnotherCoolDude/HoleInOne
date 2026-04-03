import Foundation
import SwiftData

@Model
final class RoundResult {
    var courseId: String
    var courseName: String
    var date: Date
    var holeSelection: String
    @Relationship(deleteRule: .cascade) var holeResults: [HoleResult]

    init(courseId: String, courseName: String, date: Date, holeSelection: String, holeResults: [HoleResult] = []) {
        self.courseId = courseId
        self.courseName = courseName
        self.date = date
        self.holeSelection = holeSelection
        self.holeResults = holeResults
    }

    var totalStrokes: Int {
        holeResults.reduce(0) { $0 + $1.swingCount }
    }

    var totalPar: Int {
        holeResults.reduce(0) { $0 + $1.par }
    }

    var scoreToPar: Int {
        totalStrokes - totalPar
    }
}

@Model
final class HoleResult {
    var holeNumber: Int
    var par: Int
    var swingCount: Int

    init(holeNumber: Int, par: Int, swingCount: Int) {
        self.holeNumber = holeNumber
        self.par = par
        self.swingCount = swingCount
    }

    var scoreToPar: Int {
        swingCount - par
    }

    var scoreLabel: String {
        switch scoreToPar {
        case ..<(-1): return "Eagle"
        case -1:      return "Birdie"
        case 0:       return "Par"
        case 1:       return "Bogey"
        case 2:       return "Double Bogey"
        default:      return "+\(scoreToPar)"
        }
    }
}

@Model
final class SavedCourse {
    var courseId: String
    var courseName: String
    var city: String
    var country: String
    var lastPlayed: Date
    /// Whether the player has starred this course as a favourite.
    var isFavourite: Bool

    init(from course: GolfCourse, date: Date = .now, isFavourite: Bool = false) {
        self.courseId    = course.id
        self.courseName  = course.name
        self.city        = course.city
        self.country     = course.country
        self.lastPlayed  = date
        self.isFavourite = isFavourite
    }

    /// Lightweight init used when adding a favourite that has never been played.
    init(courseId: String, courseName: String, city: String, country: String, isFavourite: Bool = true) {
        self.courseId    = courseId
        self.courseName  = courseName
        self.city        = city
        self.country     = country
        self.lastPlayed  = .distantPast   // not played yet
        self.isFavourite = isFavourite
    }
}
