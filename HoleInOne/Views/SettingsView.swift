import SwiftUI

struct SettingsView: View {
    @Environment(PlayerProfile.self) private var profile
    @AppStorage("preferredDistanceUnit") private var unitRaw: String = DistanceUnit.yards.rawValue

    @State private var showTeeNameSuggestions = false

    private var selectedUnit: Binding<DistanceUnit> {
        Binding(
            get: { DistanceUnit(rawValue: unitRaw) ?? .yards },
            set: { unitRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {

            // MARK: Player profile
            Section {
                // Name
                HStack {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    TextField("Your name", text: Bindable(profile).name)
                        .autocorrectionDisabled()
                }

                // Handicap
                HStack {
                    Image(systemName: "gauge.with.needle")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text("Handicap Index")
                    Spacer()
                    Text(profile.handicapDisplay)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                // Handicap stepper — range +10 (shown as -10) to 54
                Stepper(
                    value: Bindable(profile).handicapIndex,
                    in: -10...54,
                    step: 0.1
                ) {
                    EmptyView()
                }
                .labelsHidden()

            } header: {
                Text("Player Profile")
            } footer: {
                Text("Your name and handicap index appear in your round history.")
            }

            // MARK: Tee preference
            Section {
                // Gender
                Picker("Tee", selection: Bindable(profile).teeGender) {
                    ForEach(PlayerProfile.TeeGender.allCases) { gender in
                        Text(gender.displayName).tag(gender)
                    }
                }
                .pickerStyle(.segmented)

                // Tee name with quick-pick suggestions
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Preferred tee colour")
                            .font(.subheadline)
                        Spacer()
                        if !profile.preferredTeeName.isEmpty {
                            Button("Clear") {
                                profile.preferredTeeName = ""
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    TextField("e.g. Blue, White, Red…", text: Bindable(profile).preferredTeeName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)

                    // Suggestion chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(profile.teeGender.commonTeeNames, id: \.self) { tee in
                                Button(tee) {
                                    profile.preferredTeeName = tee
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    profile.preferredTeeName.lowercased() == tee.lowercased()
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(
                                    profile.preferredTeeName.lowercased() == tee.lowercased()
                                        ? Color.white
                                        : Color.primary
                                )
                            }
                        }
                    }
                }

            } header: {
                Text("Tee Preference")
            } footer: {
                Text("The app will try to load your preferred tee when available. Leave colour blank to use the first available tee for your chosen category.")
            }

            // MARK: Distance unit
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

            // MARK: About
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
