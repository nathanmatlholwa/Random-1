import SwiftUI

@main
struct MathsToFailureApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .task { await app.bootstrap() }
        }
    }
}
