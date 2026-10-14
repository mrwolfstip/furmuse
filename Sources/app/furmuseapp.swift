import SwiftUI

@main
struct FurmuseApp: App {
    private let services = Services.shared

    var body: some Scene {
        WindowGroup {
            RootView().inject(services)
        }
    }
}
