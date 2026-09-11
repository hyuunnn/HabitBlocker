import SwiftUI

@main
struct HabitBlockerApp: App {
    @NSApplicationDelegateAdaptor(HabitBlockerAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appDelegate.store)
        } label: {
            MenuBarIcon(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class HabitBlockerAppDelegate: NSObject, NSApplicationDelegate {
    let store = BlockerStore()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !store.canQuit else {
            return .terminateNow
        }
        store.notifyQuitBlocked()
        return .terminateCancel
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var store: BlockerStore

    var body: some View {
        Image(systemName: store.isBlocked ? "shield.fill" : "shield")
    }
}
