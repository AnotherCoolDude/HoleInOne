import SwiftData
import SwiftUI

@main
struct HoleInOneApp: App {
    var body: some Scene {
        WindowGroup {
            CourseSearchView()
                .environment(PlayerProfile.shared)
        }
        .modelContainer(for: [RoundResult.self, HoleResult.self, SavedCourse.self])
    }
}
