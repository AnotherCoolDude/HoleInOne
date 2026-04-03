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
    // Contextual hint banner — user can dismiss per-hole
    @State private var hintDismissedForHole: Set<Int> = []

    init(round: Round) {
        _viewModel = State(wrappedValue: RoundViewModel(round: round))
    }

    var body: some View {
        let hole = viewModel.effectiveCurrentHole

        VStack(spacing: 0) {
            holeHeader(hole: hole)
                .padding()

            // Contextual GPS hint — shown between header and map
            gpsHintBanner
                .padding(.horizontal)
                .padding(.bottom, gpsHintVisible ? 8 : 0)

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

    // MARK: - GPS hint banner

    private var gpsHintVisible: Bool {
        let holeNumber = viewModel.round.currentHole.number
        guard !hintDismissedForHole.contains(holeNumber) else { return false }
        return viewModel.gpsPrompt != .none
    }

    @ViewBuilder
    private var gpsHintBanner: some View {
        let holeNumber = viewModel.round.currentHole.number
        if !hintDismissedForHole.contains(holeNumber) {
            switch viewModel.gpsPrompt {
            case .markTee:
                hintRow(
                    icon: "figure.stand",
                    color: .blue,
                    message: "Stand on the tee box and tap Mark Tee to record this hole.",
                    holeNumber: holeNumber
                )
            case .markPin:
                hintRow(
                    icon: "flag.fill",
                    color: .orange,
                    message: "You're near the green — stand at the pin and tap Mark Pin.",
                    holeNumber: holeNumber
                )
            case .none:
                EmptyView()
            }
        }
    }

    private func hintRow(icon: String, color: Color, message: String, holeNumber: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    hintDismissedForHole.insert(holeNumber)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .transition(.move(edge: .top).combined(with: .opacity))
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

                    // Stroke-budget indicator — only shown when player has a handicap
                    if PlayerProfile.shared.handicapIndex > 0 {
                        strokeBudgetView
                            .padding(.top, 2)
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

    // MARK: - Stroke budget indicator

    /// Shows the player how many strokes they have left before hitting their net par.
    ///
    /// Net Par = hole par + extra handicap strokes on this hole
    ///
    /// Examples (course handicap 40, par-4 hole with stroke index 3):
    ///   Extra strokes = 3  →  Net Par = 7
    ///   After 4 swings:  "3 left to net par"  (green)
    ///   After 7 swings:  "Net par  ✓"         (blue)
    ///   After 9 swings:  "+2 over net par"     (red)
    @ViewBuilder
    private var strokeBudgetView: some View {
        let netPar   = viewModel.currentHoleNetPar
        let extra    = viewModel.extraStrokesOnCurrentHole
        let remaining = viewModel.strokesUntilNetPar

        // Only show the extra-strokes indicator when the player actually receives strokes
        let label: String
        let color: Color
        let icon: String

        if remaining > 0 {
            label = "\(remaining) left · Net par \(netPar)"
            color = remaining <= 1 ? .orange : .green
            icon  = "flag"
        } else if remaining == 0 {
            label = "Net par \(netPar)  ✓"
            color = .blue
            icon  = "checkmark"
        } else {
            label = "+\(abs(remaining)) over net par"
            color = .red
            icon  = "exclamationmark"
        }

        HStack(spacing: 5) {
            if extra > 0 {
                // Show the extra strokes badge so the player knows they have allowance
                Text("+\(extra)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.85), in: Capsule())
            }
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.2), value: remaining)
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
        // Hint fulfilled — hide it
        hintDismissedForHole.insert(viewModel.round.currentHole.number)
    }

    private func saveTee() {
        viewModel.markTee()
        flashSaved(pin: false)
        // Re-evaluate: tee saved, pin may still be needed — remove dismissal so
        // the pin hint can appear when they approach the green
        hintDismissedForHole.remove(viewModel.round.currentHole.number)
    }

    private func flashSaved(pin: Bool) {
        if pin { pinSaved = true } else { teeSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if pin { pinSaved = false } else { teeSaved = false }
        }
    }
}
