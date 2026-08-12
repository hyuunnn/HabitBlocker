import SwiftUI
import ServiceManagement
import UserNotifications

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

@MainActor
private struct MenuContentView: View {
    @EnvironmentObject private var store: BlockerStore
    @State private var newSite = ""
    @State private var selectedFocusMinutes = 25
    @State private var customFocusMinutes = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                blockingControl
                siteList
                focusSession
                todaySummary
                appControls
            }
            .padding(16)
        }
        .frame(width: 380, height: 650)
        .onAppear {
            store.refreshSystemState()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: store.isBlocked ? "shield.checkered" : "shield")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(store.isBlocked ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.isBlocked ? "차단 중" : "차단 해제")
                    .font(.headline)
                Text(store.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
    }

    private var blockingControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("등록 사이트 차단", isOn: Binding(
                get: { store.isBlocked },
                set: { store.setBlocked($0) }
            ))
            .toggleStyle(.switch)
            .disabled(store.isApplying || store.sites.isEmpty || store.isUnlockPending)

            if store.isBlocked {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(store.encouragementMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if store.isUnlockPending {
                unlockWaitPanel
            } else if store.isBlocked {
                HStack(spacing: 8) {
                    Text("해제 대기")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("해제 대기", selection: Binding(
                        get: { store.unlockDelaySeconds },
                        set: { store.setUnlockDelay(seconds: $0) }
                    )) {
                        Text("30초").tag(30)
                        Text("1분").tag(60)
                        Text("5분").tag(300)
                    }
                    .labelsHidden()
                    .frame(width: 78)

                    Text("충동적인 해제를 한 번 멈춥니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var unlockWaitPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: store.isUnlockReady ? "checkmark.circle.fill" : "hourglass")
                    .foregroundStyle(store.isUnlockReady ? .green : .orange)

                Text(store.isUnlockReady ? "해제 대기 완료" : "차단 해제까지 \(store.unlockSecondsRemaining)초")
                    .font(.subheadline.weight(.semibold))

                Spacer()
            }

            Text(store.isUnlockReady ? "정말 필요할 때만 차단을 해제하세요." : "해제 시도를 기록했습니다. 잠깐 멈춰도 괜찮습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if store.isUnlockReady {
                    Button("차단 해제") {
                        store.confirmUnblock()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(store.isApplying)

                    Button("계속 차단") {
                        store.cancelUnlockWait()
                    }
                    .disabled(store.isApplying)
                } else {
                    Button("해제 대기 취소") {
                        store.cancelUnlockWait()
                    }
                    .disabled(store.isApplying)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var siteList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("차단 목록")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("youtube.com 또는 링크 입력", text: $newSite)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSite)

                Button(action: addSite) {
                    Image(systemName: "plus")
                }
                .disabled(newSite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("사이트 추가")
            }

            if store.sites.isEmpty {
                Text("차단할 사이트 또는 URL을 추가하세요.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.sites) { site in
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .foregroundStyle(.secondary)
                            Text(site.domain)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                store.remove(site)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("목록에서 제거")
                        }
                        .padding(.vertical, 6)

                        if site.id != store.sites.last?.id {
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 120)

                if store.isBlocked && !store.isUnlockPending {
                    Button("목록 변경사항 적용") {
                        store.applyCurrentRules()
                    }
                    .disabled(store.isApplying)
                }
            }
        }
    }

    private var focusSession: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("집중 세션")
                .font(.headline)

            if let focusEnd = store.focusEndDate, focusEnd > Date() {
                HStack {
                    Image(systemName: "timer")
                        .foregroundStyle(.orange)
                    Text("\(focusEnd.formatted(date: .omitted, time: .shortened))까지 차단 유지")
                        .font(.subheadline)
                    Spacer()
                    Button("종료") {
                        store.endFocus()
                    }
                    .disabled(store.isApplying || store.isUnlockPending)
                }
            } else {
                HStack(spacing: 8) {
                    Picker("빠른 시간", selection: $selectedFocusMinutes) {
                        Text("25분").tag(25)
                        Text("45분").tag(45)
                        Text("60분").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 78)

                    Text("또는")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("직접 입력", text: $customFocusMinutes)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 78)
                        .onSubmit(startFocus)

                    Text("분")
                        .foregroundStyle(.secondary)

                    Button("집중 시작", action: startFocus)
                        .disabled(store.sites.isEmpty || store.isApplying || store.isUnlockPending)
                }

                Text("빠른 시간을 고르거나 1~1,440분을 직접 입력하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var todaySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack {
                Text("오늘의 요약")
                    .font(.headline)
                Spacer()
                Text("이 기기에만 저장")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                MetricView(value: "\(store.todayFocusSessionCount)회", label: "집중 시작")
                MetricView(value: "\(store.todayPlannedFocusMinutes)분", label: "설정 시간")
                MetricView(value: "\(store.todayUnlockAttemptCount)회", label: "해제 시도")
            }

            if let latestAttempt = store.recentUnlockAttempts.first {
                Text("최근 해제 시도: \(latestAttempt.timestamp.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("오늘 해제 시도가 아직 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Toggle("로그인 시 자동 실행", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            .disabled(store.isApplying)

            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(store.statusIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("상태 새로고침") {
                    store.refreshSystemState()
                }
                .disabled(store.isApplying)

                Spacer()

                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }

    private var focusDuration: Int? {
        let trimmed = customFocusMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return selectedFocusMinutes }
        guard let minutes = Int(trimmed), (1...1440).contains(minutes) else { return nil }
        return minutes
    }

    private func startFocus() {
        guard let minutes = focusDuration else {
            store.showFocusValidationError()
            return
        }
        store.startFocus(minutes: minutes)
    }

    private func addSite() {
        store.addSite(newSite)
        newSite = ""
    }
}

private struct MetricView: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

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
        isBlocked = HostFileService.isManagedBlockActive()
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

        if shouldBlock {
            clearUnlockWait(silently: true)
            performHostUpdate(shouldBlock: true)
        } else {
            beginUnlockWait()
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
        clearUnlockWait(silently: true)
        setStatus("차단 해제를 취소하고 집중을 이어갑니다.", error: false)
    }

    func confirmUnblock() {
        guard isUnlockReady else {
            setStatus("해제 대기 시간이 끝난 뒤 다시 시도하세요.", error: true)
            return
        }

        performHostUpdate(shouldBlock: false) { [weak self] succeeded in
            guard let self, succeeded else { return }
            self.recordActivity(.unblocked)
            self.clearUnlockWait(silently: true)
            self.setStatus("차단을 해제했습니다.", error: false)
        }
    }

    func applyCurrentRules() {
        guard isBlocked, !isUnlockPending else { return }
        performHostUpdate(shouldBlock: true)
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
        performHostUpdate(shouldBlock: true) { [weak self] succeeded in
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
        isBlocked = HostFileService.isManagedBlockActive()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if isBlocked {
            setStatus("현재 hosts 파일에 습관 차단기 규칙이 적용되어 있습니다.", error: false)
        } else {
            clearUnlockWait(silently: true)
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

    private func performHostUpdate(shouldBlock: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        isApplying = true
        setStatus("관리자 권한 확인을 기다리는 중입니다…", error: false)
        let domains = sites.map(\.domain)

        Task {
            do {
                try await HostFileService.updateHosts(shouldBlock: shouldBlock, domains: domains)
                isBlocked = shouldBlock
                isApplying = false
                if !shouldBlock {
                    focusEndDate = nil
                }
                if statusMessage.contains("관리자 권한") {
                    setStatus(shouldBlock ? "차단 규칙을 적용했습니다." : "차단을 해제했습니다.", error: false)
                }
                completion(true)
            } catch {
                isApplying = false
                isBlocked = HostFileService.isManagedBlockActive()
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
                performHostUpdate(shouldBlock: false) { [weak self] succeeded in
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
                self.performHostUpdate(shouldBlock: false) { [weak self] succeeded in
                    guard let self, succeeded else { return }
                    self.recordActivity(.focusCompleted)
                    self.clearUnlockWait(silently: true)
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

    private func clearUnlockWait(silently: Bool) {
        unlockWaitTask?.cancel()
        unlockWaitTask = nil
        unlockReadyAt = nil
        unlockSecondsRemaining = 0
        if !silently {
            setStatus("차단 해제 대기를 취소했습니다.", error: false)
        }
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

struct BlockedSite: Codable, Identifiable, Equatable {
    let id: UUID
    let domain: String

    init(id: UUID = UUID(), domain: String) {
        self.id = id
        self.domain = domain
    }
}

enum HabitActivityKind: String, Codable {
    case focusStarted
    case focusCompleted
    case unlockRequested
    case unblocked
}

struct HabitActivity: Codable, Identifiable {
    let id: UUID
    let kind: HabitActivityKind
    let timestamp: Date
    let minutes: Int?

    init(id: UUID = UUID(), kind: HabitActivityKind, timestamp: Date = Date(), minutes: Int? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.minutes = minutes
    }
}

enum DomainNormalizer {
    static func normalize(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var host = URLComponents(string: candidate)?.host?.lowercased() else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard host.contains("."), host != "localhost", host.allSatisfy({ character in
            character.isLetter || character.isNumber || character == "." || character == "-"
        }) else {
            return nil
        }

        let labels = host.split(separator: ".")
        guard labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
        return host
    }

    static func hostnames(for domains: [String]) -> [String] {
        var result = Set<String>()
        for domain in domains {
            result.insert(domain)
            if !domain.hasPrefix("www.") {
                result.insert("www.\(domain)")
            }
            if domain == "youtube.com" || domain == "www.youtube.com" {
                result.formUnion(["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "studio.youtube.com", "youtu.be"])
            }
        }
        return result.sorted()
    }
}

enum HostFileService {
    private static let beginMarker = "# HabitBlocker BEGIN"
    private static let endMarker = "# HabitBlocker END"
    private static let hostsPath = "/etc/hosts"

    static func isManagedBlockActive() -> Bool {
        guard let content = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return false }
        return content.contains(beginMarker) && content.contains(endMarker)
    }

    static func updateHosts(shouldBlock: Bool, domains: [String]) async throws {
        let current = try String(contentsOfFile: hostsPath, encoding: .utf8)
        let withoutManagedSection = removingManagedSection(from: current)
        let desired: String

        if shouldBlock {
            let hostnames = DomainNormalizer.hostnames(for: domains)
            guard !hostnames.isEmpty else { throw HostFileError.emptyDomainList }
            let rules = hostnames.flatMap { ["127.0.0.1 \($0)", "::1 \($0)"] }.joined(separator: "\n")
            let section = [
                beginMarker,
                "# 이 구역은 습관 차단기가 관리합니다.",
                rules,
                endMarker
            ].joined(separator: "\n")
            desired = withoutManagedSection.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + section + "\n"
        } else {
            desired = withoutManagedSection.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }

        let encoded = Data(desired.utf8).base64EncodedString()
        let shellCommand = "set -e; printf %s \(encoded) | /usr/bin/base64 -D > /etc/hosts; /usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder || true"
        let appleScript = "do shell script \(appleScriptString(shellCommand)) with administrator privileges"
        _ = try await runAppleScript(appleScript)
    }

    private static func removingManagedSection(from content: String) -> String {
        var result: [String] = []
        var skipping = false

        for line in content.components(separatedBy: .newlines) {
            if line == beginMarker {
                skipping = true
                continue
            }
            if line == endMarker {
                skipping = false
                continue
            }
            if !skipping {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func runAppleScript(_ source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw HostFileError.commandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return output
        }.value
    }
}

enum HostFileError: LocalizedError {
    case emptyDomainList
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyDomainList:
            return "차단할 도메인이 없습니다."
        case let .commandFailed(message):
            return message.isEmpty ? "관리자 권한 요청이 취소되었거나 hosts 파일을 변경할 수 없습니다." : message
        }
    }
}

extension String {
    func contains(_ substring: String) -> Bool {
        range(of: substring) != nil
    }
}
