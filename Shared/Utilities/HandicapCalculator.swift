import Foundation

// MARK: - HandicapCalculator
//
// Implements the World Handicap System (WHS) formulas for scoring analysis.
//
// Key WHS concepts used:
//
//   Score Differential
//     = (Adjusted Gross Score − Course Rating) × (113 / Slope Rating)
//     where Adjusted Gross = gross score with each hole capped at par + 2
//     (simplified Net Double Bogey — ignores hole-specific handicap strokes).
//
//   Course Handicap
//     = round(Handicap Index × (Slope Rating / 113) + (Course Rating − Par))
//     This tells the player how many strokes they receive on this course/tee.
//
//   Net Score = Gross Score − Course Handicap
//
//   Handicap Index (WHS)
//     = average of the best 8 Score Differentials from the last 20 rounds × 0.96
//     rounded to one decimal place.
//
// 9-hole adjustment:
//   WHS defines separate 9-hole differentials that are combined in pairs. Since
//   the app stores 9-hole rounds, we use half the 18-hole course rating as the
//   9-hole rating, then double the resulting differential to normalise it to an
//   18-hole equivalent before including it in the index calculation.
//
// Limitations:
//   • Net Double Bogey is approximated as par + 2 (no per-hole handicap strokes).
//   • Playing Conditions Calculation (PCC) is not applied (insufficient data).
//   • Exceptional Score Reduction is not applied.
//   These simplifications are appropriate for a casual handicap tracker.

enum HandicapCalculator {

    // MARK: - Public output

    struct Assessment {
        // --- Round stats ---
        /// Gross strokes played (sum of all hole swing counts).
        let grossScore: Int
        /// Par for the holes played.
        let parTotal: Int
        /// Gross strokes with each hole capped at par + 2.
        let adjustedGross: Int
        /// WHS Score Differential for this round (normalised to 18-hole equivalent).
        let scoreDifferential: Double
        /// Strokes the player receives on this course/tee given their handicap.
        let courseHandicap: Int
        /// Net score = gross − course handicap.
        let netScore: Int
        /// Net score relative to par.
        let netToPar: Int

        // --- Index context ---
        /// Differential minus the player's current handicap index.
        /// Negative = this round was better than the player's average.
        let differentialGap: Double
        /// Whether this round helps, hurts, or is neutral to the handicap.
        let trend: Trend

        // --- Projected index ---
        /// Estimated handicap index if this round is included in the set.
        /// nil when there is not enough data to compute (< 3 rounds total).
        let estimatedNewIndex: Double?
        /// Estimated change in handicap index (negative = improved).
        /// nil when estimatedNewIndex is nil.
        let indexDelta: Double?

        enum Trend {
            case improving    // differential clearly below index
            case maintaining  // within ±1.0 of index
            case declining    // differential clearly above index
        }

        var formattedDifferential: String {
            String(format: "%+.1f", scoreDifferential)
        }

        var formattedIndexDelta: String? {
            guard let d = indexDelta else { return nil }
            return String(format: "%+.1f", d)
        }

        var trendSymbol: String {
            switch trend {
            case .improving:   return "arrow.down.circle.fill"
            case .maintaining: return "equal.circle.fill"
            case .declining:   return "arrow.up.circle.fill"
            }
        }

        var trendLabel: String {
            switch trend {
            case .improving:   return "Below your handicap"
            case .maintaining: return "Close to your handicap"
            case .declining:   return "Above your handicap"
            }
        }
    }

    // MARK: - Main entry point

    /// Computes a full WHS handicap assessment for a single round.
    ///
    /// - Parameters:
    ///   - round:         The completed round with hole results.
    ///   - allRounds:     All rounds stored in history, used for the projected index
    ///                    calculation (WHS needs up to 20 recent differentials).
    ///   - handicapIndex: The player's current handicap index (from PlayerProfile).
    static func assess(
        round: RoundResult,
        allRounds: [RoundResult],
        handicapIndex: Double
    ) -> Assessment {
        let is9Hole = (round.holeSelection != Round.HoleSelection.all18.rawValue)
            && round.holeResults.count <= 9

        // --- Gross and adjusted gross ---
        let holes    = round.holeResults
        let gross    = holes.reduce(0) { $0 + $1.swingCount }
        let par      = holes.reduce(0) { $0 + $1.par }
        // Simplified NDB: cap each hole at par + 2
        let adjGross = holes.reduce(0) { $0 + min($1.swingCount, $1.par + 2) }

        // --- Score Differential ---
        let cr    = round.courseRating
        let sr    = Double(round.slopeRating)
        var diff  = (Double(adjGross) - cr) * (113.0 / sr)
        if is9Hole { diff *= 2.0 }   // normalise 9-hole to 18-hole equivalent

        // --- Course Handicap ---
        let courseHcp = courseHandicap(
            handicapIndex: handicapIndex,
            slopeRating: round.slopeRating,
            courseRating: cr,
            par: Double(par)
        )
        let effectiveCourseHcp = is9Hole ? courseHcp / 2 : courseHcp
        let net    = gross - effectiveCourseHcp
        let netPar = net  - par

        // --- Trend ---
        let gap   = diff - handicapIndex
        let trend: Assessment.Trend
        if gap < -1.0      { trend = .improving }
        else if gap > 1.0  { trend = .declining }
        else               { trend = .maintaining }

        // --- Projected index ---
        let (estIndex, delta) = projectedIndex(
            newDiff: diff,
            thisRound: round,
            allRounds: allRounds,
            currentIndex: handicapIndex
        )

        return Assessment(
            grossScore: gross,
            parTotal: par,
            adjustedGross: adjGross,
            scoreDifferential: diff,
            courseHandicap: effectiveCourseHcp,
            netScore: net,
            netToPar: netPar,
            differentialGap: gap,
            trend: trend,
            estimatedNewIndex: estIndex,
            indexDelta: delta
        )
    }

    // MARK: - Course Handicap

    /// WHS Course Handicap = round(Index × Slope / 113 + (Rating − Par))
    static func courseHandicap(
        handicapIndex: Double,
        slopeRating: Int,
        courseRating: Double,
        par: Double
    ) -> Int {
        let raw = handicapIndex * Double(slopeRating) / 113.0 + (courseRating - par)
        return Int(raw.rounded())
    }

    // MARK: - Projected Index

    /// Estimates the new handicap index if the given differential is added to
    /// the player's recent history, following WHS best-8-of-20 rules.
    ///
    /// Returns (nil, nil) when there are fewer than 3 total rounds (not enough
    /// data for a meaningful index).
    private static func projectedIndex(
        newDiff: Double,
        thisRound: RoundResult,
        allRounds: [RoundResult],
        currentIndex: Double
    ) -> (Double?, Double?) {
        // Build the set of the 20 most recent differentials (excluding thisRound,
        // which may already be in allRounds if saved before this call)
        let others = allRounds
            .filter { $0.id != thisRound.id }
            .sorted { $0.date > $1.date }
            .prefix(19)
            .map { roundDifferential($0) }

        var diffs = Array(others) + [newDiff]
        diffs.sort()   // ascending

        let n = diffs.count
        guard n >= 3 else { return (nil, nil) }

        // WHS lookup table: how many of the best differentials to use
        let count = bestDifferentialCount(for: n)
        let best  = Array(diffs.prefix(count))
        let avg   = best.reduce(0, +) / Double(best.count)
        let newIdx = (avg * 0.96 * 10).rounded() / 10   // round to 1 dp
        let delta  = ((newIdx - currentIndex) * 10).rounded() / 10

        return (newIdx, delta)
    }

    /// Computes the Score Differential for a stored round.
    private static func roundDifferential(_ round: RoundResult) -> Double {
        let is9 = (round.holeSelection != Round.HoleSelection.all18.rawValue)
            && round.holeResults.count <= 9
        let adjGross = round.holeResults.reduce(0) { $0 + min($1.swingCount, $1.par + 2) }
        var diff = (Double(adjGross) - round.courseRating) * (113.0 / Double(round.slopeRating))
        if is9 { diff *= 2.0 }
        return diff
    }

    /// WHS table: number of best differentials to average based on total rounds available.
    /// Source: World Handicap System Rules of Handicapping (Appendix C).
    private static func bestDifferentialCount(for n: Int) -> Int {
        switch n {
        case 3:      return 1
        case 4:      return 1
        case 5:      return 1
        case 6:      return 2
        case 7:      return 2
        case 8:      return 2
        case 9:      return 3
        case 10:     return 3
        case 11:     return 3
        case 12:     return 4
        case 13:     return 4
        case 14:     return 4
        case 15:     return 5
        case 16:     return 5
        case 17:     return 6
        case 18:     return 6
        case 19:     return 7
        default:     return 8  // 20+
        }
    }
}
