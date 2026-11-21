import SwiftUI

@main
struct AdFreeAndroidLauncherApp: App {
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 880, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}
