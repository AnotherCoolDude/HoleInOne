import SwiftData
import SwiftUI

@main
struct HoleInOneApp: App {

    let container: ModelContainer = {
        let schema = Schema([RoundResult.self, HoleResult.self, SavedCourse.self, LearnedHoleGPS.self])
        return try! ModelContainer(for: schema)
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
