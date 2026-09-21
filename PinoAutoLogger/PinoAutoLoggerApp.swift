import SwiftUI

@main
struct PinoAutoLoggerApp: App {
    @StateObject private var controller = AutoLoggerController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .task {
                    controller.start()
                }
        }
    }
}
