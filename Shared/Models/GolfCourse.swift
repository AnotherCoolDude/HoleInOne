import CoreLocation
import Foundation

struct GolfCourse: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let city: String
    let state: String
    let country: String
    let holes: [GolfHole]
    /// GPS coverage quality from automatic enrichment.
    var osmQuality: OSMHoleData.GPSQuality = .none
    /// Which detection method provided the GPS data.
    var gpsSource: OSMHoleData.DataSource = .osm
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

// MARK: - DataSource Codable + Hashable (declared in a different file)

extension OSMHoleData.DataSource: Codable, Hashable {}

// Hashable conformance — must be implemented manually because GPSQuality is
// declared in a different file (Swift cannot synthesise hash(into:) retroactively).
extension OSMHoleData.GPSQuality: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .full(let n):
            hasher.combine(0)
            hasher.combine(n)
        case .partial(let found, let total):
            hasher.combine(1)
            hasher.combine(found)
            hasher.combine(total)
        case .none:
            hasher.combine(2)
        }
    }

    static func == (lhs: OSMHoleData.GPSQuality, rhs: OSMHoleData.GPSQuality) -> Bool {
        switch (lhs, rhs) {
        case (.full(let a),          .full(let b)):          return a == b
        case (.partial(let a, let b), .partial(let c, let d)): return a == c && b == d
        case (.none,                 .none):                 return true
        default:                                             return false
        }
    }
}
