import Foundation

// MARK: - CommunityHoleData
//
// The validated, averaged GPS data for one hole derived from multiple players'
// contributions via CloudGPSService.
//
// Pins have a single aggregate (there is only one flagstick per hole).
// Tees have one aggregate per TeeColor (black/blue/white/yellow/red/green/gold)
// because tee boxes are physically 20–80 m apart and cannot be averaged together.

struct CommunityHoleData: Codable {

    let holeNumber: Int

    // MARK: - Pin

    /// Community-validated pin coordinate. nil when no usable data exists.
    let pinCoordinate: Coordinate?
    let pinSampleCount: Int
    let pinConfidence: Confidence

    /// True when the pin has medium-or-higher confidence (≥ 3 validated samples).
    var hasPinData: Bool { pinConfidence.isUsable && pinCoordinate != nil }

    // MARK: - Tees (one entry per colour that has been mapped)

    /// Community-validated tee coordinates keyed by TeeColor.rawValue.
    /// Using String keys for Codable compatibility.
    let tees: [String: TeeData]

    /// Returns the data for a specific tee colour, or nil if none exists.
    func teeData(for color: TeeColor) -> TeeData? {
        tees[color.rawValue]
    }

    /// Returns the tee colour + data with the highest confidence and sample count,
    /// ignoring low-confidence entries. Used as a fallback when the player's
    /// preferred colour has no data yet.
    var bestUsableTee: (color: TeeColor, data: TeeData)? {
        tees
            .compactMap { key, data -> (TeeColor, TeeData)? in
                guard let color = TeeColor(rawValue: key), data.confidence.isUsable else { return nil }
                return (color, data)
            }
            .max { $0.1.sampleCount < $1.1.sampleCount }
            .map { ($0.0, $0.1) }
    }

    /// Total contributor count across all tee colours on this hole.
    var totalTeeSamples: Int { tees.values.reduce(0) { $0 + $1.sampleCount } }

    // MARK: - Per-tee aggregate

    struct TeeData: Codable {
        let coordinate: Coordinate
        let sampleCount: Int
        let stdDevMeters: Double
        let confidence: Confidence
    }

    // MARK: - Confidence

    enum Confidence: String, Codable {
        case low    = "low"     // 1–2 samples
        case medium = "medium"  // 3–7 samples
        case high   = "high"    // 8+ samples

        /// Only medium and high confidence data is used in the GPS priority chain.
        var isUsable: Bool { self != .low }

        var label: String {
            switch self {
            case .low:    return "Unverified"
            case .medium: return "Community verified"
            case .high:   return "High confidence"
            }
        }

        var systemImage: String {
            switch self {
            case .low:    return "questionmark.circle"
            case .medium: return "checkmark.circle"
            case .high:   return "checkmark.shield.fill"
            }
        }
    }

    // MARK: - Builder (used internally by CloudGPSService)

    final class Builder {
        let holeNumber: Int
        var pinCoordinate: Coordinate?
        var pinSampleCount: Int = 0
        var pinStdDevMeters: Double = 0
        var pinConfidence: Confidence = .low
        var tees: [TeeColor: TeeData] = [:]

        init(holeNumber: Int) { self.holeNumber = holeNumber }

        func build() -> CommunityHoleData {
            CommunityHoleData(
                holeNumber:    holeNumber,
                pinCoordinate: pinCoordinate,
                pinSampleCount: pinSampleCount,
                pinConfidence:  pinConfidence,
                tees: Dictionary(uniqueKeysWithValues: tees.map { ($0.key.rawValue, $0.value) })
            )
        }
    }
}
