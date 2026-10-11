import Foundation

struct FocusWatchContext {
    var domains: [String]
    var goal: String
    var threshold: Double
}

enum FocusWatchUpdate {
    case allowed(label: String, title: String, confidence: Double)
    case closed(title: String, domain: String)
    case closeFailed(title: String)
    case modelProblem(String)
    case needsPermission
}

@MainActor
final class FocusGuard {
    private let models: LocalModelController
    private var task: Task<Void, Never>?
    private var lastFingerprint: String?
    private var backoffUntil = Date.distantPast

    init(models: LocalModelController) {
        self.models = models
    }

    func start(context: @escaping () -> FocusWatchContext, onUpdate: @escaping (FocusWatchUpdate) -> Void) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluate(context: context, onUpdate: onUpdate)
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        lastFingerprint = nil
        backoffUntil = .distantPast
    }

    private func evaluate(context: () -> FocusWatchContext, onUpdate: (FocusWatchUpdate) -> Void) async {
        let current = context()
        guard Date() >= backoffUntil else { return }
        guard let page = await BrowserActivity.capture() else { return }
        if page.windowTitle.isEmpty && (page.pageURL?.isEmpty ?? true) {
            backoffUntil = Date().addingTimeInterval(20)
            onUpdate(.needsPermission)
            return
        }
        let isBrowser = FocusPolicy.looksLikeBrowser(bundleID: page.bundleID, appName: page.appName)
        guard let domain = FocusPolicy.matchedDomain(
            isBrowser: isBrowser,
            pageURL: page.pageURL,
            title: page.windowTitle,
            domains: current.domains
        ) else {
            if isBrowser {
                lastFingerprint = nil
            }
            return
        }
        if page.fingerprint == lastFingerprint || Date() < backoffUntil { return }

        let token = page.fingerprint
        try? await Task.sleep(for: .milliseconds(1200))
        if Task.isCancelled { return }
        guard let stable = await BrowserActivity.capture(), stable.fingerprint == token else { return }

        let verdict: FocusVerdict
        do {
            verdict = try await models.judge(
                appName: stable.appName,
                pageURL: stable.pageURL,
                title: stable.windowTitle,
                goal: current.goal
            )
        } catch {
            if Task.isCancelled { return }
            backoffUntil = Date().addingTimeInterval(12)
            onUpdate(.modelProblem(error.localizedDescription))
            return
        }
        if Task.isCancelled { return }
        guard let after = await BrowserActivity.capture(), after.fingerprint == token else { return }
        lastFingerprint = token

        let title = FocusPolicy.shortTitle(after.windowTitle.isEmpty ? domain : after.windowTitle)
        if FocusPolicy.shouldClose(verdict: verdict, threshold: current.threshold) {
            let closed = await BrowserActivity.closeActiveTab(bundleID: after.bundleID, appName: after.appName)
            if Task.isCancelled { return }
            if closed {
                onUpdate(.closed(title: title, domain: domain))
            } else {
                onUpdate(.closeFailed(title: title))
            }
        } else {
            onUpdate(.allowed(label: verdict.label.korean, title: title, confidence: verdict.confidence))
        }
    }
}
