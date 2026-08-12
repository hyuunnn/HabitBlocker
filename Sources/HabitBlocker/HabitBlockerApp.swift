import SwiftUI

@main
struct HabitBlockerApp: App {
    @StateObject private var store = BlockerStore()

    var body: some Scene {
        MenuBarExtra(
            "습관 차단기",
            systemImage: store.isBlocked ? "shield.fill" : "shield"
        ) {
            MenuContentView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}
