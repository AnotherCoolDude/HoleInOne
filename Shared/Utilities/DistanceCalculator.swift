import CoreLocation
import Foundation

enum DistanceCalculator {
    static func distance(from location: CLLocation, to coordinate: Coordinate, unit: DistanceUnit) -> Int {
        let meters = location.distance(from: coordinate.clLocation)
        return unit.convert(fromMeters: meters)
    }
}
