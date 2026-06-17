import SwiftUI

@main
struct WakeOnLanApp: App {
    @StateObject private var store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
