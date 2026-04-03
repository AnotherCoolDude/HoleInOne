import SwiftData
import SwiftUI

@main
struct HoleInOneApp: App {
    var body: some Scene {
        WindowGroup {
            CourseSearchView()
        }
        .modelContainer(for: [RoundResult.self, HoleResult.self, SavedCourse.self])
    }
}
