import SwiftUI

@main
struct HoleInOneWatchApp: App {
    @State private var watchManager = WatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            WatchRoundView()
                .environment(watchManager)
        }
    }
}
