import Foundation

enum DistanceUnit: String, CaseIterable, Codable, Identifiable {
    case yards  = "yd"
    case meters = "m"
    case feet   = "ft"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .yards:  return "Yards"
        case .meters: return "Meters"
        case .feet:   return "Feet"
        }
    }

    var abbreviation: String { rawValue }

    func convert(fromMeters meters: Double) -> Int {
        switch self {
        case .meters: return Int(meters.rounded())
        case .yards:  return Int((meters * 1.09361).rounded())
        case .feet:   return Int((meters * 3.28084).rounded())
        }
    }
}
