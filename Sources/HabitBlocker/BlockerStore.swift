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
    private let unlockReadyKey = "unlockReadyAt"
    private let unlockDelayKey = "unlockDelaySeconds"
    private let activityEventsKey = "habitActivityEvents"
    private var unlockWaitTask: Task<Void, Never>?

    var isUnlockPending: Bool {
        unlockReadyAt != nil
    }

    var isUnlockReady: Bool {
        unlockReadyAt != nil && unlockSecondsRemaining == 0
    }

    var statusDescription: String {
        if isApplying { return "시스템 설정을 변경하는 중" }
        if isUnlockPending {
            return isUnlockReady ? "차단 해제를 최종 확인할 수 있습니다" : "차단 해제를 잠시 기다리는 중입니다"
        }
        if let focusEndDate, focusEndDate > Date() {
            return "집중 세션이 진행 중입니다"
        }
        return isBlocked ? "등록한 도메인을 시스템 전체에서 차단합니다" : "현재 등록 사이트에 접근할 수 있습니다"
    }

    var encouragementMessage: String {
        if isUnlockPending {
            return isUnlockReady ? "필요한 일인지 한 번만 더 확인해 보세요." : "지금의 짧은 멈춤이 선택의 여유를 만듭니다."
        }
        if let focusEndDate, focusEndDate > Date() {
            return "방해를 줄인 만큼, 지금 하는 일에 더 깊이 머물 수 있습니다."
        }
        return "차단은 포기가 아니라, 지금 할 일에 집중하기 위한 선택입니다."
    }

    var todayFocusSessionCount: Int {
        activityEvents.filter { $0.kind == .focusStarted && Calendar.current.isDateInToday($0.timestamp) }.count
    }

    var todayPlannedFocusMinutes: Int {
        activityEvents
            .filter { $0.kind == .focusStarted && Calendar.current.isDateInToday($0.timestamp) }
            .reduce(0) { $0 + ($1.minutes ?? 0) }
    }

    var todayUnlockAttemptCount: Int {
        activityEvents.filter { $0.kind == .unlockRequested && Calendar.current.isDateInToday($0.timestamp) }.count
    }

    var recentUnlockAttempts: [HabitActivity] {
        activityEvents
            .filter { $0.kind == .unlockRequested }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(3)
            .map { $0 }
    }

    init() {
        loadSites()
        loadActivityEvents()
        focusEndDate = UserDefaults.standard.object(forKey: focusEndKey) as? Date
        unlockReadyAt = UserDefaults.standard.object(forKey: unlockReadyKey) as? Date
        let savedDelay = UserDefaults.standard.integer(forKey: unlockDelayKey)
        unlockDelaySeconds = [30, 60, 300].contains(savedDelay) ? savedDelay : 60

        ProxyBlockService.startRejectListener()
        // 차단 중에 앱을 다시 실행했다면 마지막 적용 목록으로 PAC을 즉시 복구한다.
        ProxyBlockService.preparePacScript(domains: ProxyBlockService.lastAppliedDomains() ?? sites.map(\.domain))
        isBlocked = ProxyBlockService.isBlockActive()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        scheduleFocusEndIfNeeded()
        scheduleUnlockWaitIfNeeded()
    }

    func addSite(_ rawValue: String) {
        guard let domain = DomainNormalizer.normalize(rawValue) else {
            setStatus("유효한 도메인 또는 URL을 입력하세요.", error: true)
            return
        }
        guard !sites.contains(where: { $0.domain == domain }) else {
            setStatus("\(domain)은(는) 이미 목록에 있습니다.", error: true)
            return
        }

        sites.append(BlockedSite(domain: domain))
        setStatus("\(domain)을(를) 목록에 추가했습니다. 차단 중이라면 ‘목록 변경사항 적용’을 누르세요.", error: false)
    }

    func remove(_ site: BlockedSite) {
        sites.removeAll { $0.id == site.id }
        setStatus("\(site.domain)을(를) 목록에서 제거했습니다. 차단 중이라면 변경사항을 적용하세요.", error: false)
    }

    func setBlocked(_ shouldBlock: Bool) {
        guard !shouldBlock || !sites.isEmpty else {
            setStatus("먼저 차단할 사이트를 추가하세요.", error: true)
            return
        }

        clearUnlockWait()
        performBlockUpdate(shouldBlock: shouldBlock) { [weak self] succeeded in
            guard let self, succeeded else { return }
            self.setStatus(shouldBlock ? "등록 사이트 차단을 켰습니다." : "등록 사이트 차단을 해제했습니다.", error: false)
        }
    }

    func setUnlockDelay(seconds: Int) {
        guard [30, 60, 300].contains(seconds) else { return }
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
        clearUnlockWait()
        setStatus("차단 해제를 취소하고 집중을 이어갑니다.", error: false)
    }

    func confirmUnblock() {
        guard isUnlockReady else {
            setStatus("해제 대기 시간이 끝난 뒤 다시 시도하세요.", error: true)
            return
        }

        performBlockUpdate(shouldBlock: false) { [weak self] succeeded in
            guard let self, succeeded else { return }
            self.recordActivity(.unblocked)
            self.clearUnlockWait()
            self.setStatus("차단을 해제했습니다.", error: false)
        }
    }

    func applyCurrentRules() {
        guard isBlocked, !isUnlockPending else { return }
        performBlockUpdate(shouldBlock: true)
    }

    func showFocusValidationError() {
        setStatus("집중 시간은 1~1,440분 사이의 정수로 입력하세요.", error: true)
    }

    func startFocus(minutes: Int) {
        guard !sites.isEmpty else {
            setStatus("집중 세션 전에 차단할 사이트를 추가하세요.", error: true)
            return
        }
        guard !isUnlockPending else {
            setStatus("진행 중인 해제 대기를 취소한 뒤 집중 세션을 시작하세요.", error: true)
            return
        }

        focusEndDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        performBlockUpdate(shouldBlock: true) { [weak self] succeeded in
            guard let self else { return }
            if succeeded {
                self.recordActivity(.focusStarted, minutes: minutes)
                self.scheduleFocusEndIfNeeded()
                self.setStatus("\(minutes)분 집중 세션을 시작했습니다.", error: false)
                self.showFocusNotification()
            } else {
                self.focusEndDate = nil
            }
        }
    }

    func endFocus() {
        guard !isUnlockPending else { return }
        beginUnlockWait()
    }

    func refreshSystemState() {
        isBlocked = ProxyBlockService.isBlockActive()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if isBlocked {
            // 설정만 남고 리스너가 없는 상태(수동 재활성 등)를 막기 위해 차단 중이면 항상 보증한다.
            ProxyBlockService.startRejectListener()
        }
        if HostFileService.isLegacySectionPresent() {
            setStatus("이전 버전의 hosts 차단 규칙이 남아 있습니다. 차단을 한 번 해제하면 자동으로 정리됩니다.", error: false)
        } else if isBlocked {
            setStatus("시스템 프록시 규칙으로 등록 사이트가 차단되어 있습니다.", error: false)
        } else {
            clearUnlockWait()
            setStatus("현재 차단 규칙이 적용되어 있지 않습니다.", error: false)
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

    private func performBlockUpdate(shouldBlock: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        isApplying = true
        setStatus("관리자 권한 확인을 기다리는 중입니다…", error: false)
        let domains = sites.map(\.domain)

        Task {
            do {
                try await ProxyBlockService.apply(shouldBlock: shouldBlock, domains: domains)
                isBlocked = shouldBlock
                isApplying = false
                if !shouldBlock {
                    focusEndDate = nil
                }
                if shouldBlock, !ProxyBlockService.isListenerRunning {
                    setStatus("차단 규칙은 적용됐지만 로컬 응답 서버를 시작하지 못했습니다. 차단 사이트는 브라우저 기본 오류 화면으로 표시됩니다.", error: true)
                } else if statusMessage.contains("관리자 권한") {
                    setStatus(shouldBlock ? "차단 규칙을 적용했습니다." : "차단을 해제했습니다.", error: false)
                }
                completion(true)
            } catch {
                isApplying = false
                isBlocked = ProxyBlockService.isBlockActive()
                setStatus("변경하지 못했습니다: \(error.localizedDescription)", error: true)
                completion(false)
            }
        }
    }

    private func scheduleFocusEndIfNeeded() {
        guard let focusEndDate else { return }
        let remaining = focusEndDate.timeIntervalSinceNow
        if remaining <= 0 {
            self.focusEndDate = nil
            if isBlocked {
                performBlockUpdate(shouldBlock: false) { [weak self] succeeded in
                    if succeeded { self?.recordActivity(.focusCompleted) }
                }
            }
            return
        }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, let endDate = self.focusEndDate, endDate <= Date() else { return }
            self.focusEndDate = nil
            if self.isBlocked {
                self.performBlockUpdate(shouldBlock: false) { [weak self] succeeded in
                    guard let self, succeeded else { return }
                    self.recordActivity(.focusCompleted)
                    self.clearUnlockWait()
                    self.setStatus("집중 시간이 끝나 차단을 해제했습니다.", error: false)
                }
            }
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

    private func recordActivity(_ kind: HabitActivityKind, minutes: Int? = nil) {
        activityEvents.append(HabitActivity(kind: kind, minutes: minutes))
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? .distantPast
        activityEvents.removeAll { $0.timestamp < cutoff }
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
