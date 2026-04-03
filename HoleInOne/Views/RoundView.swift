import SwiftData
import SwiftUI

struct RoundView: View {
    @State private var viewModel: RoundViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(round: Round) {
        _viewModel = State(wrappedValue: RoundViewModel(round: round))
    }

    var body: some View {
        let hole = viewModel.round.currentHole

        VStack(spacing: 0) {
            // Header: hole info + distance
            holeHeader(hole: hole)
                .padding()

            // Map
            HoleMapView(hole: hole, userLocation: viewModel.userLocation)
                .ignoresSafeArea(edges: .horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom controls
            bottomBar(hole: hole)
                .padding()
        }
        .navigationTitle(viewModel.round.course.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("End Round") {
                    viewModel.endRound()
                    dismiss()
                }
                .foregroundStyle(.red)
            }
        }
        .onAppear {
            let store = SwingHistoryStore(modelContext: modelContext)
            viewModel.startRound(store: store)
        }
        .onDisappear {
            viewModel.endRound()
        }
    }

    // MARK: - Sub-views

    private func holeHeader(hole: GolfHole) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hole \(hole.number)")
                    .font(.title.bold())
                HStack(spacing: 12) {
                    Label("Par \(hole.par)", systemImage: "flag")
                    Label("\(hole.lengthMeters) m", systemImage: "arrow.left.and.right")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Distance badge
            VStack(spacing: 2) {
                Text("\(viewModel.distanceToPin)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(viewModel.preferredUnit.abbreviation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("to pin")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func bottomBar(hole: GolfHole) -> some View {
        HStack(spacing: 24) {
            // Previous hole
            Button {
                viewModel.goToPreviousHole()
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(viewModel.round.isOnFirstHole ? .gray : .primary)
            }
            .disabled(viewModel.round.isOnFirstHole)

            Spacer()

            // Swing counter
            VStack(spacing: 4) {
                Text("\(viewModel.currentSwingCount)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("swings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Button {
                        viewModel.decrementSwing()
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        viewModel.incrementSwing()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            // Next hole
            Button {
                viewModel.goToNextHole()
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(viewModel.round.isOnLastHole ? .gray : .primary)
            }
            .disabled(viewModel.round.isOnLastHole)
        }
    }
}
