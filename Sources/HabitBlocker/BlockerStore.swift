import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class BlockerStore: ObservableObject {
    @Published private(set) var sites: [BlockedSite] = [] {
        didSet { saveSites() }
    }
    @Published private(set) var isBlocked = false
    @Published private(set) var isApplying = false
    @Published private(set) var focusEndDate: Date? {
        didSet { saveFocusEndDate() }
    }
    @Published private(set) var focusStartedAt: Date? {
        didSet { saveFocusStartedAt() }
    }
    @Published private(set) var unlockReadyAt: Date? {
        didSet { saveUnlockReadyDate() }
    }
    @Published private(set) var unlockSecondsRemaining = 0
    @Published private(set) var unlockDelaySeconds = 60 {
        didSet { UserDefaults.standard.set(unlockDelaySeconds, forKey: unlockDelayKey) }
    }
    @Published private(set) var activityEvents: [HabitActivity] = [] {
        didSet { saveActivityEvents() }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var statusIsError = false

    private let sitesKey = "blockedSites"
    private let focusEndKey = "focusEndDate"
    private let focusStartedKey = "focusStartedAt"
    private let unlockReadyKey = "unlockReadyAt"
    private let unlockDelayKey = "unlockDelaySeconds"
    private let activityEventsKey = "habitActivityEvents"
    private var unlockWaitTask: Task<Void, Never>?
    private var isRefreshing = false
    private var systemMutationVersion = 0

    private static let blockPrompt = "습관 차단기가 등록한 사이트를 차단하려고 합니다."
    private static let unblockPrompt = "습관 차단기가 사이트 차단을 해제하려고 합니다."
    private static let focusEndPrompt = "집중 시간이 끝나 습관 차단기가 사이트 차단을 해제하려고 합니다."
    private static let listenerDownMessage = "로컬 응답 서버(127.0.0.1:\(ProxyBlockService.listenPort))를 시작하지 못해 지금은 차단이 적용되지 않습니다. 이 포트를 쓰는 다른 프로그램을 종료한 뒤 메뉴를 다시 여세요."

    var isUnlockPending: Bool {
        unlockReadyAt != nil
    }

    var isUnlockReady: Bool {
        unlockReadyAt != nil && unlockSecondsRemaining == 0
    }

    var isFocusActive: Bool {
        guard let focusEndDate else { return false }
        return focusEndDate > Date()
    }

    var isSessionLocked: Bool {
        isFocusActive || isUnlockPending
    }

    /// 집중 종료 시각이 지났는데 차단이 아직 켜져 있다. 해제 암호를 취소했거나 앱이 꺼져 있는 동안 끝난 경우다.
    /// 자동 해제 암호 창이 떠 있는 동안(isApplying)은 아직 해제 중이므로 제외한다.
    var isFocusExpired: Bool {
        guard isBlocked, !isApplying, !isUnlockPending, let focusEndDate else { return false }
        return focusEndDate <= Date()
    }

    var canQuit: Bool {
        !isBlocked && !isFocusActive && !isApplying
    }

    var statusDescription: String {
        if isApplying { return "시스템 설정을 변경하는 중" }
        if isUnlockPending {
            return isUnlockReady ? "차단 해제를 최종 확인할 수 있습니다" : "차단 해제를 잠시 기다리는 중입니다"
        }
        if isFocusActive {
            return "집중 세션이 진행 중입니다"
        }
        return isBlocked ? "등록한 도메인을 시스템 전체에서 차단합니다" : "현재 등록 사이트에 접근할 수 있습니다"
    }

    var encouragementMessage: String {
        if isUnlockPending {
            return isUnlockReady ? "필요한 일인지 한 번만 더 확인해 보세요." : "지금의 짧은 멈춤이 선택의 여유를 만듭니다."
        }
        if isFocusActive {
            return "방해를 줄인 만큼, 지금 하는 일에 더 깊이 머물 수 있습니다."
        }
        return "차단은 포기가 아니라, 지금 할 일에 집중하기 위한 선택입니다."
    }

    var todayFocusSessionCount: Int {
        activityEvents.filter { $0.kind == .focusStarted && Calendar.current.isDateInToday($0.timestamp) }.count
    }

    var todayFocusMinutes: Int {
        activityEvents
            .filter {
                ($0.kind == .focusCompleted || $0.kind == .unblocked)
                    && Calendar.current.isDateInToday($0.timestamp)
            }
            .reduce(0) { $0 + ($1.minutes ?? 0) }
    }

    var todayUnlockAttemptCount: Int {
        activityEvents.filter { $0.kind == .unlockRequested && Calendar.current.isDateInToday($0.timestamp) }.count
    }

    var latestUnlockAttempt: HabitActivity? {
        activityEvents
            .filter { $0.kind == .unlockRequested && Calendar.current.isDateInToday($0.timestamp) }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    init() {
        loadSites()
        loadActivityEvents()
        focusEndDate = UserDefaults.standard.object(forKey: focusEndKey) as? Date
        focusStartedAt = UserDefaults.standard.object(forKey: focusStartedKey) as? Date
        unlockReadyAt = UserDefaults.standard.object(forKey: unlockReadyKey) as? Date
        let savedDelay = UserDefaults.standard.integer(forKey: unlockDelayKey)
        unlockDelaySeconds = [30, 60, 300].contains(savedDelay) ? savedDelay : 60

        // 첫 화면 상태를 정확히 잡도록 실행 시에는 동기로 읽는다. 메뉴를 열 때는 백그라운드에서 읽는다.
        isBlocked = ProxyBlockService.isBlockActive()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if isBlocked {
            // 차단 중에 앱을 다시 실행했다면 마지막 적용 목록으로 PAC과 리스너를 즉시 복구한다.
            restoreBlockingServer()
        } else {
            clearUnlockWait()
            clearFocusSession()
        }

        if isFocusExpired {
            // 앱이 꺼져 있는 동안 끝난 세션이다. 로그인 직후 설명 없이 암호 창을 띄우는 대신
            // 차단을 유지한 채 메뉴에서 해제하도록 안내한다.
            setStatus("앱이 꺼져 있는 동안 집중 시간이 끝났습니다. 차단을 해제하려면 '등록 사이트 차단'을 끄세요.", error: false)
        } else {
            scheduleFocusEndIfNeeded()
        }
        scheduleUnlockWaitIfNeeded()
    }

    @discardableResult
    func addSite(_ rawValue: String) -> Bool {
        if isBlocked || isApplying {
            setStatus("차단이 켜져 있을 때는 목록을 바꿀 수 없습니다.", error: true)
            return false
        }
        guard let domain = DomainNormalizer.normalize(rawValue) else {
            setStatus("유효한 도메인 또는 URL을 입력하세요.", error: true)
            return false
        }
        guard !sites.contains(where: { $0.domain == domain }) else {
            setStatus("\(domain)은(는) 이미 목록에 있습니다.", error: true)
            return false
        }

        sites.append(BlockedSite(domain: domain))
        setStatus("\(domain)을(를) 목록에 추가했습니다.", error: false)
        return true
    }

    func remove(_ site: BlockedSite) {
        if isBlocked || isApplying {
            setStatus("차단이 켜져 있을 때는 목록을 바꿀 수 없습니다.", error: true)
            return
        }
        sites.removeAll { $0.id == site.id }
        setStatus("\(site.domain)을(를) 목록에서 제거했습니다.", error: false)
    }

    func setBlocked(_ shouldBlock: Bool) {
        if isUnlockPending {
            setStatus("진행 중인 해제 대기를 마친 뒤 차단을 변경하세요.", error: true)
            return
        }
        if isFocusActive {
            setStatus("집중 세션 중에는 차단을 직접 끄거나 켤 수 없습니다. 세션을 종료하세요.", error: true)
            return
        }
        guard !shouldBlock || !sites.isEmpty else {
            setStatus("먼저 차단할 사이트를 추가하세요.", error: true)
            return
        }

        performBlockUpdate(shouldBlock: shouldBlock) { [weak self] succeeded in
            guard let self, succeeded, !shouldBlock else { return }
            self.recordElapsedFocus(as: .unblocked)
        }
    }

    func setUnlockDelay(seconds: Int) {
        guard [30, 60, 300].contains(seconds) else { return }
        if isBlocked {
            setStatus("해제 대기 시간은 차단이 꺼져 있을 때만 바꿀 수 있습니다.", error: true)
            return
        }
        unlockDelaySeconds = seconds
        setStatus("차단 해제 대기 시간을 \(unlockDelayLabel)으로 설정했습니다.", error: false)
    }

    func beginUnlockWait() {
        guard isBlocked, !isApplying else { return }
        guard unlockReadyAt == nil else { return }

        recordActivity(.unlockRequested)
        unlockReadyAt = Date().addingTimeInterval(TimeInterval(unlockDelaySeconds))
        scheduleUnlockWaitIfNeeded()
        setStatus("차단 해제 시도를 기록했습니다. \(unlockDelayLabel) 뒤에 최종 해제할 수 있습니다.", error: false)
    }

    func cancelUnlockWait() {
        let focusAlreadyEnded = focusEndDate.map { $0 <= Date() } ?? false
        clearUnlockWait()
        if focusAlreadyEnded {
            recordElapsedFocus(as: .focusCompleted)
            focusEndDate = nil
            setStatus("차단 해제를 취소하고 차단을 유지합니다.", error: false)
        } else {
            setStatus("차단 해제를 취소하고 집중을 이어갑니다.", error: false)
        }
    }

    func confirmUnblock() {
        guard isUnlockReady else {
            setStatus("해제 대기 시간이 끝난 뒤 다시 시도하세요.", error: true)
            return
        }

        performBlockUpdate(shouldBlock: false) { [weak self] succeeded in
            guard let self, succeeded else { return }
            self.recordElapsedFocus(as: .unblocked)
            self.clearUnlockWait()
            self.setStatus("차단을 해제했습니다.", error: false)
        }
    }

    func showFocusValidationError() {
        setStatus("집중 시간은 1~1,440분 사이의 정수로 입력하세요.", error: true)
    }

    func startFocus(minutes: Int) {
        guard !sites.isEmpty else {
            setStatus("집중 세션 전에 차단할 사이트를 추가하세요.", error: true)
            return
        }
        if isApplying {
            return
        }
        if isBlocked {
            setStatus("차단을 끈 뒤에 집중 세션을 시작하세요.", error: true)
            return
        }

        // 암호를 묻기 전에 세션을 먼저 저장해 둔다. 차단이 적용된 뒤 완료 콜백 전에 앱이 죽어도
        // 다시 실행하면 일반 차단이 아니라 집중 세션으로 복원된다. 시각은 성공 뒤에 다시 맞춘다.
        let startedAt = Date()
        focusStartedAt = startedAt
        focusEndDate = startedAt.addingTimeInterval(TimeInterval(minutes * 60))
        performBlockUpdate(shouldBlock: true) { [weak self] succeeded in
            guard let self else { return }
            if succeeded {
                // 암호 입력을 기다린 시간은 세션에 넣지 않는다. 차단이 실제로 켜진 시각부터 센다.
                let blockedAt = Date()
                self.focusStartedAt = blockedAt
                self.focusEndDate = blockedAt.addingTimeInterval(TimeInterval(minutes * 60))
                self.recordActivity(.focusStarted)
                self.scheduleFocusEndIfNeeded()
                self.setStatus("\(minutes)분 집중 세션을 시작했습니다.", error: false)
                self.showFocusNotification()
            } else {
                self.clearFocusSession()
            }
        }
    }

    func endFocus() {
        guard !isUnlockPending else { return }
        beginUnlockWait()
    }

    func quitIfAllowed() {
        guard canQuit else {
            notifyQuitBlocked()
            return
        }
        NSApplication.shared.terminate(nil)
    }

    func notifyQuitBlocked() {
        setStatus("차단 또는 집중 세션이 켜져 있을 때는 앱을 종료할 수 없습니다.", error: true)
    }

    @discardableResult
    func refreshSystemState() -> Task<Void, Never>? {
        guard !isApplying, !isRefreshing else { return nil }
        isRefreshing = true
        let readVersion = systemMutationVersion
        launchAtLogin = SMAppService.mainApp.status == .enabled

        return Task {
            // networksetup을 여러 번 실행하므로 메뉴가 멈추지 않게 메인 스레드 밖에서 읽는다.
            let active = await Task.detached(priority: .userInitiated) { ProxyBlockService.isBlockActive() }.value
            isRefreshing = false
            // 조회 뒤 시작한 적용이 이미 끝났더라도, 그 이전 상태를 반영하지 않는다.
            guard !isApplying, readVersion == systemMutationVersion else { return }

            let changed = active != isBlocked
            isBlocked = active
            if active {
                // 설정만 남고 리스너가 없는 상태(수동 재활성 등)를 막기 위해 차단 중이면 항상 보증한다.
                restoreBlockingServer()
            } else {
                clearUnlockWait()
                clearFocusSession()
            }
            // 직전 작업의 결과나 오류 문구를 지우지 않도록, 바깥에서 상태가 바뀐 경우에만 안내를 바꾼다.
            if changed {
                setStatus(active ? "시스템 프록시 규칙으로 등록 사이트가 차단되어 있습니다." : "현재 차단 규칙이 적용되어 있지 않습니다.", error: false)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            setStatus(launchAtLogin ? "로그인 시 자동 실행을 켰습니다." : "로그인 시 자동 실행을 껐습니다.", error: false)
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            setStatus("자동 실행 설정을 변경하지 못했습니다: \(error.localizedDescription)", error: true)
        }
    }

    private var unlockDelayLabel: String {
        switch unlockDelaySeconds {
        case 30: return "30초"
        case 300: return "5분"
        default: return "1분"
        }
    }

    private func performBlockUpdate(shouldBlock: Bool,
                                    prompt: String? = nil,
                                    completion: @escaping (Bool) -> Void) {
        guard !isApplying else { return }
        systemMutationVersion += 1
        isApplying = true
        setStatus("관리자 권한 확인을 기다리는 중입니다…", error: false)
        let domains = sites.map(\.domain)
        let prompt = prompt ?? (shouldBlock ? Self.blockPrompt : Self.unblockPrompt)

        Task {
            do {
                try await ProxyBlockService.apply(shouldBlock: shouldBlock, domains: domains, prompt: prompt)
                isBlocked = shouldBlock
                isApplying = false
                setStatus(shouldBlock ? "차단 규칙을 적용했습니다." : "차단을 해제했습니다.", error: false)
                completion(true)
                // 완료 콜백이 계획 종료 시각으로 집중 시간을 자를 수 있도록 세션 종료 시각은 콜백 뒤에 지운다.
                if !shouldBlock {
                    focusEndDate = nil
                }
            } catch {
                // 실패 뒤의 실제 상태를 메인 스레드 밖에서 읽는다. 다 읽을 때까지 적용 중 상태를 유지한다.
                let active = await Task.detached(priority: .userInitiated) { ProxyBlockService.isBlockActive() }.value
                isBlocked = active
                isApplying = false
                setStatus("변경하지 못했습니다: \(error.localizedDescription)", error: true)
                completion(false)
            }
        }
    }

    /// 시스템 설정은 우리 PAC을 가리키는데 리스너가 없으면 차단이 전혀 적용되지 않는다.
    /// 마지막으로 적용한 목록으로 PAC을 다시 만들고 리스너를 띄운다. 포트를 잡지 못하면 그 사실을 알린다.
    private func restoreBlockingServer() {
        ProxyBlockService.preparePacScript(domains: ProxyBlockService.lastAppliedDomains() ?? sites.map(\.domain))
        Task {
            do {
                try await ProxyBlockService.ensureRejectListenerReady()
                // 메뉴를 다시 열어 포트 충돌에서 회복했으면 남아 있는 리스너 오류만 지운다. 다른 문구는 건드리지 않는다.
                if statusIsError, statusMessage == Self.listenerDownMessage {
                    setStatus("시스템 프록시 규칙으로 등록 사이트가 차단되어 있습니다.", error: false)
                }
            } catch {
                // 그사이 해제됐거나 다른 적용이 시작됐다면 더 최신 문구를 덮지 않는다.
                guard isBlocked, !isApplying else { return }
                setStatus(Self.listenerDownMessage, error: true)
            }
        }
    }

    private func scheduleFocusEndIfNeeded() {
        guard let focusEndDate else { return }
        let remaining = focusEndDate.timeIntervalSinceNow
        if remaining <= 0 {
            finishFocusIfNeeded()
            return
        }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, let endDate = self.focusEndDate, endDate <= Date() else { return }
            self.finishFocusIfNeeded()
        }
    }

    private func finishFocusIfNeeded() {
        if isUnlockPending {
            return
        }
        if isBlocked {
            performBlockUpdate(shouldBlock: false, prompt: Self.focusEndPrompt) { [weak self] succeeded in
                guard let self, succeeded else { return }
                self.recordElapsedFocus(as: .focusCompleted)
                self.setStatus("집중 시간이 끝나 차단을 해제했습니다.", error: false)
            }
        } else {
            clearFocusSession()
        }
    }

    private func scheduleUnlockWaitIfNeeded() {
        unlockWaitTask?.cancel()
        guard let unlockReadyAt else {
            unlockSecondsRemaining = 0
            return
        }

        let initialRemaining = max(0, Int(ceil(unlockReadyAt.timeIntervalSinceNow)))
        unlockSecondsRemaining = initialRemaining
        guard initialRemaining > 0 else {
            setStatus("해제 대기 시간이 끝났습니다. 차단 해제를 누르세요.", error: false)
            return
        }

        unlockWaitTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let deadline = self.unlockReadyAt else { return }
                let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                self.unlockSecondsRemaining = remaining
                if remaining == 0 {
                    self.setStatus("해제 대기 시간이 끝났습니다. 차단 해제를 누르세요.", error: false)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func clearUnlockWait() {
        unlockWaitTask?.cancel()
        unlockWaitTask = nil
        unlockReadyAt = nil
        unlockSecondsRemaining = 0
    }

    private func clearFocusSession() {
        focusEndDate = nil
        focusStartedAt = nil
    }

    private func recordElapsedFocus(as kind: HabitActivityKind) {
        guard let start = focusStartedAt else { return }
        recordActivity(kind, minutes: FocusDuration.recordedMinutes(from: start, plannedEnd: focusEndDate))
        focusStartedAt = nil
    }

    private func recordActivity(_ kind: HabitActivityKind, minutes: Int? = nil) {
        activityEvents.append(HabitActivity(kind: kind, minutes: minutes))
        dropActivityBeforeToday()
    }

    private func loadSites() {
        guard let data = UserDefaults.standard.data(forKey: sitesKey) else { return }
        sites = (try? JSONDecoder().decode([BlockedSite].self, from: data)) ?? []
    }

    private func saveSites() {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        UserDefaults.standard.set(data, forKey: sitesKey)
    }

    private func loadActivityEvents() {
        guard let data = UserDefaults.standard.data(forKey: activityEventsKey) else { return }
        activityEvents = (try? JSONDecoder().decode([HabitActivity].self, from: data)) ?? []
        dropActivityBeforeToday()
    }

    private func dropActivityBeforeToday() {
        activityEvents.removeAll { !Calendar.current.isDateInToday($0.timestamp) }
    }

    private func saveActivityEvents() {
        guard let data = try? JSONEncoder().encode(activityEvents) else { return }
        UserDefaults.standard.set(data, forKey: activityEventsKey)
    }

    private func saveFocusEndDate() {
        if let focusEndDate {
            UserDefaults.standard.set(focusEndDate, forKey: focusEndKey)
        } else {
            UserDefaults.standard.removeObject(forKey: focusEndKey)
        }
    }

    private func saveFocusStartedAt() {
        if let focusStartedAt {
            UserDefaults.standard.set(focusStartedAt, forKey: focusStartedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: focusStartedKey)
        }
    }

    private func saveUnlockReadyDate() {
        if let unlockReadyAt {
            UserDefaults.standard.set(unlockReadyAt, forKey: unlockReadyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: unlockReadyKey)
        }
    }

    private func showFocusNotification() {
        Task {
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }

            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = "습관 차단기"
            content.body = encouragementMessage
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    private func setStatus(_ message: String, error: Bool) {
        statusMessage = message
        statusIsError = error
    }
}
