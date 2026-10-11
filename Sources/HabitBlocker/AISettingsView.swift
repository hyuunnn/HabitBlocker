import AppKit
import SwiftUI

@MainActor
enum AISettingsWindow {
    private static var window: NSWindow?

    static func open(store: BlockerStore) {
        if window == nil {
            let root = AISettingsView()
                .environmentObject(store)
                .environmentObject(store.models)
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.title = "AI 설정"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 700))
            window.minSize = NSSize(width: 480, height: 560)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AISettingsView: View {
    @EnvironmentObject private var store: BlockerStore
    @EnvironmentObject private var models: LocalModelController
    @State private var accessibilityTrusted = false
    @State private var pendingDelete: LocalModelSpec?
    @State private var sampleLines: [String] = []
    @State private var sampleRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro
                behavior
                permissions
                modelsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { accessibilityTrusted = AccessibilityReader.isTrusted(prompt: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AccessibilityReader.isTrusted(prompt: false)
        }
        .alert("모델을 지울까요?", isPresented: deletePresented) {
            Button("삭제", role: .destructive) {
                if let pendingDelete {
                    models.delete(pendingDelete.id)
                }
                pendingDelete = nil
            }
            Button("취소", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("받은 파일을 지웁니다. 다시 쓰려면 처음부터 받아야 합니다.")
        }
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("로컬 판단")
                .font(.title3.weight(.semibold))
            Text("노트북에서 돌리도록 Clef-flash 9B의 4비트와 5비트를 준비했습니다. 주소와 제목만 이 Mac에서 판단하고, 화면이나 페이지 본문은 나가지 않습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behavior: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("AI로 내용 판단", isOn: Binding(
                get: { store.aiEnabled },
                set: { store.setAIEnabled($0) }
            ))
            .disabled(store.isBlocked || store.isApplying)

            Text(store.aiEnabled
                 ? "차단을 시작하면 등록한 사이트를 열어 두고, 딴짓인 탭만 닫습니다."
                 : "끄면 등록한 도메인의 모든 페이지를 막습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isBlocked {
                Text("차단 중에는 이 전환을 바꿀 수 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("지금 하려는 일")
                .font(.subheadline.weight(.semibold))
            TextField("공부하거나 업무에 집중하기", text: Binding(
                get: { store.goal },
                set: { store.setGoal($0) }
            ))
            .textFieldStyle(.roundedBorder)

            HStack {
                Text("닫는 기준")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int((store.threshold * 100).rounded()))% 이상")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { store.threshold },
                set: { store.setThreshold($0) }
            ), in: 0.5...0.9)
            Text("딴짓이라는 확신이 이 값 이상일 때만 탭을 닫습니다. 애매하면 그대로 둡니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("브라우저 권한")
                .font(.headline)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "hand.raised")
                    .foregroundStyle(accessibilityTrusted ? .green : .orange)
                Text(accessibilityTrusted
                     ? "손쉬운 사용이 허용되어 있습니다. Safari·Chrome 계열은 자동화 권한으로 탭 주소를 읽습니다."
                     : "Firefox처럼 주소를 직접 주지 않는 브라우저는 손쉬운 사용으로 창 제목을 읽습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("손쉬운 사용 요청") {
                    accessibilityTrusted = AccessibilityReader.isTrusted(prompt: true)
                }
                Button("설정 열기") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("모델")
                .font(.headline)
            Text("한 번에 하나만 메모리에 올립니다. 판단을 멈추면 메모리에서 내립니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Image(systemName: models.runtimeReady ? "checkmark.circle.fill" : "shippingbox")
                    .foregroundStyle(models.runtimeReady ? .green : .secondary)
                Text(runtimeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if models.runtimeReady {
                    Button("엔진 지우기") {
                        models.deleteRuntime()
                    }
                    .disabled(models.isBusy || models.isDownloading)
                }
            }
            if let runtimeProgress = models.runtimeProgress {
                ProgressView(value: runtimeProgress)
                    .progressViewStyle(.linear)
            }

            ForEach(ModelCatalog.specs) { spec in
                modelRow(spec)
            }

            HStack {
                Button(sampleRunning ? "시험 중…" : "예시로 시험") {
                    Task { await runSample() }
                }
                .disabled(sampleRunning || models.isBusy || models.isDownloading || !models.selectedModelIsReady)
                if models.isBusy && !sampleRunning && models.runtimeProgress == nil && !models.isDownloading {
                    ProgressView()
                        .controlSize(.small)
                    Text("모델을 불러오는 중")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !sampleLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sampleLines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if !models.banner.isEmpty {
                Text(models.banner)
                    .font(.caption)
                    .foregroundStyle(models.bannerIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var runtimeLabel: String {
        if let runtimeProgress = models.runtimeProgress {
            return "실행 엔진을 받는 중 \(Int((runtimeProgress * 100).rounded()))%"
        }
        return models.runtimeReady ? "실행 엔진 준비됨 · llama.cpp \(ModelCatalog.llamaRelease)" : "실행 엔진은 모델을 처음 받을 때 함께 준비합니다."
    }

    private func modelRow(_ spec: LocalModelSpec) -> some View {
        let state = models.installState[spec.id] ?? .missing
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(spec.name)
                            .font(.subheadline.weight(.semibold))
                        if spec.recommended {
                            Text("추천")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(.orange)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                        }
                        if models.selectedID == spec.id, models.isReady(spec.id) {
                            Text("사용 중")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    Text(spec.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(spec.sizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if case let .downloading(fraction) = state {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("취소") {
                        models.cancelDownload()
                    }
                }
            } else {
                HStack {
                    if case .ready = state {
                        Button("사용") {
                            models.select(spec.id)
                        }
                        .disabled(models.selectedID == spec.id || models.isBusy)
                        Button("삭제") {
                            pendingDelete = spec
                        }
                        .disabled(models.isBusy || models.isDownloading)
                    } else {
                        Button("받기") {
                            models.download(spec.id)
                        }
                        .disabled(models.isDownloading || models.isBusy)
                    }
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func runSample() async {
        sampleRunning = true
        sampleLines = []
        defer { sampleRunning = false }
        do {
            sampleLines = try await models.runSamples(goal: store.goal)
            if !store.aiGuardActive {
                models.stopServer()
            }
        } catch {
            sampleLines = [error.localizedDescription]
            if !store.aiGuardActive {
                models.stopServer()
            }
        }
    }
}
