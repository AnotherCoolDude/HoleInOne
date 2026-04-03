import SwiftData
import SwiftUI

struct SwingHistoryView: View {
    @Environment(\.modelContext) private var modelContext
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
                            RoundDetailView(round: round)
                        } label: {
                            RoundRowView(round: round)
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
        let store = SwingHistoryStore(modelContext: modelContext)
        rounds = store.fetchAllRounds()
    }
}

private struct RoundRowView: View {
    let round: RoundResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(round.courseName).font(.body.bold())
            HStack {
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
}

private struct RoundDetailView: View {
    let round: RoundResult

    private var sortedHoles: [HoleResult] {
        round.holeResults.sorted { $0.holeNumber < $1.holeNumber }
    }

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Course", value: round.courseName)
                LabeledContent("Date", value: round.date.formatted(date: .long, time: .omitted))
                LabeledContent("Holes", value: Round.HoleSelection(rawValue: round.holeSelection)?.displayName ?? round.holeSelection)
                LabeledContent("Total Strokes", value: "\(round.totalStrokes)")
                LabeledContent("Total Par", value: "\(round.totalPar)")
                LabeledContent("Score") {
                    let diff = round.scoreToPar
                    Text(diff == 0 ? "E" : diff > 0 ? "+\(diff)" : "\(diff)")
                        .foregroundStyle(diff < 0 ? .green : diff > 0 ? .red : .primary)
                        .bold()
                }
            }

            Section("Hole by Hole") {
                ForEach(sortedHoles) { hole in
                    HStack {
                        Text("Hole \(hole.holeNumber)")
                        Spacer()
                        Text("Par \(hole.par)")
                            .foregroundStyle(.secondary)
                        Text("\(hole.swingCount) strokes")
                            .monospacedDigit()
                        Text(hole.scoreLabel)
                            .font(.caption)
                            .foregroundStyle(hole.scoreToPar < 0 ? .green : hole.scoreToPar > 0 ? .red : .secondary)
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                }
            }
        }
        .navigationTitle("Round Detail")
        .navigationBarTitleDisplayMode(.inline)
    }
}
