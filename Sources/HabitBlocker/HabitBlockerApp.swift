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
        if isSystemPowerOffEvent {
            return .terminateNow
        }
        guard !store.canQuit else {
            return .terminateNow
        }
        store.notifyQuitBlocked()
        return .terminateCancel
    }

    /// 로그아웃·재시동·시스템 종료는 앱 종료 잠금으로 막지 않는다.
    var isSystemPowerOffEvent: Bool {
        HabitBlockerAppDelegate.isSystemPowerOff(NSAppleEventManager.shared().currentAppleEvent)
    }

    static func isSystemPowerOff(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let why = event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else {
            return false
        }
        switch why.typeCodeValue {
        case OSType(kAEShutDown), OSType(kAERestart), OSType(kAELogOut):
            return true
        default:
            return false
        }
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var store: BlockerStore

    var body: some View {
        Image(systemName: store.isBlocked ? "shield.fill" : "shield")
    }
}
