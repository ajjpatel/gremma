import SwiftUI

@main
struct GremmaApp: App {
    @StateObject private var app = AppController()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(app)
                .environmentObject(app.model)
                .environmentObject(app.voice)
                .preferredColorScheme(.dark)
        }
    }
}
