import SwiftData
import SwiftUI

struct RoundView: View {
    @State private var viewModel: RoundViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Re-record confirmation
    @State private var showRerecordPin = false
    @State private var showRerecordTee = false
    // Brief "saved" feedback
    @State private var pinSaved = false
    @State private var teeSaved = false

    init(round: Round) {
        _viewModel = State(wrappedValue: RoundViewModel(round: round))
    }

    var body: some View {
        let hole = viewModel.effectiveCurrentHole

        VStack(spacing: 0) {
            holeHeader(hole: hole)
                .padding()

            HoleMapView(hole: hole, userLocation: viewModel.userLocation)
                .ignoresSafeArea(edges: .horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
            viewModel.startRound(
                store: SwingHistoryStore(modelContext: modelContext),
                gpsStore: LearnedGPSStore(modelContext: modelContext)
            )
        }
        .onDisappear {
            viewModel.endRound()
        }
        // Re-record pin confirmation
        .confirmationDialog(
            "Re-record pin location for Hole \(viewModel.round.currentHole.number)?",
            isPresented: $showRerecordPin,
            titleVisibility: .visible
        ) {
            Button("Re-record Pin", role: .destructive) { savePin() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will overwrite the previously saved pin location.")
        }
        // Re-record tee confirmation
        .confirmationDialog(
            "Re-record tee location for Hole \(viewModel.round.currentHole.number)?",
            isPresented: $showRerecordTee,
            titleVisibility: .visible
        ) {
            Button("Re-record Tee", role: .destructive) { saveTee() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will overwrite the previously saved tee location.")
        }
    }

    // MARK: - Header

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

            // Distance + mark-pin button
            VStack(spacing: 4) {
                Text("\(viewModel.distanceToPin)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(viewModel.preferredUnit.abbreviation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("to pin")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                markPinButton
            }
        }
    }

    // MARK: - Mark pin button

    private var markPinButton: some View {
        let holeNumber = viewModel.round.currentHole.number
        let hasPin = viewModel.hasLearnedPin(holeNumber: holeNumber)
        let noGPS = viewModel.userLocation == nil

        return Button {
            if hasPin {
                showRerecordPin = true
            } else {
                savePin()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: pinSaved ? "checkmark.circle.fill" : (hasPin ? "location.fill" : "location"))
                Text(pinSaved ? "Saved!" : (hasPin ? "Re-record Pin" : "Mark Pin"))
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(noGPS ? .secondary : (hasPin ? .green : .blue))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (noGPS ? Color.secondary : (hasPin ? Color.green : Color.blue)).opacity(0.12),
                in: Capsule()
            )
        }
        .disabled(noGPS)
        .animation(.easeInOut(duration: 0.2), value: pinSaved)
    }

    // MARK: - Bottom bar

    private func bottomBar(hole: GolfHole) -> some View {
        HStack(spacing: 24) {
            Button {
                viewModel.goToPreviousHole()
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(viewModel.round.isOnFirstHole ? .gray : .primary)
            }
            .disabled(viewModel.round.isOnFirstHole)

            Spacer()

            // Swing counter + mark tee
            VStack(spacing: 8) {
                VStack(spacing: 4) {
                    Text("\(viewModel.currentSwingCount)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("swings")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 16) {
                        Button { viewModel.decrementSwing() } label: {
                            Image(systemName: "minus.circle")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        Button { viewModel.incrementSwing() } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                        }
                    }
                }

                markTeeButton
            }

            Spacer()

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

    // MARK: - Mark tee button

    private var markTeeButton: some View {
        let holeNumber = viewModel.round.currentHole.number
        let hasTee = viewModel.hasLearnedTee(holeNumber: holeNumber)
        let noGPS = viewModel.userLocation == nil

        return Button {
            if hasTee {
                showRerecordTee = true
            } else {
                saveTee()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: teeSaved ? "checkmark.circle.fill" : (hasTee ? "location.fill" : "location"))
                Text(teeSaved ? "Saved!" : (hasTee ? "Re-record Tee" : "Mark Tee"))
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(noGPS ? .secondary : (hasTee ? .green : .blue))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (noGPS ? Color.secondary : (hasTee ? Color.green : Color.blue)).opacity(0.12),
                in: Capsule()
            )
        }
        .disabled(noGPS)
        .animation(.easeInOut(duration: 0.2), value: teeSaved)
    }

    // MARK: - Save helpers

    private func savePin() {
        viewModel.markPin()
        flashSaved(pin: true)
    }

    private func saveTee() {
        viewModel.markTee()
        flashSaved(pin: false)
    }

    private func flashSaved(pin: Bool) {
        if pin { pinSaved = true } else { teeSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if pin { pinSaved = false } else { teeSaved = false }
        }
    }
}
