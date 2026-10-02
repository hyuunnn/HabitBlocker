import Foundation
import os
import UserNotifications

// test.sh가 실제 BlockerStore와 아래 대역만 함께 컴파일한다.
// 프록시 변경·알림 권한 창·앱 사용자 설정 없이 조회와 적용의 순서를 통제한다.
enum ProxyBlockService {
    static let listenPort: UInt16 = 47471
    private static let state = OSAllocatedUnfairLock(initialState: (active: false, pendingRead: Optional<PendingRead>.none))

    static func setActive(_ active: Bool) {
        state.withLock { $0.active = active }
    }

    static func delayNextRead() -> PendingRead {
        let read = PendingRead()
        state.withLock { $0.pendingRead = read }
        return read
    }

    static func isBlockActive() -> Bool {
        let (active, read) = state.withLock { state in
            let snapshot = (state.active, state.pendingRead)
            state.pendingRead = nil
            return snapshot
        }
        read?.waitForRelease()
        return active
    }

    static func apply(shouldBlock: Bool, domains: [String], prompt: String) async throws {
        setActive(shouldBlock)
    }

    static func lastAppliedDomains() -> [String]? { nil }
    @discardableResult static func preparePacScript(domains: [String]) -> String { "test" }
    @MainActor static func ensureRejectListenerReady() async throws {}
}

// 조회 시작 표식과 해제 대기는 각각 잠금과 세마포어로 보호한다.
final class PendingRead: @unchecked Sendable {
    private let started = OSAllocatedUnfairLock(initialState: false)
    private let releaseSignal = DispatchSemaphore(value: 0)

    var hasStarted: Bool { started.withLock { $0 } }

    func waitForRelease() {
        started.withLock { $0 = true }
        releaseSignal.wait()
    }

    func release() { releaseSignal.signal() }
}

// Foundation.UserDefaults를 명시해 테스트 프로세스만의 임시 suite를 사용한다.
enum UserDefaults {
    private static let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HabitBlockerStoreTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static let suiteName = directory.appendingPathComponent("defaults").path
    static let standard = Foundation.UserDefaults(suiteName: suiteName)!

    static func reset() { standard.removePersistentDomain(forName: suiteName) }

    static func cleanUp() {
        reset()
        try? FileManager.default.removeItem(at: directory)
    }
}

final class UNUserNotificationCenter {
    struct Settings { let authorizationStatus: UNAuthorizationStatus = .denied }
    static func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
    func notificationSettings() async -> Settings { Settings() }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { false }
    func add(_ request: UNNotificationRequest) async throws {}
}

@main
@MainActor
enum HabitBlockerStoreTests {
    private static var failures = 0

    static func main() async {
        defer { UserDefaults.cleanUp() }
        await testOldRefreshKeepsCompletedFocus()
        await testOldRefreshKeepsCompletedUnblock()
        await testFreshRefreshStillUpdatesState()

        if failures == 0 {
            print("✅ HabitBlocker store tests passed")
        } else {
            print("❌ \(failures) store test(s) failed")
            exit(1)
        }
    }

    private static func makeStore() -> BlockerStore {
        UserDefaults.reset()
        ProxyBlockService.setActive(false)
        let store = BlockerStore()
        _ = store.addSite("example.com")
        return store
    }

    private static func testOldRefreshKeepsCompletedFocus() async {
        let store = makeStore()
        let read = ProxyBlockService.delayNextRead()
        defer { read.release() }
        let refresh = store.refreshSystemState()
        await waitUntil("상태 조회가 시작되어야 합니다.") { read.hasStarted }

        store.startFocus(minutes: 25)
        await waitUntil("집중 세션 적용이 완료되어야 합니다.") { !store.isApplying }
        let startedAt = store.focusStartedAt
        let endDate = store.focusEndDate
        let message = store.statusMessage
        expect(store.isBlocked && store.isFocusActive, "조회 반환 전에 집중 세션이 시작되어야 합니다.")

        read.release()
        await refresh?.value

        expect(store.isBlocked, "과거의 꺼짐 상태가 성공한 차단을 덮으면 안 됩니다.")
        expect(store.isFocusActive && !store.canQuit, "집중 세션과 종료 잠금이 유지되어야 합니다.")
        expect(store.focusStartedAt == startedAt && store.focusEndDate == endDate, "집중 시각이 유지되어야 합니다.")
        expect(UserDefaults.standard.object(forKey: "focusEndDate") as? Date == endDate, "저장된 집중 종료 시각도 유지되어야 합니다.")
        expect(store.statusMessage == message, "성공한 세션 안내가 과거 조회로 바뀌면 안 됩니다.")
    }

    private static func testOldRefreshKeepsCompletedUnblock() async {
        let store = makeStore()
        store.setBlocked(true)
        await waitUntil("차단이 적용되어야 합니다.") { !store.isApplying }
        expect(store.isBlocked, "조회 전에 차단이 켜져 있어야 합니다.")
        let read = ProxyBlockService.delayNextRead()
        defer { read.release() }
        let refresh = store.refreshSystemState()
        await waitUntil("켜짐 상태 조회가 시작되어야 합니다.") { read.hasStarted }

        store.setBlocked(false)
        await waitUntil("차단 해제가 완료되어야 합니다.") { !store.isApplying }
        let message = store.statusMessage
        read.release()
        await refresh?.value

        expect(!store.isBlocked && store.canQuit, "과거의 켜짐 상태가 완료한 해제를 덮으면 안 됩니다.")
        expect(store.statusMessage == message, "해제 안내가 과거 조회로 바뀌면 안 됩니다.")
    }

    private static func testFreshRefreshStillUpdatesState() async {
        let store = makeStore()
        ProxyBlockService.setActive(true)
        await store.refreshSystemState()?.value
        expect(store.isBlocked && !store.canQuit, "새 조회는 외부에서 켠 차단을 반영해야 합니다.")

        ProxyBlockService.setActive(false)
        await store.refreshSystemState()?.value
        expect(!store.isBlocked && store.canQuit, "새 조회는 외부에서 끈 차단도 반영해야 합니다.")
    }

    private static func waitUntil(_ message: String, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { fatalError(message) }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("❌ \(message)")
        }
    }
}
