import CoreLocation
import Foundation

struct GolfCourse: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let city: String
    let state: String
    let country: String
    let holes: [GolfHole]
    /// GPS coverage quality from OpenStreetMap enrichment.
    /// `.none` means all holes use the course centre as a placeholder.
    var osmQuality: OSMHoleData.GPSQuality = .none
}

// MARK: - Codable conformance for GPSQuality

extension OSMHoleData.GPSQuality: Codable {
    enum CodingKeys: String, CodingKey { case type, found, of }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .full(let n):
            try c.encode("full", forKey: .type)
            try c.encode(n, forKey: .found)
            try c.encode(n, forKey: .of)
        case .partial(let f, let t):
            try c.encode("partial", forKey: .type)
            try c.encode(f, forKey: .found)
            try c.encode(t, forKey: .of)
        case .none:
            try c.encode("none", forKey: .type)
            try c.encode(0, forKey: .found)
            try c.encode(0, forKey: .of)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let found = (try? c.decode(Int.self, forKey: .found)) ?? 0
        let total = (try? c.decode(Int.self, forKey: .of)) ?? 0
        switch type {
        case "full":    self = .full(holes: found)
        case "partial": self = .partial(found: found, of: total)
        default:        self = .none
        }
    }
}

// Hashable conformance
extension OSMHoleData.GPSQuality: Hashable {}
