import SwiftUI

@main
struct BezelApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Bezel") {
            ContentView()
                .environment(state)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
