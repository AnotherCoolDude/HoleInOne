import Foundation

struct Round {
    let course: GolfCourse
    let selection: HoleSelection
    var currentHoleIndex: Int = 0

    enum HoleSelection: String, CaseIterable, Codable {
        case front9 = "front9"
        case back9  = "back9"
        case all18  = "all18"

        var displayName: String {
            switch self {
            case .front9: return "Front 9"
            case .back9:  return "Back 9"
            case .all18:  return "18 Holes"
            }
        }

        var holeNumbers: [Int] {
            switch self {
            case .front9: return Array(1...9)
            case .back9:  return Array(10...18)
            case .all18:  return Array(1...18)
            }
        }
    }

    var activeHoles: [GolfHole] {
        course.holes.filter { selection.holeNumbers.contains($0.number) }
    }

    var currentHole: GolfHole {
        activeHoles[currentHoleIndex]
    }

    var isOnLastHole: Bool {
        currentHoleIndex >= activeHoles.count - 1
    }

    var isOnFirstHole: Bool {
        currentHoleIndex == 0
    }
}
