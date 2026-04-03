import SwiftData
import SwiftUI

struct SwingHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerProfile.self) private var profile
    @State private var rounds: [RoundResult] = []

    var body: some View {
        Group {
            if rounds.isEmpty {
                ContentUnavailableView(
                    "No rounds yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Your round history will appear here after you complete a game.")
                )
            } else {
                List {
                    ForEach(rounds) { round in
                        NavigationLink {
                            RoundDetailView(round: round, allRounds: rounds,
                                            handicapIndex: profile.handicapIndex)
                        } label: {
                            RoundRowView(round: round, handicapIndex: profile.handicapIndex)
                        }
                    }
                    .onDelete { indexSet in
                        indexSet.forEach { modelContext.delete(rounds[$0]) }
                        try? modelContext.save()
                        load()
                    }
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
    }

    private func load() {
        rounds = SwingHistoryStore(modelContext: modelContext).fetchAllRounds()
    }
}

// MARK: - Round row

private struct RoundRowView: View {
    let round: RoundResult
    let handicapIndex: Double

    private var assessment: HandicapCalculator.Assessment {
        HandicapCalculator.assess(round: round, allRounds: [], handicapIndex: handicapIndex)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Left: course name + meta
            VStack(alignment: .leading, spacing: 4) {
                Text(round.courseName).font(.body.bold())
                HStack(spacing: 6) {
                    Text(round.date.formatted(date: .abbreviated, time: .omitted))
                    Text("·")
                    Text(selectionLabel)
                    Text("·")
                    Text(scoreLabel)
                        .foregroundStyle(scoreColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Right: differential chip
            differentialChip
        }
        .padding(.vertical, 2)
    }

    private var selectionLabel: String {
        Round.HoleSelection(rawValue: round.holeSelection)?.displayName ?? round.holeSelection
    }

    private var scoreLabel: String {
        let diff = round.scoreToPar
        if diff == 0 { return "E" }
        return diff > 0 ? "+\(diff)" : "\(diff)"
    }

    private var scoreColor: Color {
        round.scoreToPar < 0 ? .green : round.scoreToPar > 0 ? .red : .primary
    }

    /// Small coloured pill showing the WHS differential.
    @ViewBuilder
    private var differentialChip: some View {
        let diff = assessment.scoreDifferential
        let color: Color = {
            switch assessment.trend {
            case .improving:   return .green
            case .maintaining: return .orange
            case .declining:   return .red
            }
        }()

        VStack(spacing: 1) {
            Text(String(format: "%.1f", diff))
                .font(.caption.bold())
                .monospacedDigit()
            Text("diff")
                .font(.system(size: 9))
                .foregroundStyle(color.opacity(0.8))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Round detail

private struct RoundDetailView: View {
    let round: RoundResult
    let allRounds: [RoundResult]
    let handicapIndex: Double

    private var assessment: HandicapCalculator.Assessment {
        HandicapCalculator.assess(round: round, allRounds: allRounds,
                                  handicapIndex: handicapIndex)
    }

    private var sortedHoles: [HoleResult] {
        round.holeResults.sorted { $0.holeNumber < $1.holeNumber }
    }

    var body: some View {
        List {
            summarySection
            handicapSection
            holeByHoleSection
        }
        .navigationTitle("Round Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Summary section

    private var summarySection: some View {
        Section("Summary") {
            LabeledContent("Course", value: round.courseName)
            LabeledContent("Date", value: round.date.formatted(date: .long, time: .omitted))
            LabeledContent("Holes",
                value: Round.HoleSelection(rawValue: round.holeSelection)?.displayName
                    ?? round.holeSelection)
            LabeledContent("Total Strokes", value: "\(round.totalStrokes)")
            LabeledContent("Total Par",     value: "\(round.totalPar)")
            LabeledContent("Score") {
                let diff = round.scoreToPar
                Text(diff == 0 ? "E" : diff > 0 ? "+\(diff)" : "\(diff)")
                    .foregroundStyle(diff < 0 ? .green : diff > 0 ? .red : .primary)
                    .bold()
            }
        }
    }

    // MARK: - Handicap section

    private var handicapSection: some View {
        Section {
            // Trend banner
            trendBanner

            // Key numbers
            LabeledContent("Score Differential") {
                Text(String(format: "%.1f", assessment.scoreDifferential))
                    .bold()
                    .foregroundStyle(trendColor)
            }
            LabeledContent("Your Handicap Index") {
                Text(String(format: "%.1f", handicapIndex))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Course Handicap") {
                Text("\(assessment.courseHandicap) strokes")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Net Score") {
                let n = assessment.netToPar
                let label = n == 0 ? "Even par" : n > 0 ? "+\(n) over par" : "\(n) under par"
                Text(label)
                    .foregroundStyle(n < 0 ? .green : n > 0 ? .red : .primary)
            }

            // Projected index
            if let newIdx = assessment.estimatedNewIndex,
               let delta = assessment.indexDelta {
                LabeledContent("Projected Index") {
                    HStack(spacing: 6) {
                        Text(String(format: "%.1f", newIdx))
                            .bold()
                        Text("(\(delta >= 0 ? "+" : "")\(String(format: "%.1f", delta)))")
                            .foregroundStyle(delta < 0 ? .green : delta > 0 ? .red : .secondary)
                            .font(.caption)
                    }
                }
            }

            // Rating/slope for context
            if round.courseRating != 72.0 || round.slopeRating != 113 {
                LabeledContent("Course Rating / Slope") {
                    Text(String(format: "%.1f / %d", round.courseRating, round.slopeRating))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

        } header: {
            Label("Handicap Impact", systemImage: "chart.line.downtrend.xyaxis")
        } footer: {
            handicapFootnote
        }
    }

    @ViewBuilder
    private var trendBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: assessment.trendSymbol)
                .font(.title3)
                .foregroundStyle(trendColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(assessment.trendLabel)
                    .font(.subheadline.bold())
                    .foregroundStyle(trendColor)
                Text(trendDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(trendColor.opacity(0.06))
    }

    private var trendColor: Color {
        switch assessment.trend {
        case .improving:   return .green
        case .maintaining: return .orange
        case .declining:   return .red
        }
    }

    private var trendDescription: String {
        let gap = abs(assessment.differentialGap)
        switch assessment.trend {
        case .improving:
            return String(format: "%.1f strokes below your index — great round!", gap)
        case .maintaining:
            return "Close to your handicap index — consistent play."
        case .declining:
            return String(format: "%.1f strokes above your index.", gap)
        }
    }

    @ViewBuilder
    private var handicapFootnote: some View {
        if assessment.estimatedNewIndex != nil {
            Text("Projected index uses WHS best-8-of-20 formula with your stored rounds.")
                .font(.caption2)
        } else {
            Text("Play more rounds to unlock your projected handicap index.")
                .font(.caption2)
        }
    }

    // MARK: - Hole by hole section

    private var holeByHoleSection: some View {
        let courseHcp = assessment.courseHandicap
        let hasStrokeData = sortedHoles.contains { $0.strokeIndex > 0 }

        return Section {
            ForEach(sortedHoles) { hole in
                holeRow(hole: hole, courseHandicap: courseHcp, hasStrokeData: hasStrokeData)
            }
        } header: {
            HStack {
                Text("Hole by Hole")
                Spacer()
                // Column headers
                Text("Gross")
                    .frame(minWidth: 42, alignment: .center)
                if hasStrokeData {
                    Text("Net")
                        .frame(minWidth: 42, alignment: .center)
                }
            }
            .font(.caption)
            .textCase(nil)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func holeRow(hole: HoleResult, courseHandicap: Int, hasStrokeData: Bool) -> some View {
        let grossToPar  = hole.scoreToPar
        let extra       = hole.strokeIndex > 0
            ? HandicapCalculator.extraStrokes(courseHandicap: courseHandicap, strokeIndex: hole.strokeIndex)
            : 0
        let netPar      = hole.par + extra
        let netToPar    = hole.swingCount - netPar

        HStack(spacing: 0) {
            // Hole number + par
            VStack(alignment: .leading, spacing: 1) {
                Text("Hole \(hole.holeNumber)")
                    .font(.subheadline)
                HStack(spacing: 4) {
                    Text("Par \(hole.par)")
                        .foregroundStyle(.secondary)
                    if extra > 0 {
                        Text("+\(extra)")
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.indigo.opacity(0.1), in: Capsule())
                    }
                }
                .font(.caption)
            }

            Spacer()

            // Gross score chip
            scoreChip(strokes: hole.swingCount, toPar: grossToPar, label: grossLabel(grossToPar))
                .frame(minWidth: 42, alignment: .center)

            // Net score chip (only when stroke index data is available)
            if hasStrokeData && hole.strokeIndex > 0 {
                scoreChip(strokes: hole.swingCount, toPar: netToPar, label: netLabel(netToPar), isNet: true)
                    .frame(minWidth: 42, alignment: .center)
            } else if hasStrokeData {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 42, alignment: .center)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func scoreChip(strokes: Int, toPar: Int, label: String, isNet: Bool = false) -> some View {
        let color: Color = toPar < -1 ? .purple
            : toPar == -1 ? .green
            : toPar == 0  ? (isNet ? .blue : .primary)
            : toPar == 1  ? .orange
            : .red

        VStack(spacing: 1) {
            Text("\(strokes)")
                .font(.subheadline.bold())
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
        }
        .foregroundStyle(toPar == 0 && !isNet ? .secondary : color)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            (toPar == 0 && !isNet) ? Color.clear : color.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func grossLabel(_ toPar: Int) -> String {
        switch toPar {
        case ..<(-1): return "Eagle"
        case -1:      return "Birdie"
        case 0:       return "Par"
        case 1:       return "Bogey"
        case 2:       return "Dbl"
        default:      return "+\(toPar)"
        }
    }

    private func netLabel(_ toPar: Int) -> String {
        switch toPar {
        case ..<0: return "Net \(toPar)"
        case 0:    return "Net par"
        default:   return "Net +\(toPar)"
        }
    }
}
