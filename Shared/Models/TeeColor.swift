import SwiftUI

// MARK: - TeeColor
//
// Canonical tee-box identifier used throughout the app for community GPS
// bucketing, player profile preference, and display.
//
// Design principle: all string inputs (from the API, user settings, club
// websites, or any language) are normalised to one of these canonical values
// on the way IN, so contributions always land in the correct bucket even when
// different clubs or languages use different names for the same colour.

enum TeeColor: String, CaseIterable, Codable, Identifiable, Hashable {
    case black  = "black"
    case blue   = "blue"
    case white  = "white"
    case yellow = "yellow"
    case red    = "red"
    case green  = "green"
    case gold   = "gold"
    case other  = "other"

    var id: String { rawValue }

    // MARK: - Normalisation

    /// Converts any tee name string (any language, any case) to a canonical
    /// TeeColor. Returns nil when the string is empty or completely unrecognised.
    static func from(_ name: String) -> TeeColor? {
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }

        // Exact / alias matches first (most reliable)
        switch n {
        case "black", "schwarz", "noir", "championship", "pro", "back", "tour":
            return .black
        case "blue", "blau", "bleu", "mens", "men", "herren", "männer", "competition":
            return .blue
        case "white", "weiß", "weiss", "blanc", "regular", "standard", "club":
            return .white
        case "yellow", "gelb", "jaune", "seniors", "senior", "damen", "senior/damen":
            return .yellow
        case "red", "rot", "rouge", "ladies", "women", "damen uk", "front":
            return .red
        case "green", "grün", "gruen", "vert", "juniors", "junior", "kinder", "children":
            return .green
        case "gold", "or":
            return .gold
        default:
            break
        }

        // Partial / containment match (e.g. "Blue Championship", "White Regular")
        if n.contains("black") || n.contains("schwarz") { return .black }
        if n.contains("blue")  || n.contains("blau")    { return .blue  }
        if n.contains("white") || n.contains("weiß")
            || n.contains("weiss")                       { return .white  }
        if n.contains("yellow") || n.contains("gelb")   { return .yellow }
        if n.contains("red")   || n.contains("rot")     { return .red    }
        if n.contains("green") || n.contains("grün")
            || n.contains("gruen")                       { return .green  }
        if n.contains("gold")                            { return .gold   }

        return .other
    }

    // MARK: - Display

    var displayName: String {
        switch self {
        case .black:  return "Black"
        case .blue:   return "Blue"
        case .white:  return "White"
        case .yellow: return "Yellow"
        case .red:    return "Red"
        case .green:  return "Green"
        case .gold:   return "Gold"
        case .other:  return "Other"
        }
    }

    /// Typical gender / age group that plays this tee (informational only —
    /// clubs vary widely; never used to restrict data entry).
    var typicalUse: String {
        switch self {
        case .black:  return "Championship"
        case .blue:   return "Men's"
        case .white:  return "Men's / Regular"
        case .yellow: return "Seniors' / Ladies'"
        case .red:    return "Ladies'"
        case .green:  return "Juniors'"
        case .gold:   return "Championship"
        case .other:  return "Other"
        }
    }

    // MARK: - Visual

    /// The physical tee-marker colour used in SwiftUI.
    var markerColor: Color {
        switch self {
        case .black:  return .black
        case .blue:   return .blue
        case .white:  return Color(white: 0.76)
        case .yellow: return .yellow
        case .red:    return .red
        case .green:  return .green
        case .gold:   return Color(hue: 0.128, saturation: 0.90, brightness: 0.92)
        case .other:  return .gray
        }
    }

    /// Legible foreground colour when drawn on top of `markerColor`.
    var labelColor: Color {
        switch self {
        case .black, .blue, .red, .green: return .white
        default:                          return .black
        }
    }

    /// Compact coloured swatch view for use in list rows and buttons.
    var swatchView: some View {
        Circle()
            .fill(markerColor)
            .frame(width: 12, height: 12)
            .overlay { Circle().stroke(Color(white: 0.72), lineWidth: 0.5) }
    }
}
