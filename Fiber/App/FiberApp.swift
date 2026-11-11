import SwiftUI

@main
struct FiberApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                #if targetEnvironment(macCatalyst)
                .frame(minWidth: 720, minHeight: 600)
                #endif
        }
    }
}
