import AppKit
import ApplicationServices
import Foundation

@MainActor
enum AccessibilityReader {
    static func isTrusted(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard isTrusted(prompt: false) else { return nil }
        let application = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else {
            return nil
        }
        let element = window as! AXUIElement
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
              let title = title as? String else {
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum BrowserActivity {
    static func capture() async -> PageSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = application.bundleIdentifier ?? ""
        let appName = application.localizedName ?? bundleID
        if bundleID == "com.hyun.habitblocker" { return nil }
        if let kind = BrowserKind.resolve(bundleID: bundleID), let page = await read(kind) {
            return PageSnapshot(appName: appName, bundleID: bundleID, windowTitle: page.title, pageURL: page.url)
        }
        let title = AccessibilityReader.focusedWindowTitle(pid: application.processIdentifier) ?? ""
        if title.isEmpty && BrowserKind.resolve(bundleID: bundleID) == nil && !FocusPolicy.looksLikeBrowser(bundleID: bundleID, appName: appName) {
            return nil
        }
        return PageSnapshot(appName: appName, bundleID: bundleID, windowTitle: title, pageURL: nil)
    }

    static func closeActiveTab(bundleID: String, appName: String) async -> Bool {
        if let kind = BrowserKind.resolve(bundleID: bundleID), await run(BrowserScript.closeSource(for: kind)) != nil {
            return true
        }
        guard AccessibilityReader.isTrusted(prompt: false) else { return false }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return false }
        return await run("tell application \"System Events\" to keystroke \"w\" using command down") != nil
    }

    private static func read(_ kind: BrowserKind) async -> (url: String, title: String)? {
        guard let output = await run(BrowserScript.readSource(for: kind)) else { return nil }
        let parts = output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let url = parts.first else { return nil }
        let title = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (url, title)
    }

    private static func run(_ source: String, timeout: TimeInterval = 4) async -> String? {
        await withCheckedContinuation { continuation in
            let waiter = ScriptWaiter(continuation)
            let process = waiter.process
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { finished in
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                _ = error.fileHandleForReading.readDataToEndOfFile()
                waiter.resume(finished.terminationStatus == 0 ? text : nil)
            }
            do {
                try process.run()
            } catch {
                waiter.resume(nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

/// 핸들러가 프로세스보다 먼저 풀리지 않게 붙잡아 두고, 끝나면 순환 참조를 끊는다.
private final class ScriptWaiter: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
        let process = self.process
        DispatchQueue.global().async {
            process.terminationHandler = nil
        }
    }
}
