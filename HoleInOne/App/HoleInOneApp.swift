import SwiftData
import SwiftUI

@main
struct HoleInOneApp: App {

    let container: ModelContainer = {
        let schema = Schema([RoundResult.self, HoleResult.self, SavedCourse.self, LearnedHoleGPS.self])
        // Keep SwiftData store local-only; CloudKit sync is handled directly
        // by CloudGPSService via the public CloudKit database.
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        return try! ModelContainer(for: schema, configurations: config)
    }()

    var body: some Scene {
        WindowGroup {
            CourseSearchView()
                .environment(PlayerProfile.shared)
                .task {
                    #if DEBUG
                    await MockDataService.seedIfNeeded(modelContext: container.mainContext)
                    #endif
                }
        }
        .modelContainer(container)
    }
}
