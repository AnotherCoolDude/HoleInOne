import SwiftUI
import WatchKit

struct WatchRoundView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @State private var swingCount: Int = 0

    private var payload: WatchPayload? { watchManager.latestPayload }

    var body: some View {
        TabView {
            // Tab 1: Distance
            distanceTab
                .tag(0)

            // Tab 2: Swing counter
            swingTab
                .tag(1)
        }
        .tabViewStyle(.page)
        .onChange(of: payload?.holeNumber) { _, _ in
            // Reset swing count when hole changes
            swingCount = 0
        }
    }

    // MARK: - Distance tab

    private var distanceTab: some View {
        VStack(spacing: 4) {
            if let payload {
                Text("Hole \(payload.holeNumber)  ·  Par \(payload.par)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(payload.distance)")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)

                Text(payload.distanceUnit)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("to pin")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Text(payload.courseName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                ContentUnavailableView {
                    Label("Waiting…", systemImage: "iphone.radiowaves.left.and.right")
                } description: {
                    Text("Open HoleInOne on your iPhone to start a round.")
                }
            }
        }
        .padding(8)
    }

    // MARK: - Swing counter tab

    private var swingTab: some View {
        VStack(spacing: 0) {
            // Hole info + count
            HStack {
                Text("Hole \(payload?.holeNumber ?? 0)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(swingCount) sw")
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            // Large tap button
            Button {
                addSwing()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.green.gradient)
                    VStack(spacing: 2) {
                        Image(systemName: "plus")
                            .font(.system(size: 32, weight: .bold))
                        Text("\(swingCount)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Undo
            Button {
                removeSwing()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Actions

    private func addSwing() {
        swingCount += 1
        WKInterfaceDevice.current().play(.click)
        sendSwingUpdate()
    }

    private func removeSwing() {
        guard swingCount > 0 else { return }
        swingCount -= 1
        WKInterfaceDevice.current().play(.directionDown)
        sendSwingUpdate()
    }

    private func sendSwingUpdate() {
        guard let payload else { return }
        let swingPayload = SwingPayload(
            holeNumber: payload.holeNumber,
            courseId: "",   // not needed for iPhone-side lookup
            swingCount: swingCount
        )
        WatchConnectivityManager.shared.sendSwingToPhone(swingPayload)
    }
}

// MARK: - Action Button (Apple Watch Ultra)
// The WKApplicationDelegate method below handles the Ultra's Action Button.
// Add this to a separate file: WatchAppDelegate.swift

/*
class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func actionButtonPressed() {
        // Post notification that WatchRoundView observes
        NotificationCenter.default.post(name: .actionButtonPressed, object: nil)
    }
}
extension Notification.Name {
    static let actionButtonPressed = Notification.Name("actionButtonPressed")
}
*/
