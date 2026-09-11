import SwiftUI

@MainActor
struct MenuContentView: View {
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
            .disabled(store.isApplying || store.isUnlockPending || (store.sites.isEmpty && !store.isBlocked))

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

struct MetricView: View {
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
