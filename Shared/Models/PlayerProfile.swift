import Foundation
import Observation

/// Persisted player settings — backed by UserDefaults, observable by SwiftUI.
@Observable
final class PlayerProfile {
    static let shared = PlayerProfile()

    // MARK: - Properties (auto-persisted via didSet)

    var name: String = "" {
        didSet { UserDefaults.standard.set(name, forKey: Keys.name) }
    }

    /// World Handicap System index. Range: +10 (scratch or better) to 54.
    /// Stored as a Double so half-strokes are possible (e.g. 12.4).
    var handicapIndex: Double = 0.0 {
        didSet { UserDefaults.standard.set(handicapIndex, forKey: Keys.handicapIndex) }
    }

    /// "male" or "female" — controls which tee group is chosen from the API data.
    var teeGender: TeeGender = .male {
        didSet { UserDefaults.standard.set(teeGender.rawValue, forKey: Keys.teeGender) }
    }

    /// Optional tee name preference (e.g. "Blue", "White").
    /// Empty string means "use first available tee for the chosen gender".
    var preferredTeeName: String = "" {
        didSet { UserDefaults.standard.set(preferredTeeName, forKey: Keys.preferredTeeName) }
    }

    // MARK: - Tee gender enum

    enum TeeGender: String, CaseIterable, Identifiable {
        case male   = "male"
        case female = "female"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .male:   return "Men's"
            case .female: return "Women's"
            }
        }

        /// Common tee colour names for each gender, shown as quick suggestions.
        var commonTeeNames: [String] {
            switch self {
            case .male:   return ["Championship", "Black", "Blue", "White", "Yellow", "Gold"]
            case .female: return ["Red", "Pink", "Silver", "White", "Yellow"]
            }
        }
    }

    // MARK: - Computed helpers

    var displayName: String {
        name.isEmpty ? "Player" : name
    }

    var handicapDisplay: String {
        if handicapIndex <= 0 {
            let plus = abs(handicapIndex)
            return plus == 0 ? "Scratch" : "+\(formatted(plus))"
        }
        return formatted(handicapIndex)
    }

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    // MARK: - Private init (load from UserDefaults)

    private init() {
        name             = UserDefaults.standard.string(forKey: Keys.name) ?? ""
        handicapIndex    = UserDefaults.standard.object(forKey: Keys.handicapIndex) as? Double ?? 0.0
        preferredTeeName = UserDefaults.standard.string(forKey: Keys.preferredTeeName) ?? ""

        if let raw = UserDefaults.standard.string(forKey: Keys.teeGender),
           let gender = TeeGender(rawValue: raw) {
            teeGender = gender
        }
    }

    // MARK: - UserDefaults keys

    private enum Keys {
        static let name             = "player_name"
        static let handicapIndex    = "player_handicap_index"
        static let teeGender        = "player_tee_gender"
        static let preferredTeeName = "player_tee_name"
    }
}
