import SwiftUI

struct SettingsView: View {
    @AppStorage("preferredDistanceUnit") private var unitRaw: String = DistanceUnit.yards.rawValue

    private var selectedUnit: Binding<DistanceUnit> {
        Binding(
            get: { DistanceUnit(rawValue: unitRaw) ?? .yards },
            set: { unitRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Distance Unit") {
                Picker("Unit", selection: selectedUnit) {
                    ForEach(DistanceUnit.allCases) { unit in
                        HStack {
                            Text(unit.displayName)
                            Spacer()
                            Text(unit.abbreviation)
                                .foregroundStyle(.secondary)
                        }
                        .tag(unit)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
