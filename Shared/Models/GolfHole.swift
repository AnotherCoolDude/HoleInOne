import CoreLocation
import Foundation

struct GolfHole: Identifiable, Codable, Hashable {
    let number: Int         // 1–18
    let par: Int
    let handicap: Int
    let teeCoordinate: Coordinate
    let pinCoordinate: Coordinate   // center of green
    let lengthMeters: Int

    var id: Int { number }
}

struct Coordinate: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
